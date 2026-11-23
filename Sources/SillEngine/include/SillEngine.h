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
+ (BOOL)startWithProfile:(NSString *)profile;
/// Runs `block` once Chromium is ready for pages (at once if it is).
+ (void)whenReady:(void (^)(void))block;
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
@end

/// One item of a page's right-click menu, as Chromium offers it.
@interface SEMenuItem : NSObject
@property(nonatomic, readonly) NSInteger commandID;   // -1 for a separator
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) BOOL enabled, checked;
@end

@class SEWebView;

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
/// Its right-click menu: show it, then call `choose` with the item picked, or -1.
- (void)webView:(SEWebView *)view menu:(NSArray<SEMenuItem *> *)items at:(NSPoint)point choose:(void (^)(NSInteger commandID))choose;
- (void)webViewProcessEnded:(SEWebView *)view;
/// A file the page is downloading: where it goes is decided here.
- (nullable NSURL *)webView:(SEWebView *)view downloadNamed:(NSString *)name;
- (void)webView:(SEWebView *)view download:(NSURL *)file progress:(double)progress done:(BOOL)done;
/// A video frame for picture in picture, as the page sent it (RGBA, 4 bytes
/// a pixel, rows packed), with the video's state; `rgba` is NULL (and the
/// size 0) when only the state changed. Valid only during the call.
- (void)webView:(SEWebView *)view videoFrame:(const void *_Nullable)rgba width:(NSInteger)width height:(NSInteger)height
           time:(double)time duration:(double)duration paused:(BOOL)paused;
/// A key the page didn't take (⌘-shortcuts reach the menus this way).
- (BOOL)webView:(SEWebView *)view unhandledKey:(NSEvent *)event;
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
@property(nonatomic) BOOL audioMuted;

- (void)loadURL:(NSURL *)url;
/// A page of Sill's own (an error page) shown for `url`.
- (void)loadHTML:(NSString *)html forURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadFromOrigin;
- (void)stopLoading;
/// Runs `script` in the page as an expression; promises are awaited.
- (void)evaluateJavaScript:(NSString *)script completion:(void (^_Nullable)(id _Nullable result, NSError *_Nullable error))completion;
/// A picture of what the page shows, `width` points wide.
- (void)takeSnapshotWithWidth:(CGFloat)width completion:(void (^)(NSImage *_Nullable image))completion;
- (void)find:(NSString *)text forward:(BOOL)forward again:(BOOL)again;
- (void)stopFinding;
- (void)focusPage;
- (void)showDevTools;
/// Ends the page: Chromium closes it and its process lets go.
- (void)closePage;
@end

NS_ASSUME_NONNULL_END
