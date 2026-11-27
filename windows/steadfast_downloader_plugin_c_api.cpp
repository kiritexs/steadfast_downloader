#include "include/steadfast_downloader/steadfast_downloader_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "steadfast_downloader_plugin.h"

void SteadfastDownloaderPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  steadfast_downloader::SteadfastDownloaderPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
