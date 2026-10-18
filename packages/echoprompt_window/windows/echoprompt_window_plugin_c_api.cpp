#include "include/echoprompt_window/echoprompt_window_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "echoprompt_window_plugin.h"

void EchopromptWindowPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  echoprompt_window::EchopromptWindowPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
