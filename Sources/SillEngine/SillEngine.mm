// Sill's Chromium engine (SillEngine.h). CEF's C++ lives here and nowhere else.

#import "SillEngine.h"
#include <crt_externs.h>
#include <map>
#include <set>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"

static NSString* S(const CefString& s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

@interface SEWebView ()
- (void)adoptBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
@property(nonatomic, readwrite, copy, nullable) NSURL* URL;
@property(nonatomic, readwrite, copy, nullable) NSString* title;
@property(nonatomic, readwrite) BOOL isLoading;
@property(nonatomic, readwrite) double estimatedProgress;
@property(nonatomic, readwrite) BOOL canGoBack;
@property(nonatomic, readwrite) BOOL canGoForward;
@end

// MARK: - The app object

@interface SEApplication () <CefAppProtocol>
@end

@implementation SEApplication {
  BOOL handlingSendEvent_;
  BOOL terminating_;
}
- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)value { handlingSendEvent_ = value; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scoper;
  [super sendEvent:event];
}
// Quitting goes through Chromium: the app's own checks first (pages with
// unsaved changes, downloads running), then every page closes, then the loop ends.
- (void)terminate:(id)sender {
  if (terminating_) return;
  NSApplicationTerminateReply reply = NSTerminateNow;
  if ([self.delegate respondsToSelector:@selector(applicationShouldTerminate:)])
    reply = [self.delegate applicationShouldTerminate:self];
  if (reply == NSTerminateCancel) return;
  if (reply == NSTerminateLater) { terminating_ = NO; return; }
  [self finishTerminating];
}
// Quit sent from outside (the Dock, another app, logging out) takes the same
// way: AppKit's own handling would wait for a reply that never reaches it.
- (void)finishLaunching {
  [super finishLaunching];
  [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self
                                                     andSelector:@selector(handleQuitEvent:withReply:)
                                                   forEventClass:kCoreEventClass
                                                      andEventID:kAEQuitApplication];
}
- (void)handleQuitEvent:(NSAppleEventDescriptor*)event withReply:(NSAppleEventDescriptor*)reply {
  [self terminate:nil];
}
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate {
  if (shouldTerminate) [self finishTerminating];
}
- (void)finishTerminating {
  terminating_ = YES;
  // The delegate hears it as an observer of the notification, as AppKit set it up.
  [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationWillTerminateNotification object:self];
  [SEEngine quit];
}
@end

// MARK: - Pages, all of them

static NSHashTable<SEWebView*>* gViews;
static int gOpenBrowsers = 0;
static bool gQuitting = false;
static CefRefPtr<CefRequestContext> gPrivateContext;
static std::string gExtensions;
// Sill's own page scripts, handed to every page's process as it's made
// (Tools/chromium-helper.mm runs them as each document starts).
static NSArray<NSString*>* gPageScripts = @[];
static CefRefPtr<CefDictionaryValue> PageScriptsInfo() {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  for (NSUInteger i = 0; i < gPageScripts.count; i++) list->SetString(i, gPageScripts[i].UTF8String);
  CefRefPtr<CefDictionaryValue> info = CefDictionaryValue::Create();
  info->SetList("sill-scripts", list);
  return info;
}  // folders of the extensions that come with Sill, comma separated

// MARK: - Menu items

@implementation SEMenuItem
- (instancetype)initWithID:(NSInteger)commandID title:(NSString*)title enabled:(BOOL)enabled checked:(BOOL)checked {
  self = [super init];
  _commandID = commandID;
  _title = [title copy];
  _enabled = enabled;
  _checked = checked;
  return self;
}
@end

// MARK: - One page's events

class SEClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
                 public CefKeyboardHandler, public CefContextMenuHandler, public CefRequestHandler,
                 public CefDownloadHandler, public CefDevToolsMessageObserver {
 public:
  explicit SEClient(SEWebView* view) : view_(view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  // Life span
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    gOpenBrowsers++;
    devtools_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    [view_ adoptBrowser:browser];
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // The page closed itself (window.close()): Sill decides, then closes it.
    if (!closing_ && !gQuitting) {
      id<SEWebViewDelegate> d = view_.pageDelegate;
      if ([d respondsToSelector:@selector(webViewDidClose:)]) [d webViewDidClose:view_];
      return true;
    }
    return false;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    devtools_ = nullptr;
    pending_.clear();
    [view_ browserClosed];
    if (--gOpenBrowsers <= 0 && gQuitting) CefQuitMessageLoop();
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& target_url, const CefString&,
                     WindowOpenDisposition disposition, bool, const CefPopupFeatures& features, CefWindowInfo& info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override;
  void markClosing() { closing_ = true; }

  // Display
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (!frame->IsMain()) return;
    NSString* text = S(url);
    // A page of Sill's own shows the address it stands for.
    if (shownFor_ && [text hasPrefix:@"data:"]) { view_.URL = shownFor_; }
    else { shownFor_ = nil; view_.URL = [NSURL URLWithString:text]; }
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webViewDidCommit:)]) [d webViewDidCommit:view_];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    NSString* t = S(title);
    // Chromium titles a page without one with its address; Sill shows its own then.
    if (view_.URL && [t isEqualToString:view_.URL.absoluteString]) t = @"";
    if (shownFor_ && [t hasPrefix:@"data:"]) t = @"";
    view_.title = t;
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override { view_.estimatedProgress = progress; }
  void OnStatusMessage(CefRefPtr<CefBrowser>, const CefString& value) override {
    NSString* link = S(value);
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:hoveredLink:)]) [d webView:view_ hoveredLink:link.length ? link : nil];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser>, const std::vector<CefString>& urls) override {
    NSMutableArray* list = [NSMutableArray array];
    for (auto& u : urls) if (NSURL* url = [NSURL URLWithString:S(u)]) [list addObject:url];
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:faviconURLs:)]) [d webView:view_ faviconURLs:list];
  }
  void OnFullscreenModeChange(CefRefPtr<CefBrowser>, bool on) override {
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:fullscreen:)]) [d webView:view_ fullscreen:on];
  }

  // Load
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    if (view_.isLoading != loading) view_.isLoading = loading;
    if (view_.canGoBack != back) view_.canGoBack = back;
    if (view_.canGoForward != forward) view_.canGoForward = forward;
    if (!loading) {
      id<SEWebViewDelegate> d = view_.pageDelegate;
      if ([d respondsToSelector:@selector(webViewDidFinish:)]) [d webViewDidFinish:view_];
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString& text,
                   const CefString& url) override {
    if (!frame->IsMain() || code == ERR_ABORTED) return;
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:didFailWithCode:description:url:)])
      [d webView:view_ didFailWithCode:code description:S(text) url:[NSURL URLWithString:S(url)] ?: view_.URL];
  }

  // Requests
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool gesture,
                      bool) override {
    if (!frame->IsMain()) return false;
    NSURL* url = [NSURL URLWithString:S(request->GetURL())];
    if (!url || [url.scheme isEqualToString:@"data"] || [url.scheme isEqualToString:@"devtools"]) return false;
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:shouldLoad:userGesture:)])
      return ![d webView:view_ shouldLoad:url userGesture:gesture];
    return false;
  }
  // Picture in picture: frames from the page's process (Tools/chromium-helper.mm).
  struct PipHeader {
    uint32_t width, height;
    double time, duration;
    uint32_t paused, reserved;
  };
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefProcessId,
                                CefRefPtr<CefProcessMessage> message) override {
    if (message->GetName() == "sill-msg") {
      NSString* text = S(message->GetArgumentList()->GetString(0));
      id<SEWebViewDelegate> d = view_.pageDelegate;
      if (text && [d respondsToSelector:@selector(webView:message:)]) [d webView:view_ message:text];
      return true;
    }
    if (message->GetName() != "sill-pip") return false;
    CefRefPtr<CefSharedMemoryRegion> region = message->GetSharedMemoryRegion();
    if (!region || !region->IsValid() || region->Size() < sizeof(PipHeader)) return true;
    auto* header = static_cast<const PipHeader*>(region->Memory());
    size_t pixels = (size_t)header->width * header->height * 4;
    bool frame = pixels && region->Size() >= sizeof(PipHeader) + pixels;
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:videoFrame:width:height:time:duration:paused:)])
      [d webView:view_ videoFrame:frame ? (header + 1) : nullptr width:frame ? header->width : 0
          height:frame ? header->height : 0 time:header->time duration:header->duration paused:header->paused];
    return true;
  }

  // ⌘-click, middle-click: a tab of its own.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& target_url,
                        WindowOpenDisposition disposition, bool) override {
    if (disposition == CEF_WOD_CURRENT_TAB) return false;
    NSURL* url = [NSURL URLWithString:S(target_url)];
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if (!url || ![d respondsToSelector:@selector(webView:openURL:inBackground:)]) return false;
    BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    dispatch_async(dispatch_get_main_queue(), ^{ [d webView:view_ openURL:url inBackground:background]; });
    return true;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int, const CefString&) override {
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webViewProcessEnded:)]) [d webViewProcessEnded:view_];
  }

  // Keys: what the page didn't take goes to Sill (its menus).
  bool OnKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle os_event) override {
    NSEvent* ns = (__bridge NSEvent*)os_event;
    if (!ns || event.type != KEYEVENT_RAWKEYDOWN) return false;
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if ([d respondsToSelector:@selector(webView:unhandledKey:)]) return [d webView:view_ unhandledKey:ns];
    return (ns.modifierFlags & NSEventModifierFlagCommand) && [[NSApp mainMenu] performKeyEquivalent:ns];
  }

  // The right-click menu: Sill draws it.
  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    id<SEWebViewDelegate> d = view_.pageDelegate;
    if (![d respondsToSelector:@selector(webView:menu:at:choose:)]) return false;
    NSMutableArray* items = [NSMutableArray array];
    for (size_t i = 0; i < model->GetCount(); i++) {
      if (model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR) {
        [items addObject:[[SEMenuItem alloc] initWithID:-1 title:@"" enabled:NO checked:NO]];
        continue;
      }
      if (model->GetTypeAt(i) == MENUITEMTYPE_SUBMENU) continue;
      NSString* title = [S(model->GetLabelAt(i)) stringByReplacingOccurrencesOfString:@"&" withString:@""];
      [items addObject:[[SEMenuItem alloc] initWithID:model->GetCommandIdAt(i) title:title
                                              enabled:model->IsEnabledAt(i) checked:model->IsCheckedAt(i)]];
    }
    NSPoint point = NSMakePoint(params->GetXCoord(), view_.bounds.size.height - params->GetYCoord());
    point = [view_ convertPoint:point toView:nil];
    CefRefPtr<CefRunContextMenuCallback> keep = callback;
    [d webView:view_ menu:items at:point choose:^(NSInteger commandID) {
      if (commandID < 0) keep->Cancel(); else keep->Continue((int)commandID, EVENTFLAG_NONE);
    }];
    return true;
  }

  // Downloads
  bool CanDownload(CefRefPtr<CefBrowser>, const CefString&, const CefString&) override { return true; }
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString& name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    id<SEWebViewDelegate> d = view_.pageDelegate;
    NSURL* where = [d respondsToSelector:@selector(webView:downloadNamed:)] ? [d webView:view_ downloadNamed:S(name)] : nil;
    if (!where) return false;
    downloads_[item->GetId()] = where;
    callback->Continue(where.path.UTF8String, false);
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback>) override {
    auto found = downloads_.find(item->GetId());
    if (found == downloads_.end()) return;
    id<SEWebViewDelegate> d = view_.pageDelegate;
    double progress = item->GetPercentComplete() < 0 ? 0 : item->GetPercentComplete() / 100.0;
    BOOL done = item->IsComplete() || item->IsCanceled();
    if ([d respondsToSelector:@selector(webView:download:progress:done:)])
      [d webView:view_ download:found->second progress:progress done:done];
    if (done) downloads_.erase(found);
  }

  // DevTools answers: scripts' results and snapshots.
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success, const void* result,
                              size_t size) override {
    auto found = pending_.find(message_id);
    if (found == pending_.end()) return;
    void (^done)(BOOL, NSDictionary*) = found->second;
    pending_.erase(found);
    NSData* data = [NSData dataWithBytes:result length:size];
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    done(success, [json isKindOfClass:NSDictionary.class] ? json : nil);
  }
  int devtools(CefRefPtr<CefBrowser> browser, const char* method, CefRefPtr<CefDictionaryValue> params,
               void (^done)(BOOL, NSDictionary*)) {
    int id_ = ++nextID_;
    pending_[id_] = [done copy];
    if (!browser->GetHost()->ExecuteDevToolsMethod(id_, method, params)) {
      pending_.erase(id_);
      done(NO, nil);
    }
    return id_;
  }

  void showing(NSURL* url) { shownFor_ = url; }

 private:
  __weak SEWebView* view_;
  bool closing_ = false;
  NSURL* shownFor_ = nil;
  int nextID_ = 0;
  std::map<int, void (^)(BOOL, NSDictionary*)> pending_;
  std::map<uint32_t, NSURL*> downloads_;
  CefRefPtr<CefRegistration> devtools_;
  IMPLEMENT_REFCOUNTING(SEClient);
};

// MARK: - The view

@implementation SEWebView {
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<SEClient> client_;
  NSURL* pendingURL_;
  NSString* pendingHTML_;
  NSURL* pendingHTMLFor_;
  BOOL hidden_;
  BOOL muted_;
  double zoom_;
}

- (instancetype)initWithFrame:(NSRect)frame private:(BOOL)isPrivate {
  return [self initWithFrame:frame private:isPrivate create:YES];
}

- (instancetype)initWithFrame:(NSRect)frame private:(BOOL)isPrivate create:(BOOL)create {
  self = [super initWithFrame:frame];
  _isPrivate = isPrivate;
  zoom_ = 1;
  self.wantsLayer = YES;
  client_ = new SEClient(self);
  [gViews addObject:self];
  if (create) [self makeBrowser];
  return self;
}

- (instancetype)initForPopupWithFrame:(NSRect)frame private:(BOOL)isPrivate {
  return [self initWithFrame:frame private:isPrivate create:NO];
}

- (CefRefPtr<SEClient>)client { return client_; }

- (void)makeBrowser {
  CefWindowInfo info;
  info.SetAsChild((__bridge void*)self, CefRect(0, 0, (int)self.bounds.size.width, (int)self.bounds.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  settings.background_color = CefColorSetARGB(255, 30, 30, 30);
  CefRefPtr<CefRequestContext> context = _isPrivate ? gPrivateContext : nullptr;
  CefBrowserHost::CreateBrowser(info, client_, "", settings, PageScriptsInfo(), context);
}

- (void)adoptBrowser:(CefRefPtr<CefBrowser>)browser {
  browser_ = browser;
  NSView* page = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  page.frame = self.bounds;
  page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (hidden_) browser_->GetHost()->WasHidden(true);
  if (muted_) browser_->GetHost()->SetAudioMuted(true);
  if (zoom_ != 1) browser_->GetHost()->SetZoomLevel(log(zoom_) / log(1.2));
  if (pendingHTML_) { [self loadHTML:pendingHTML_ forURL:pendingHTMLFor_]; pendingHTML_ = nil; }
  else if (pendingURL_) { [self loadURL:pendingURL_]; pendingURL_ = nil; }
}


- (void)browserClosed {
  browser_ = nullptr;
  [gViews removeObject:self];
}

- (BOOL)isFlipped { return NO; }

// The view Chromium draws in, kept the size of this one.
- (void)resizeSubviewsWithOldSize:(NSSize)old {
  [super resizeSubviewsWithOldSize:old];
  for (NSView* v in self.subviews) v.frame = self.bounds;
}

- (void)loadURL:(NSURL*)url {
  if (!browser_) { pendingURL_ = url; return; }
  client_->showing(nil);
  browser_->GetMainFrame()->LoadURL(url.absoluteString.UTF8String);
}

- (void)loadHTML:(NSString*)html forURL:(NSURL*)url {
  if (!browser_) { pendingHTML_ = html; pendingHTMLFor_ = url; return; }
  client_->showing(url);
  NSString* encoded = [[html dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  NSString* data = [@"data:text/html;charset=utf-8;base64," stringByAppendingString:encoded];
  browser_->GetMainFrame()->LoadURL(data.UTF8String);
}

- (void)goBack { if (browser_) browser_->GoBack(); }
- (void)goForward { if (browser_) browser_->GoForward(); }
- (void)reload { if (browser_) browser_->Reload(); }
- (void)reloadFromOrigin { if (browser_) browser_->ReloadIgnoreCache(); }
- (void)stopLoading { if (browser_) browser_->StopLoad(); }

- (double)pageZoom { return zoom_; }
- (void)setPageZoom:(double)zoom {
  zoom_ = zoom;
  if (browser_) browser_->GetHost()->SetZoomLevel(log(zoom) / log(1.2));
}

- (BOOL)pageHidden { return hidden_; }
- (void)setPageHidden:(BOOL)hidden {
  if (hidden_ == hidden) return;
  hidden_ = hidden;
  if (browser_) browser_->GetHost()->WasHidden(hidden);
}

- (void)insistShown {
  hidden_ = NO;
  if (browser_) browser_->GetHost()->WasHidden(false);
}

- (BOOL)audioMuted { return muted_; }
- (void)setAudioMuted:(BOOL)muted {
  muted_ = muted;
  if (browser_) browser_->GetHost()->SetAudioMuted(muted);
}

- (void)evaluateJavaScript:(NSString*)script completion:(void (^)(id, NSError*))completion {
  if (!browser_) { if (completion) completion(nil, [NSError errorWithDomain:@"SillEngine" code:1 userInfo:nil]); return; }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", script.UTF8String);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  // As if clicked: Sill's own scripts (picture in picture's play button) may start media.
  params->SetBool("userGesture", true);
  client_->devtools(browser_, "Runtime.evaluate", params, ^(BOOL ok, NSDictionary* json) {
    if (!completion) return;
    NSDictionary* result = json[@"result"];
    if (!ok || !result || json[@"exceptionDetails"]) {
      NSString* why = [json[@"exceptionDetails"][@"exception"][@"description"] description] ?: @"script failed";
      completion(nil, [NSError errorWithDomain:@"SillEngine" code:2 userInfo:@{NSLocalizedDescriptionKey: why}]);
      return;
    }
    id value = result[@"value"];
    completion(value == NSNull.null ? nil : value, nil);
  });
}

- (void)takeSnapshotWithWidth:(CGFloat)width completion:(void (^)(NSImage*))completion {
  if (!browser_ || hidden_ || self.bounds.size.width <= 0) { completion(nil); return; }
  double cssWidth = self.bounds.size.width / zoom_, cssHeight = self.bounds.size.height / zoom_;
  CefRefPtr<CefDictionaryValue> clip = CefDictionaryValue::Create();
  clip->SetDouble("x", 0);
  clip->SetDouble("y", 0);
  clip->SetDouble("width", cssWidth);
  clip->SetDouble("height", cssHeight);
  clip->SetDouble("scale", MIN(1.0, width * 2 / cssWidth));
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "jpeg");
  params->SetInt("quality", 80);
  params->SetDictionary("clip", clip);
  client_->devtools(browser_, "Page.captureScreenshot", params, ^(BOOL ok, NSDictionary* json) {
    NSString* base64 = ok ? json[@"data"] : nil;
    NSData* data = base64 ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
    completion(data ? [[NSImage alloc] initWithData:data] : nil);
  });
}

- (void)find:(NSString*)text forward:(BOOL)forward again:(BOOL)again {
  if (browser_) browser_->GetHost()->Find(text.UTF8String, forward, false, again);
}
- (void)stopFinding { if (browser_) browser_->GetHost()->StopFinding(true); }

- (void)focusPage {
  if (!browser_) return;
  browser_->GetHost()->SetFocus(true);
  NSView* page = self.subviews.firstObject;
  if (page) [self.window makeFirstResponder:page];
}

- (void)showDevTools {
  if (!browser_) return;
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  browser_->GetHost()->ShowDevTools(info, nullptr, CefBrowserSettings(), CefPoint());
}

- (void)closePage {
  if (!browser_) return;
  client_->markClosing();
  browser_->GetHost()->CloseBrowser(true);
}

- (void)dealloc {
  if (browser_) { client_->markClosing(); browser_->GetHost()->CloseBrowser(true); }
}
@end

// MARK: - Popups ("Sign in with…" windows keep their opener)

bool SEClient::OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& target_url,
                             const CefString&, WindowOpenDisposition disposition, bool,
                             const CefPopupFeatures& features, CefWindowInfo& info, CefRefPtr<CefClient>& client,
                             CefBrowserSettings&, CefRefPtr<CefDictionaryValue>& extra, bool*) {
  id<SEWebViewDelegate> d = view_.pageDelegate;
  if (features.widthSet || features.heightSet || features.isPopup) {
    NSSize size = NSMakeSize(features.widthSet ? features.width : 520, features.heightSet ? features.height : 640);
    SEWebView* popup = [d respondsToSelector:@selector(webView:popupWithSize:)] ? [d webView:view_ popupWithSize:size] : nil;
    if (!popup) return true;
    info.SetAsChild((__bridge void*)popup, CefRect(0, 0, (int)popup.bounds.size.width, (int)popup.bounds.size.height));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = popup.client;
    extra = PageScriptsInfo();
    return false;
  }
  NSURL* url = [NSURL URLWithString:S(target_url)];
  if (url && [d respondsToSelector:@selector(webView:openURL:inBackground:)]) {
    BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    dispatch_async(dispatch_get_main_queue(), ^{ [d webView:view_ openURL:url inBackground:background]; });
  }
  return true;
}

// MARK: - The engine

class SEApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString& type, CefRefPtr<CefCommandLine> line) override {
    if (!type.empty()) return;
    // None of Chrome's background traffic, update checks or reporting.
    line->AppendSwitch("disable-background-networking");
    line->AppendSwitch("disable-component-update");
    line->AppendSwitch("disable-domain-reliability");
    line->AppendSwitch("use-mock-keychain");
    // Drawing on the GPU, as Chrome and Dia do.
    line->AppendSwitch("enable-gpu-rasterization");
    line->AppendSwitch("enable-zero-copy");
    // Sill says itself which pages are hidden. Chromium's own guess (a page
    // covered by another view is hidden) would stop the video of a page
    // floating in picture in picture, kept under the one in front.
    std::string off = line->GetSwitchValue("disable-features").ToString();
    off += off.empty() ? "" : ",";
    // ...and the extensions that come with Sill (uBlock Origin Lite) load
    // from their folders, as Chromium's own command line loads them.
    line->AppendSwitchWithValue("disable-features", off + "MacWebContentsOcclusion,DisableLoadExtensionCommandLineSwitch");
    if (!gExtensions.empty()) line->AppendSwitchWithValue("load-extension", gExtensions);
  }
  void OnContextInitialized() override {
    CefRequestContextSettings settings;  // no cache path: kept in memory, gone when Sill quits
    gPrivateContext = CefRequestContext::CreateContext(settings, nullptr);
    ready_ = true;
    for (void (^b)(void) in waiting_) b();
    [waiting_ removeAllObjects];
  }
  bool ready_ = false;
  NSMutableArray* waiting_ = [NSMutableArray array];
  IMPLEMENT_REFCOUNTING(SEApp);
};

static CefScopedLibraryLoader* gLibrary;
static CefRefPtr<SEApp> gApp;

class CookieSet : public CefSetCookieCallback {
 public:
  void OnComplete(bool) override {}
  IMPLEMENT_REFCOUNTING(CookieSet);
};
class CookiesGone : public CefDeleteCookiesCallback {
 public:
  explicit CookiesGone(void (^done)(void)) : done_([done copy]) {}
  void OnComplete(int) override { done_(); }
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(CookiesGone);
};

@implementation SEEngine

// The extensions that come with Sill (Contents/Resources/Extensions), copied
// into the profile when new or updated: Chromium writes into an extension's
// folder (its compiled filter lists), and the app's own files stay as signed.
static std::string InstallExtensions(NSString* profile) {
  NSFileManager* files = [NSFileManager defaultManager];
  NSString* shipped = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"Extensions"];
  NSString* installed = [profile stringByAppendingPathComponent:@"Extensions"];
  [files createDirectoryAtPath:installed withIntermediateDirectories:YES attributes:nil error:nil];
  std::string folders;
  // Switched off in Sill's Extensions panel: installed, not loaded.
  NSArray* off = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"disabledExtensions"] ?: @[];
  for (NSString* name in [files contentsOfDirectoryAtPath:shipped error:nil]) {
    NSString* from = [shipped stringByAppendingPathComponent:name];
    NSString* to = [installed stringByAppendingPathComponent:name];
    NSString* (^version)(NSString*) = ^NSString*(NSString* folder) {
      NSData* data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"manifest.json"]];
      NSDictionary* manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      return [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"version"] : nil;
    };
    NSString* want = version(from);
    if (!want) continue;
    if (![want isEqual:version(to)]) {
      [files removeItemAtPath:to error:nil];
      if (![files copyItemAtPath:from toPath:to error:nil]) continue;
    }
    if ([off containsObject:name]) continue;
    if (!folders.empty()) folders += ",";
    folders += to.UTF8String;
  }
  return folders;
}

+ (void)setPageScripts:(NSArray<NSString*>*)scripts { gPageScripts = [scripts copy] ?: @[]; }

+ (BOOL)startWithProfile:(NSString*)profile {
  gLibrary = new CefScopedLibraryLoader();
  gExtensions = InstallExtensions(profile);
  if (!gLibrary->LoadInMain()) return NO;
  gViews = [NSHashTable weakObjectsHashTable];
  CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
  CefSettings settings;
  [[NSFileManager defaultManager] createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil];
  CefString(&settings.root_cache_path) = profile.UTF8String;
  CefString(&settings.cache_path) = [profile stringByAppendingPathComponent:@"Default"].UTF8String;
  settings.persist_session_cookies = true;
  CefString(&settings.locale) = "en-GB";
  settings.background_color = CefColorSetARGB(255, 30, 30, 30);
  gApp = new SEApp();
  return CefInitialize(args, settings, gApp.get(), nullptr);
}

+ (void)whenReady:(void (^)(void))block {
  if (gApp && gApp->ready_) block(); else [gApp->waiting_ addObject:[block copy]];
}

+ (void)run { CefRunMessageLoop(); }

+ (void)quit {
  gQuitting = true;
  for (SEWebView* v in gViews.allObjects) [v closePage];
  if (gOpenBrowsers <= 0) { CefQuitMessageLoop(); return; }
  // A page that won't close doesn't keep Sill open.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ CefQuitMessageLoop(); });
}

+ (void)shutdown {
  gPrivateContext = nullptr;
  CefShutdown();
}

+ (void)importCookies:(NSArray<NSDictionary*>*)cookies {
  CefRefPtr<CefCookieManager> manager = CefCookieManager::GetGlobalManager(nullptr);
  for (NSDictionary* c in cookies) {
    CefCookie cookie;
    NSString* domain = c[@"domain"];
    CefString(&cookie.name) = [c[@"name"] UTF8String];
    CefString(&cookie.value) = [c[@"value"] UTF8String];
    CefString(&cookie.domain) = domain.UTF8String;
    CefString(&cookie.path) = [c[@"path"] UTF8String];
    cookie.secure = [c[@"secure"] boolValue];
    cookie.httponly = [c[@"httponly"] boolValue];
    double expires = [c[@"expires"] doubleValue];
    if (expires > 0) {
      cookie.has_expires = true;
      cookie.expires.val = (int64_t)((expires + 11644473600.0) * 1000000.0);
    }
    NSString* host = [domain hasPrefix:@"."] ? [domain substringFromIndex:1] : domain;
    NSString* url = [NSString stringWithFormat:@"https://%@%@", host, c[@"path"]];
    manager->SetCookie(url.UTF8String, cookie, new CookieSet());
  }
  manager->FlushStore(nullptr);
}

+ (void)clearWebsiteData:(void (^)(void))done {
  CefRefPtr<CefCookieManager> manager = CefCookieManager::GetGlobalManager(nullptr);
  manager->DeleteCookies("", "", new CookiesGone(done));
}
@end
