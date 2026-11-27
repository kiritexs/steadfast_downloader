#include "steadfast_downloader_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

namespace steadfast_downloader {

namespace {

std::wstring Widen(const std::string &utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = static_cast<int>(utf8.size());
  const int length =
      MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, wide.data(), length);
  return wide;
}

// The notice's title is the power request's reason.
std::string ReasonFrom(const flutter::EncodableValue *arguments) {
  const auto *map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return std::string();
  const auto found = map->find(flutter::EncodableValue("title"));
  if (found == map->end()) return std::string();
  const auto *text = std::get_if<std::string>(&found->second);
  return text == nullptr ? std::string() : *text;
}

}  // namespace

// static
void SteadfastDownloaderPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel = std::make_unique<Channel>(
      registrar->messenger(), "steadfast_downloader/keep_alive",
      &flutter::StandardMethodCodec::GetInstance());
  registrar->AddPlugin(
      std::make_unique<SteadfastDownloaderPlugin>(registrar, std::move(channel)));
}

SteadfastDownloaderPlugin::SteadfastDownloaderPlugin(
    flutter::PluginRegistrarWindows *registrar,
    std::unique_ptr<Channel> channel)
    : registrar_(registrar), channel_(std::move(channel)) {
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

SteadfastDownloaderPlugin::~SteadfastDownloaderPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  Release();
  if (request_ != nullptr) CloseHandle(request_);
}

void SteadfastDownloaderPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string &method = method_call.method_name();
  if (method == "hold") {
    const bool held = Hold(Widen(ReasonFrom(method_call.arguments())));
    result->Success(
        flutter::EncodableValue(std::string(held ? "held" : "refused")));
  } else if (method == "release") {
    Release();
    result->Success();
  } else if (method == "update") {
    // Nothing is shown on Windows; the reason stays the first one.
    result->Success();
  } else {
    result->NotImplemented();
  }
}

std::optional<LRESULT> SteadfastDownloaderPlugin::HandleWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) {
      channel_->InvokeMethod("suspending", nullptr);
    } else if (wparam == PBT_APMRESUMEAUTOMATIC ||
               wparam == PBT_APMRESUMESUSPEND) {
      // Both can come for one wake; resuming in Dart is idempotent.
      channel_->InvokeMethod("resumed", nullptr);
    }
  }
  return std::nullopt;
}

// A power request (system required) keeps Windows from sleeping by itself;
// the user can still put it to sleep. Unlike SetThreadExecutionState it is
// its own handle, so the player's keep-awake can't cancel it, and
// `powercfg /requests` shows its reason.
bool SteadfastDownloaderPlugin::Hold(const std::wstring &reason) {
  if (held_) return true;
  if (request_ != nullptr) {
    CloseHandle(request_);
    request_ = nullptr;
  }
  reason_ = reason.empty() ? L"Downloading" : reason;
  REASON_CONTEXT context{};
  context.Version = POWER_REQUEST_CONTEXT_VERSION;
  context.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
  context.Reason.SimpleReasonString = reason_.data();
  const HANDLE created = PowerCreateRequest(&context);
  if (created == INVALID_HANDLE_VALUE) return false;
  request_ = created;
  held_ = PowerSetRequest(request_, PowerRequestSystemRequired) != FALSE;
  return held_;
}

void SteadfastDownloaderPlugin::Release() {
  if (held_) PowerClearRequest(request_, PowerRequestSystemRequired);
  held_ = false;
}

}  // namespace steadfast_downloader
