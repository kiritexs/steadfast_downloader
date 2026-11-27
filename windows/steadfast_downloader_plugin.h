#ifndef FLUTTER_PLUGIN_STEADFAST_DOWNLOADER_PLUGIN_H_
#define FLUTTER_PLUGIN_STEADFAST_DOWNLOADER_PLUGIN_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>
#include <string>

namespace steadfast_downloader {

// Keeps Windows from sleeping by itself while downloads run, and tells Dart
// when the system sleeps and wakes.
class SteadfastDownloaderPlugin : public flutter::Plugin {
 public:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;

  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  SteadfastDownloaderPlugin(flutter::PluginRegistrarWindows *registrar,
                          std::unique_ptr<Channel> channel);

  virtual ~SteadfastDownloaderPlugin();

  SteadfastDownloaderPlugin(const SteadfastDownloaderPlugin &) = delete;
  SteadfastDownloaderPlugin &operator=(const SteadfastDownloaderPlugin &) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // WM_POWERBROADCAST: suspend and resume go to Dart. The message is never
  // handled here, so the runner and other plugins still see it.
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);

  bool Hold(const std::wstring &reason);
  void Release();

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<Channel> channel_;
  int window_proc_id_ = -1;
  HANDLE request_ = nullptr;
  std::wstring reason_;
  bool held_ = false;
};

}  // namespace steadfast_downloader

#endif  // FLUTTER_PLUGIN_STEADFAST_DOWNLOADER_PLUGIN_H_
