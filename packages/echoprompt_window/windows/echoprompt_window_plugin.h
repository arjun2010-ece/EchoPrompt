#ifndef FLUTTER_PLUGIN_ECHOPROMPT_WINDOW_PLUGIN_H_
#define FLUTTER_PLUGIN_ECHOPROMPT_WINDOW_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace echoprompt_window {

// Switches the single Flutter window between Studio and Prompter (top-most,
// borderless, hidden from capture).
class EchopromptWindowPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit EchopromptWindowPlugin(flutter::PluginRegistrarWindows *registrar);
  virtual ~EchopromptWindowPlugin();

  EchopromptWindowPlugin(const EchopromptWindowPlugin &) = delete;
  EchopromptWindowPlugin &operator=(const EchopromptWindowPlugin &) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  struct Options {
    std::string placement = "floating";
    std::string corner = "topRight";
    bool hide_from_capture = true;
    double notch_w = 420, notch_h = 90, corner_w = 420, corner_h = 240;
    bool has_floating = false;
    double fx = 0, fy = 0, fw = 0, fh = 0;
  };

  // One row of the notification-area menu; [command] is its Win32 menu id.
  struct TrayEntry {
    int command = 0;
    std::string id;
    std::string title;
    bool enabled = true;
    bool checked = false;
    bool separator = false;
  };

  HWND Hwnd() const;
  bool SetTrayMenu(const flutter::EncodableValue *args);
  void RemoveTray();
  void ShowTrayMenu(HWND hwnd);
  flutter::EncodableMap RegisterHotkeys(const flutter::EncodableValue *args);
  void UnregisterHotkeys();
  void SendToDart(const char *method, const std::string &value);
  void ParseOptions(const flutter::EncodableValue *args);
  void Enter();
  void Exit();
  void Apply();
  void ApplyCapture(HWND hwnd);
  void OnExitSizeMove();
  void ResizeUpdate(const std::string &edge);
  std::optional<LRESULT> WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam);

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int proc_id_ = -1;
  Options opt_;
  bool in_prompter_ = false;
  bool applying_ = false;
  double notch_extra_ = -1;
  LONG studio_style_ = 0, studio_exstyle_ = 0;
  WINDOWPLACEMENT studio_placement_{sizeof(WINDOWPLACEMENT)};
  RECT gesture_rect_{};
  POINT gesture_mouse_{};
  double gesture_extra_ = 150;
  bool gesture_active_ = false;
  NOTIFYICONDATAW tray_data_{};
  bool tray_added_ = false;
  std::vector<TrayEntry> tray_items_;
  std::vector<std::pair<int, std::string>> hotkeys_;  // Win32 hotkey id -> name
};

}  // namespace echoprompt_window

#endif  // FLUTTER_PLUGIN_ECHOPROMPT_WINDOW_PLUGIN_H_
