// Sill on Chromium's helper: every process Chromium starts besides the
// browser itself (renderers, GPU, network, utilities) runs this. It enters
// the macOS sandbox first, then loads the engine and hands over to it.
//
// In a page's process it also gives the page one function, __sillPipFrame,
// which Sill's picture in picture uses: a video frame (RGBA bytes) and the
// video's state go to Sill through shared memory, without a copy in between.
#include <cstring>
#include <map>
#include <vector>
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_shared_process_message_builder.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

// What goes ahead of the pixels: Sill reads the same layout (SillEngine.mm).
struct PipHeader {
  uint32_t width, height;
  double time, duration;
  uint32_t paused, reserved;
};

class PipFrame : public CefV8Handler {
 public:
  bool Execute(const CefString&, CefRefPtr<CefV8Value>, const CefV8ValueList& args, CefRefPtr<CefV8Value>& ret,
               CefString&) override {
    ret = CefV8Value::CreateBool(false);
    if (args.size() < 6) return true;
    uint32_t w = args[1]->IsInt() || args[1]->IsDouble() ? (uint32_t)args[1]->GetDoubleValue() : 0;
    uint32_t h = args[2]->IsInt() || args[2]->IsDouble() ? (uint32_t)args[2]->GetDoubleValue() : 0;
    size_t pixels = (size_t)w * h * 4;
    // Only a frame of the size it says, and no bigger than 1920 × 1080.
    bool frame = w > 0 && h > 0 && w <= 1920 && h <= 1080 && args[0]->IsArrayBuffer() &&
                 args[0]->GetArrayBufferByteLength() == pixels;
    if (!frame) { w = h = 0; pixels = 0; }
    CefRefPtr<CefSharedProcessMessageBuilder> builder =
        CefSharedProcessMessageBuilder::Create("sill-pip", sizeof(PipHeader) + pixels);
    if (!builder || !builder->IsValid()) return true;
    auto* header = static_cast<PipHeader*>(builder->Memory());
    header->width = w;
    header->height = h;
    header->time = args[3]->IsDouble() || args[3]->IsInt() ? args[3]->GetDoubleValue() : 0;
    header->duration = args[4]->IsDouble() || args[4]->IsInt() ? args[4]->GetDoubleValue() : 0;
    header->paused = args[5]->IsBool() && args[5]->GetBoolValue();
    if (pixels) memcpy(header + 1, args[0]->GetArrayBufferData(), pixels);
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    context->GetFrame()->SendProcessMessage(PID_BROWSER, builder->Build());
    ret = CefV8Value::CreateBool(true);
    return true;
  }
  IMPLEMENT_REFCOUNTING(PipFrame);
};

// Sill's page script's messages (link hover, sign-in boxes, media…) to Sill:
// one string of JSON, as WebKit's message handler took them.
class Post : public CefV8Handler {
 public:
  bool Execute(const CefString&, CefRefPtr<CefV8Value>, const CefV8ValueList& args, CefRefPtr<CefV8Value>& ret,
               CefString&) override {
    ret = CefV8Value::CreateBool(false);
    if (args.size() < 1 || !args[0]->IsString()) return true;
    CefString text = args[0]->GetStringValue();
    if (text.length() > 64 * 1024) return true;
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create("sill-msg");
    message->GetArgumentList()->SetString(0, text);
    CefV8Context::GetCurrentContext()->GetFrame()->SendProcessMessage(PID_BROWSER, message);
    ret = CefV8Value::CreateBool(true);
    return true;
  }
  IMPLEMENT_REFCOUNTING(Post);
};

class Renderer : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  // Sill's page scripts come with each page as it's made.
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra) override {
    if (!extra || !extra->HasKey("sill-scripts")) return;
    CefRefPtr<CefListValue> list = extra->GetList("sill-scripts");
    std::vector<CefString>& scripts = scripts_[browser->GetIdentifier()];
    for (size_t i = 0; i < list->GetSize(); i++) scripts.push_back(list->GetString(i));
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override { scripts_.erase(browser->GetIdentifier()); }

  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
    if (!frame->IsMain()) return;
    context->GetGlobal()->SetValue("__sillPipFrame", CefV8Value::CreateFunction("__sillPipFrame", new PipFrame()),
                                   V8_PROPERTY_ATTRIBUTE_DONTENUM);
    context->GetGlobal()->SetValue("__sillPost", CefV8Value::CreateFunction("__sillPost", new Post()),
                                   static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_DONTENUM | V8_PROPERTY_ATTRIBUTE_READONLY |
                                                                          V8_PROPERTY_ATTRIBUTE_DONTDELETE));
    // Then Sill's own scripts, in the page's world, before any of the page's:
    // web pages only (not Sill's own or an extension's), and each runs once a
    // document (they check for themselves; extensions' worlds start here too).
    std::string url = frame->GetURL().ToString();
    bool web = url.rfind("http:", 0) == 0 || url.rfind("https:", 0) == 0 || url.rfind("file:", 0) == 0;
    auto found = scripts_.find(browser->GetIdentifier());
    if (!web || found == scripts_.end()) return;
    for (const CefString& script : found->second) frame->ExecuteJavaScript(script, frame->GetURL(), 0);
  }

 private:
  std::map<int, std::vector<CefString>> scripts_;
  IMPLEMENT_REFCOUNTING(Renderer);
};

}  // namespace

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader library;
  if (!library.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  CefRefPtr<Renderer> app(new Renderer());
  return CefExecuteProcess(args, app.get(), nullptr);
}
