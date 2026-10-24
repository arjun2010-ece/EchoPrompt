#include "include/echoprompter_window/echoprompter_window_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "echoprompter_window_plugin.h"

void EchoprompterWindowPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  echoprompter_window::EchoprompterWindowPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
