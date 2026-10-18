#include "echoprompt_window_plugin.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <vector>

#include <shellapi.h>

#include <string>
#include <wchar.h>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace echoprompt_window {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

double AsDouble(const EncodableValue &v, double fallback) {
  if (const auto *d = std::get_if<double>(&v)) return *d;
  if (const auto *i = std::get_if<int32_t>(&v)) return *i;
  if (const auto *l = std::get_if<int64_t>(&v)) return static_cast<double>(*l);
  return fallback;
}

// WDA_EXCLUDEFROMCAPTURE needs Windows 10 version 2004 (build 19041).
bool SupportsExcludeFromCapture() {
  using RtlGetVersionFn = LONG(WINAPI *)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) return false;
  auto fn = reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));
  if (!fn) return false;
  RTL_OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (fn(&info) != 0) return false;
  return info.dwMajorVersion > 10 || (info.dwMajorVersion == 10 && info.dwBuildNumber >= 19041);
}

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr int kTrayCommandBase = 1000;
constexpr int kHotkeyIdBase = 0x4550;
constexpr WORD kAppIconResource = 101;  // IDI_APP_ICON in the runner's resource.h

std::wstring Widen(const std::string &s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

const EncodableValue *FindValue(const EncodableMap &m, const char *key) {
  auto it = m.find(EncodableValue(key));
  return it == m.end() ? nullptr : &it->second;
}

std::string StringOf(const EncodableMap &m, const char *key) {
  if (const auto *v = FindValue(m, key)) if (const auto *s = std::get_if<std::string>(v)) return *s;
  return std::string();
}

bool BoolOf(const EncodableMap &m, const char *key, bool fallback) {
  if (const auto *v = FindValue(m, key)) if (const auto *b = std::get_if<bool>(v)) return *b;
  return fallback;
}

const EncodableList *ListOf(const EncodableValue *args, const char *key) {
  const auto *m = args ? std::get_if<EncodableMap>(args) : nullptr;
  if (!m) return nullptr;
  const auto *v = FindValue(*m, key);
  return v ? std::get_if<EncodableList>(v) : nullptr;
}

// Key names shared with the Dart side: space, up, down, left, right, a-z, 0-9.
bool KeyToVirtualKey(const std::string &key, UINT *vk) {
  if (key == "space") { *vk = VK_SPACE; return true; }
  if (key == "up") { *vk = VK_UP; return true; }
  if (key == "down") { *vk = VK_DOWN; return true; }
  if (key == "left") { *vk = VK_LEFT; return true; }
  if (key == "right") { *vk = VK_RIGHT; return true; }
  if (key.size() == 1 && key[0] >= 'a' && key[0] <= 'z') {
    *vk = static_cast<UINT>(key[0] - 'a' + 'A');
    return true;
  }
  if (key.size() == 1 && key[0] >= '0' && key[0] <= '9') {
    *vk = static_cast<UINT>(key[0]);
    return true;
  }
  return false;
}

}  // namespace

void EchopromptWindowPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<EchopromptWindowPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

EchopromptWindowPlugin::EchopromptWindowPlugin(flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "com.echoprompt/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return WindowProc(hwnd, message, wparam, lparam);
      });
}

EchopromptWindowPlugin::~EchopromptWindowPlugin() {
  UnregisterHotkeys();
  RemoveTray();
  registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_);
}

HWND EchopromptWindowPlugin::Hwnd() const {
  auto *view = registrar_->GetView();
  return view ? GetAncestor(view->GetNativeWindow(), GA_ROOT) : nullptr;
}

void EchopromptWindowPlugin::ParseOptions(const EncodableValue *args) {
  const auto *m = args ? std::get_if<EncodableMap>(args) : nullptr;
  if (!m) return;
  auto get = [&](const char *k) -> const EncodableValue * {
    auto it = m->find(EncodableValue(k));
    return it == m->end() ? nullptr : &it->second;
  };
  if (auto *v = get("placement")) if (auto *s = std::get_if<std::string>(v)) opt_.placement = *s;
  if (auto *v = get("corner")) if (auto *s = std::get_if<std::string>(v)) opt_.corner = *s;
  if (auto *v = get("hideFromCapture")) if (auto *b = std::get_if<bool>(v)) opt_.hide_from_capture = *b;
  if (auto *v = get("notchWidth")) opt_.notch_w = AsDouble(*v, opt_.notch_w);
  if (auto *v = get("notchHeight")) opt_.notch_h = AsDouble(*v, opt_.notch_h);
  if (auto *v = get("cornerWidth")) opt_.corner_w = AsDouble(*v, opt_.corner_w);
  if (auto *v = get("cornerHeight")) opt_.corner_h = AsDouble(*v, opt_.corner_h);
  opt_.has_floating = false;
  if (auto *v = get("floatingFrame")) {
    if (auto *l = std::get_if<EncodableList>(v); l && l->size() == 4) {
      opt_.has_floating = true;
      opt_.fx = AsDouble((*l)[0], 0);
      opt_.fy = AsDouble((*l)[1], 0);
      opt_.fw = AsDouble((*l)[2], 900);
      opt_.fh = AsDouble((*l)[3], 360);
    }
  }
}

void EchopromptWindowPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto &name = call.method_name();
  if (name == "enterPrompter") {
    ParseOptions(call.arguments());
    notch_extra_ = -1;
    Enter();
    result->Success();
  } else if (name == "update") {
    ParseOptions(call.arguments());
    notch_extra_ = -1;
    if (in_prompter_) Apply();
    result->Success();
  } else if (name == "exitPrompter") {
    Exit();
    result->Success();
  } else if (name == "gestureBegin") {
    if (HWND h = Hwnd()) {
      GetWindowRect(h, &gesture_rect_);
      GetCursorPos(&gesture_mouse_);
      gesture_extra_ = notch_extra_ >= 0 ? notch_extra_ : opt_.notch_h;
      gesture_active_ = true;
    }
    result->Success();
  } else if (name == "dragUpdate") {
    if (HWND h = Hwnd(); h && gesture_active_) {
      POINT m;
      GetCursorPos(&m);
      applying_ = true;
      SetWindowPos(h, HWND_TOPMOST, gesture_rect_.left + m.x - gesture_mouse_.x,
                   gesture_rect_.top + m.y - gesture_mouse_.y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE);
      applying_ = false;
    }
    result->Success();
  } else if (name == "resizeUpdate") {
    std::string edge = "br";
    if (call.arguments()) if (auto *s = std::get_if<std::string>(call.arguments())) edge = *s;
    ResizeUpdate(edge);
    result->Success();
  } else if (name == "gestureEnd") {
    gesture_active_ = false;
    OnExitSizeMove();
    result->Success();
  } else if (name == "supportsCaptureHiding") {
    result->Success(EncodableValue(SupportsExcludeFromCapture()));
  } else if (name == "hasHardwareNotch") {
    result->Success(EncodableValue(false));
  } else if (name == "setTrayMenu") {
    result->Success(EncodableValue(SetTrayMenu(call.arguments())));
  } else if (name == "registerHotkeys") {
    result->Success(EncodableValue(RegisterHotkeys(call.arguments())));
  } else if (name == "unregisterHotkeys") {
    UnregisterHotkeys();
    result->Success();
  } else if (name == "setPrompterVisible") {
    bool visible = true;
    if (call.arguments()) if (auto *b = std::get_if<bool>(call.arguments())) visible = *b;
    if (HWND h = Hwnd(); h && in_prompter_) ShowWindow(h, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void EchopromptWindowPlugin::ResizeUpdate(const std::string &edge) {
  HWND hwnd = Hwnd();
  if (!hwnd || !gesture_active_) return;
  POINT m;
  GetCursorPos(&m);
  const double scale = GetDpiForWindow(hwnd) / 96.0;
  const int dx = m.x - gesture_mouse_.x, dy = m.y - gesture_mouse_.y;
  if (opt_.placement == "notch") {
    notch_extra_ = std::clamp(gesture_extra_ + dy / scale, 80.0, 400.0);
    Apply();
    return;
  }
  RECT r = gesture_rect_;
  const int min_w = static_cast<int>(std::lround((opt_.placement == "corner" ? 300 : 360) * scale));
  const int min_h = static_cast<int>(std::lround((opt_.placement == "corner" ? 160 : 200) * scale));
  int left = r.left, right = r.right, bottom = r.bottom;
  if (edge.find('r') != std::string::npos) right = std::max<int>(r.left + min_w, r.right + dx);
  if (edge.find('l') != std::string::npos) left = std::min<int>(r.right - min_w, r.left + dx);
  if (edge.find('b') != std::string::npos) bottom = std::max<int>(r.top + min_h, r.bottom + dy);
  applying_ = true;
  SetWindowPos(hwnd, HWND_TOPMOST, left, r.top, right - left, bottom - r.top, SWP_NOACTIVATE);
  applying_ = false;
}

void EchopromptWindowPlugin::Enter() {
  HWND hwnd = Hwnd();
  if (!hwnd) return;
  if (!in_prompter_) {
    studio_style_ = GetWindowLong(hwnd, GWL_STYLE);
    studio_exstyle_ = GetWindowLong(hwnd, GWL_EXSTYLE);
    GetWindowPlacement(hwnd, &studio_placement_);
    // A maximized Studio must become a normal window before applying overlay
    // bounds. Otherwise Win32 retains its maximized geometry/style.
    if (IsZoomed(hwnd) || IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
    in_prompter_ = true;
  }
  LONG style = studio_style_ & ~(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_MAXIMIZE | WS_MINIMIZE);
  style |= WS_POPUP;
  SetWindowLong(hwnd, GWL_STYLE, style);
  // Capture visibility first: some tools snapshot the window list at start.
  ApplyCapture(hwnd);
  Apply();
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
}

void EchopromptWindowPlugin::Exit() {
  HWND hwnd = Hwnd();
  if (!hwnd || !in_prompter_) return;
  in_prompter_ = false;
  SetWindowDisplayAffinity(hwnd, WDA_NONE);
  SetWindowLong(hwnd, GWL_STYLE, studio_style_ & ~(WS_MAXIMIZE | WS_MINIMIZE));
  SetWindowLong(hwnd, GWL_EXSTYLE, studio_exstyle_);
  SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  SetWindowPlacement(hwnd, &studio_placement_);
  SetForegroundWindow(hwnd);
}

void EchopromptWindowPlugin::ApplyCapture(HWND hwnd) {
  // Best effort: older Windows 10 builds fall back to visible.
  if (opt_.hide_from_capture && SupportsExcludeFromCapture()) {
    SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  } else {
    SetWindowDisplayAffinity(hwnd, WDA_NONE);
  }
  LONG ex = GetWindowLong(hwnd, GWL_EXSTYLE);
  ex |= WS_EX_TOOLWINDOW;  // keep out of Alt-Tab / taskbar while presenting
  SetWindowLong(hwnd, GWL_EXSTYLE, ex);
}

void EchopromptWindowPlugin::Apply() {
  HWND hwnd = Hwnd();
  if (!hwnd) return;
  ApplyCapture(hwnd);

  HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{sizeof(mi)};
  GetMonitorInfo(mon, &mi);
  const RECT wa = mi.rcWork;
  const double scale = GetDpiForWindow(hwnd) / 96.0;
  auto px = [&](double v) { return static_cast<int>(std::lround(v * scale)); };
  const int work_w = wa.right - wa.left, work_h = wa.bottom - wa.top;

  int x, y, w, h;
  if (opt_.placement == "notch") {
    // Windows has no notch: dock at top centre, next to the webcam.
    w = (std::min)(work_w, px(opt_.notch_w));
    h = px(notch_extra_ >= 0 ? notch_extra_ : opt_.notch_h);
    x = wa.left + (work_w - w) / 2;
    y = wa.top;
  } else if (opt_.placement == "corner") {
    w = std::clamp(px(opt_.corner_w), px(300), static_cast<int>(work_w * 0.6));
    h = std::clamp(px(opt_.corner_h), px(160), static_cast<int>(work_h * 0.6));
    const int m = px(16);
    const bool left = opt_.corner.size() >= 4 && opt_.corner.substr(opt_.corner.size() - 4) == "Left";
    const bool top = opt_.corner.rfind("top", 0) == 0;
    x = left ? wa.left + m : wa.right - m - w;
    y = top ? wa.top + m : wa.bottom - m - h;
  } else {
    if (opt_.has_floating) {
      w = px(opt_.fw); h = px(opt_.fh);
      x = mi.rcMonitor.left + px(opt_.fx);
      y = mi.rcMonitor.top + px(opt_.fy);
    } else {
      w = (std::min)(px(900), work_w * 9 / 10);
      h = (std::min)(px(360), work_h * 9 / 10);
      x = wa.left + (work_w - w) / 2;
      y = wa.top + px(40);
    }
    w = std::clamp(w, (std::min)(px(360), work_w * 9 / 10), work_w * 9 / 10);
    h = std::clamp(h, (std::min)(px(200), work_h * 9 / 10), work_h * 9 / 10);
    // Keep at least 80 x 40 dips reachable after display changes.
    x = std::clamp(x, static_cast<int>(wa.left) - w + px(80), static_cast<int>(wa.right) - px(80));
    y = std::clamp(y, static_cast<int>(wa.top) - h + px(40), static_cast<int>(wa.bottom) - h);
  }
  applying_ = true;
  SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SWP_FRAMECHANGED | SWP_NOACTIVATE);
  applying_ = false;
}

void EchopromptWindowPlugin::SendToDart(const char *method, const std::string &value) {
  channel_->InvokeMethod(method, std::make_unique<EncodableValue>(value));
}

// Shows the notification-area icon with [args].items, or removes it when there
// are none. Returns whether the icon is showing.
bool EchopromptWindowPlugin::SetTrayMenu(const EncodableValue *args) {
  const EncodableList *list = ListOf(args, "items");
  if (!list) {
    RemoveTray();
    return false;
  }
  HWND hwnd = Hwnd();
  if (!hwnd) return false;
  tray_items_.clear();
  int next = 0;
  for (const auto &v : *list) {
    const auto *e = std::get_if<EncodableMap>(&v);
    if (!e) continue;
    TrayEntry t;
    t.command = kTrayCommandBase + next++;
    t.id = StringOf(*e, "id");
    t.title = StringOf(*e, "title");
    t.enabled = BoolOf(*e, "enabled", true);
    t.checked = BoolOf(*e, "checked", false);
    t.separator = BoolOf(*e, "separator", false);
    tray_items_.push_back(t);
  }
  if (!tray_added_) {
    tray_data_ = NOTIFYICONDATAW{};
    tray_data_.cbSize = sizeof(NOTIFYICONDATAW);
    tray_data_.hWnd = hwnd;
    tray_data_.uID = kTrayIconId;
    tray_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray_data_.uCallbackMessage = kTrayMessage;
    HICON icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(kAppIconResource));
    if (!icon) icon = LoadIconW(nullptr, IDI_APPLICATION);
    tray_data_.hIcon = icon;
    wcscpy_s(tray_data_.szTip, L"EchoPrompt");
    tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_data_) == TRUE;
  }
  return tray_added_;
}

void EchopromptWindowPlugin::RemoveTray() {
  if (tray_added_) Shell_NotifyIconW(NIM_DELETE, &tray_data_);
  tray_added_ = false;
  tray_items_.clear();
}

void EchopromptWindowPlugin::ShowTrayMenu(HWND hwnd) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  for (const auto &t : tray_items_) {
    if (t.separator) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    UINT flags = MF_STRING | (t.enabled ? MF_ENABLED : MF_GRAYED) | (t.checked ? MF_CHECKED : MF_UNCHECKED);
    AppendMenuW(menu, flags, static_cast<UINT_PTR>(t.command), Widen(t.title).c_str());
  }
  POINT pt{};
  GetCursorPos(&pt);
  // Without this the menu would not close when the user clicks elsewhere.
  SetForegroundWindow(hwnd);
  const int chosen = static_cast<int>(TrackPopupMenu(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, nullptr));
  PostMessageW(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  for (const auto &t : tray_items_) {
    if (t.command == chosen) {
      SendToDart("trayAction", t.id);
      break;
    }
  }
}

// Registers system-wide shortcuts. Returns { id: registered }.
EncodableMap EchopromptWindowPlugin::RegisterHotkeys(const EncodableValue *args) {
  UnregisterHotkeys();
  EncodableMap outcome;
  const EncodableList *list = ListOf(args, "bindings");
  if (!list) return outcome;
  HWND hwnd = Hwnd();
  int next = 0;
  for (const auto &v : *list) {
    const auto *e = std::get_if<EncodableMap>(&v);
    if (!e) continue;
    const std::string id = StringOf(*e, "id");
    UINT mods = MOD_NOREPEAT;
    if (const auto *mv = FindValue(*e, "mods")) {
      if (const auto *ml = std::get_if<EncodableList>(mv)) {
        for (const auto &m : *ml) {
          const auto *name = std::get_if<std::string>(&m);
          if (!name) continue;
          if (*name == "ctrl") mods |= MOD_CONTROL;
          else if (*name == "alt") mods |= MOD_ALT;
          else if (*name == "shift") mods |= MOD_SHIFT;
          else if (*name == "meta") mods |= MOD_WIN;
        }
      }
    }
    UINT vk = 0;
    bool ok = hwnd != nullptr && KeyToVirtualKey(StringOf(*e, "key"), &vk);
    if (ok) {
      const int hotkey_id = kHotkeyIdBase + next++;
      ok = RegisterHotKey(hwnd, hotkey_id, mods, vk) != 0;
      if (ok) hotkeys_.emplace_back(hotkey_id, id);
    }
    outcome[EncodableValue(id)] = EncodableValue(ok);
  }
  return outcome;
}

void EchopromptWindowPlugin::UnregisterHotkeys() {
  HWND hwnd = Hwnd();
  if (hwnd) {
    for (const auto &h : hotkeys_) UnregisterHotKey(hwnd, h.first);
  }
  hotkeys_.clear();
}

std::optional<LRESULT> EchopromptWindowPlugin::WindowProc(HWND hwnd, UINT message,
                                                          WPARAM wparam, LPARAM lparam) {
  if (hwnd == Hwnd()) {
    if (message == kTrayMessage) {
      const UINT tray_event = LOWORD(lparam);
      if (tray_event == WM_LBUTTONUP || tray_event == WM_RBUTTONUP || tray_event == WM_CONTEXTMENU) ShowTrayMenu(hwnd);
      return 0;
    }
    if (message == WM_HOTKEY) {
      for (const auto &h : hotkeys_) {
        if (h.first == static_cast<int>(wparam)) {
          SendToDart("hotkey", h.second);
          break;
        }
      }
      return 0;
    }
  }
  if (in_prompter_ && !applying_ && hwnd == Hwnd()) {
    if (message == WM_EXITSIZEMOVE) OnExitSizeMove();
    // Display hot-plug / DPI changes: re-apply the placement.
    if (message == WM_DISPLAYCHANGE || message == WM_DPICHANGED) Apply();
  }
  return std::nullopt;
}

void EchopromptWindowPlugin::OnExitSizeMove() {
  HWND hwnd = Hwnd();
  if (!hwnd) return;
  if (opt_.placement == "notch") {
    EncodableMap p;
    p[EncodableValue("display")] = EncodableValue(std::string("0"));
    p[EncodableValue("frame")] = EncodableValue(EncodableList{EncodableValue(0.0), EncodableValue(0.0), EncodableValue(0.0), EncodableValue(0.0)});
    p[EncodableValue("notchHeight")] = EncodableValue(notch_extra_ >= 0 ? notch_extra_ : opt_.notch_h);
    channel_->InvokeMethod("frameChanged", std::make_unique<EncodableValue>(p));
    return;
  }
  HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{sizeof(mi)};
  GetMonitorInfo(mon, &mi);
  RECT r;
  GetWindowRect(hwnd, &r);
  const double scale = GetDpiForWindow(hwnd) / 96.0;

  EncodableMap payload;
  if (opt_.placement == "corner") {
    const bool left = (r.left + r.right) / 2 < (mi.rcWork.left + mi.rcWork.right) / 2;
    const bool top = (r.top + r.bottom) / 2 < (mi.rcWork.top + mi.rcWork.bottom) / 2;
    opt_.corner = std::string(top ? "top" : "bottom") + (left ? "Left" : "Right");
    payload[EncodableValue("corner")] = EncodableValue(opt_.corner);
    Apply();
    GetWindowRect(hwnd, &r);
  }
  payload[EncodableValue("display")] = EncodableValue(std::to_string(reinterpret_cast<uintptr_t>(mon)));
  payload[EncodableValue("frame")] = EncodableValue(EncodableList{
      EncodableValue((r.left - mi.rcMonitor.left) / scale),
      EncodableValue((r.top - mi.rcMonitor.top) / scale),
      EncodableValue((r.right - r.left) / scale),
      EncodableValue((r.bottom - r.top) / scale)});
  channel_->InvokeMethod("frameChanged", std::make_unique<EncodableValue>(payload));
}

}  // namespace echoprompt_window
