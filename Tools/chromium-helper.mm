// Sill on Chromium's helper: every process Chromium starts besides the
// browser itself (renderers, GPU, network, utilities) runs this. It enters
// the macOS sandbox first, then loads the engine and hands over to it.
//
// In a page's process it also gives the page one function, __sillPipFrame,
// which Sill's picture in picture uses: a video frame (RGBA bytes) and the
// video's state go to Sill through shared memory, without a copy in between.
#include <cstring>
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

class Renderer : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
    if (!frame->IsMain()) return;
    context->GetGlobal()->SetValue("__sillPipFrame", CefV8Value::CreateFunction("__sillPipFrame", new PipFrame()),
                                   V8_PROPERTY_ATTRIBUTE_DONTENUM);
  }
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
