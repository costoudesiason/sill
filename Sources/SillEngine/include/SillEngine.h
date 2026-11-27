// Sill's Chromium engine: Chromium (CEF) behind an interface shaped like the
// parts of WKWebView Sill uses, so the rest of Sill barely knows the
// difference. Objective-C on the outside; CEF's C++ stays inside.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The app object Chromium needs: it must know when AppKit is sending an event.
@interface SEApplication : NSApplication
@end

/// Starting, running and stopping Chromium, once per launch.
@interface SEEngine : NSObject
/// Loads Chromium and starts it, keeping its profile in `profile`. NO if it can't.
/// Scripts every page runs as each of its documents starts, before the page's
/// own (http, https and file pages; main frame). Set before any page is made.
+ (void)setPageScripts:(NSArray<NSString *> *)scripts;
+ (BOOL)startWithProfile:(NSString *)profile;
/// Runs `block` once Chromium is ready for pages (at once if it is).
+ (void)whenReady:(void (^)(void))block;
/// Sill was launched again while running (or a launch overlapped one quitting):
/// Sill opens its own window. Left to Chromium, it opened a stock Chromium one.
+ (void)whenRelaunched:(void (^)(void))block;
/// AppKit's run loop, with Chromium's work in it, until `quit`.
+ (void)run;
/// Closes every page, then ends the run loop.
+ (void)quit;
+ (void)shutdown;
/// Cookies to add once (Sill's sign-ins), as dictionaries: name, value,
/// domain, path, secure, httponly, expires (seconds since 1970, 0 for session).
+ (void)importCookies:(NSArray<NSDictionary *> *)cookies;
/// Clears cookies and site data for every site.
+ (void)clearWebsiteData:(void (^)(void))done;
/// Chromium's own settings (chrome://settings, at `page` if given, such as
/// "privacy"), in a window of their own: they open only in Chrome-style
/// pages, which Chromium hosts itself. Named Sill, with what Sill does
/// itself left out. Brought to the front if already open.
+ (void)openChromiumSettings:(nullable NSString *)page;
@end

@class SEWebView;

/// What a right-click in a page landed on, as Chromium saw it.
typedef NS_OPTIONS(NSInteger, SEMediaState) {
  SEMediaPaused = 1 << 1, SEMediaMuted = 1 << 2, SEMediaLoops = 1 << 3, SEMediaCanSave = 1 << 4,
  SEMediaHasAudio = 1 << 5, SEMediaCanToggleControls = 1 << 6, SEMediaShowsControls = 1 << 7,
  SEMediaCanPictureInPicture = 1 << 10, SEMediaInPictureInPicture = 1 << 11, SEMediaCanLoop = 1 << 12,
};
typedef NS_OPTIONS(NSInteger, SEEditState) {
  SEEditCanUndo = 1 << 0, SEEditCanRedo = 1 << 1, SEEditCanCut = 1 << 2, SEEditCanCopy = 1 << 3,
  SEEditCanPaste = 1 << 4, SEEditCanDelete = 1 << 5, SEEditCanSelectAll = 1 << 6, SEEditRich = 1 << 8,
};
typedef NS_ENUM(NSInteger, SEMediaKind) {
  SEMediaNone, SEMediaImage, SEMediaVideo, SEMediaAudio, SEMediaCanvas, SEMediaFile, SEMediaPlugin,
};

/// A right-click in a page: what's under the pointer, and what can be done
/// with it in the frame it landed in. Sill builds the menu from this.
@interface SEContextMenu : NSObject
/// Where, in the window's coordinates.
@property(nonatomic, readonly) NSPoint point;
@property(nonatomic, readonly, nullable) NSURL *linkURL, *sourceURL, *pageURL, *frameURL;
@property(nonatomic, readonly, copy) NSString *linkText, *selection;
@property(nonatomic, readonly) SEMediaKind mediaKind;
@property(nonatomic, readonly) SEMediaState mediaState;
@property(nonatomic, readonly) SEEditState editState;
@property(nonatomic, readonly) BOOL editable, inFrame;
/// A misspelled word under the pointer, and Chromium's suggestions for it.
@property(nonatomic, readonly, copy, nullable) NSString *misspelledWord;
@property(nonatomic, readonly, copy) NSArray<NSString *> *suggestions;
/// undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll: in the clicked frame.
- (void)edit:(NSString *)command;
- (void)replaceMisspelling:(NSString *)word;
- (void)learnSpelling;
/// DevTools, on the element under the pointer.
- (void)inspect;
/// A script in the clicked frame (also a frame from another site); no answer.
- (void)runScript:(NSString *)script;
- (void)reloadFrame;
/// The bytes at an address, fetched as the frame would (its cookies); nil if it failed.
- (void)fetch:(NSURL *)url completion:(void (^)(NSData *_Nullable data, NSString *_Nullable mimeType))completion;
@end

@protocol SEWebViewDelegate <NSObject>
@optional
/// A main-frame load is about to start. NO cancels it (another app's link, say).
- (BOOL)webView:(SEWebView *)view shouldLoad:(NSURL *)url userGesture:(BOOL)gesture;
/// The page's address changed (a load committed, or the page changed it itself).
- (void)webViewDidCommit:(SEWebView *)view;
- (void)webViewDidFinish:(SEWebView *)view;
- (void)webView:(SEWebView *)view didFailWithCode:(NSInteger)code description:(NSString *)text url:(NSURL *)url;
/// The page wants a link in a tab of its own.
- (void)webView:(SEWebView *)view openURL:(NSURL *)url inBackground:(BOOL)background;
/// The page wants a small window of its own ("Sign in with…"): return an
/// empty page view (initForPopup…) placed where it should show; Chromium puts
/// the new page, which keeps its opener, in it. Nil refuses the window.
- (nullable SEWebView *)webView:(SEWebView *)view popupWithSize:(NSSize)size;
- (void)webViewDidClose:(SEWebView *)view;
/// The link under the pointer, or nil.
- (void)webView:(SEWebView *)view hoveredLink:(nullable NSString *)link;
- (void)webView:(SEWebView *)view faviconURLs:(NSArray<NSURL *> *)urls;
- (void)webView:(SEWebView *)view audible:(BOOL)audible;
- (void)webView:(SEWebView *)view fullscreen:(BOOL)on;
/// A right-click: Sill shows its menu (Chromium shows none of its own).
- (void)webView:(SEWebView *)view contextMenu:(SEContextMenu *)menu;
- (void)webViewProcessEnded:(SEWebView *)view;
/// A file the page is downloading: where it goes is decided here.
- (nullable NSURL *)webView:(SEWebView *)view downloadNamed:(NSString *)name;
/// The same, with the address it was asked for (the right-click menu's Save As… picks the file first).
- (nullable NSURL *)webView:(SEWebView *)view downloadNamed:(NSString *)name from:(NSURL *)source;
/// How it's going; `failed` when it was stopped or broke off (its file is then incomplete).
- (void)webView:(SEWebView *)view download:(NSURL *)file progress:(double)progress done:(BOOL)done failed:(BOOL)failed;
/// A video frame for picture in picture, as the page sent it (RGBA, 4 bytes
/// a pixel, rows packed), with the video's state; `rgba` is NULL (and the
/// size 0) when only the state changed. Valid only during the call.
- (void)webView:(SEWebView *)view videoFrame:(const void *_Nullable)rgba width:(NSInteger)width height:(NSInteger)height
           time:(double)time duration:(double)duration paused:(BOOL)paused;
/// A key the page didn't take (⌘-shortcuts reach the menus this way).
- (BOOL)webView:(SEWebView *)view unhandledKey:(NSEvent *)event;
/// A message from Sill's page script (`__sillPost`), one string of JSON.
- (void)webView:(SEWebView *)view message:(NSString *)json;
@end

/// A Chromium page in a view. Observable (KVO) as WKWebView's are: url,
/// title, isLoading, estimatedProgress, canGoBack, canGoForward.
@interface SEWebView : NSView
- (instancetype)initWithFrame:(NSRect)frame private:(BOOL)isPrivate;
/// An empty one for a popup Chromium is about to make (see popupWithSize).
- (instancetype)initForPopupWithFrame:(NSRect)frame private:(BOOL)isPrivate;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<SEWebViewDelegate> pageDelegate;
@property(nonatomic, readonly, copy, nullable) NSURL *URL;
@property(nonatomic, readonly, copy, nullable) NSString *title;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) double estimatedProgress;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) BOOL isPrivate;
/// 1 is 100%.
@property(nonatomic) double pageZoom;
/// Whether the page is out of sight (Chromium stops drawing it, and lets
/// its timers slow down).
@property(nonatomic) BOOL pageHidden;
/// Whether a load may give the page the keys (Chromium focuses a page it
/// navigates). Off for a page drawn out of sight, under the one in front.
@property(nonatomic) BOOL takesFocusOnLoad;
/// Shown again, whatever Chromium decided (a window covered by another app hides its pages).
- (void)insistShown;
@property(nonatomic) BOOL audioMuted;

- (void)loadURL:(NSURL *)url;
/// A page of Sill's own (an error page) shown for `url`.
- (void)loadHTML:(NSString *)html forURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
/// Stops the download this page started into `file`.
- (void)cancelDownloadTo:(NSURL *)file;
- (void)reloadFromOrigin;
- (void)stopLoading;
/// Runs `script` in the page as an expression; promises are awaited.
- (void)evaluateJavaScript:(NSString *)script completion:(void (^_Nullable)(id _Nullable result, NSError *_Nullable error))completion;
/// A picture of what the page shows, `width` points wide.
- (void)takeSnapshotWithWidth:(CGFloat)width completion:(void (^)(NSImage *_Nullable image))completion;
/// Any Chrome DevTools Protocol method on this page (Input.dispatchMouseEvent,
/// Page.captureScreenshot…): what agents drive pages with, in the background.
/// `result` is the method's answer; `error` says why there's none.
- (void)devtools:(NSString *)method params:(nullable NSDictionary *)params
      completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;
/// The same, in a child session: a frame in another process, attached with
/// Target.setAutoAttach (flatten). Nil session: the page itself.
- (void)devtools:(NSString *)method params:(nullable NSDictionary *)params session:(nullable NSString *)session
      completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;
/// Until this moment (reference-date seconds), unhandled keys are an agent's:
/// they stay in the page and never reach Sill's menus.
@property(nonatomic) NSTimeInterval agentKeysUntil;
/// Hold the page's alert/confirm/prompt dialogs for an agent to answer
/// instead of showing them (set while an agent drives the page).
@property(nonatomic) BOOL holdsDialogs;
/// The dialog waiting for an answer, if any: kind (alert, confirm, prompt, beforeunload), message, text.
@property(nonatomic, readonly, nullable) NSDictionary<NSString *, NSString *> *openDialog;
- (BOOL)answerDialog:(BOOL)accept text:(nullable NSString *)text;
- (void)dialogOpened:(nullable NSString *)kind message:(nullable NSString *)message text:(nullable NSString *)text;
/// DevTools events (method, params, the session they came from, nil for the page), on the main thread.
@property(nonatomic, copy, nullable) void (^devtoolsEvent)(NSString *method, NSDictionary *params, NSString *_Nullable session);
- (void)find:(NSString *)text forward:(BOOL)forward again:(BOOL)again;
- (void)stopFinding;
- (void)focusPage;
/// Out of the page's own full screen (a video's).
- (void)exitFullScreen;
- (void)showDevTools;
/// Downloads an address as a link's download would (into the Downloads list).
- (void)startDownload:(NSURL *)url;
- (void)print;
/// The view Chromium draws the page in (it answers the system's Services and Look Up).
@property(nonatomic, readonly, nullable) NSView *contentView;
/// Ends the page: Chromium closes it and its process lets go.
- (void)closePage;
@end

NS_ASSUME_NONNULL_END
