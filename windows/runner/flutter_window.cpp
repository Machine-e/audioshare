#include "flutter_window.h"

#include <shellapi.h>

#include <optional>
#include <utility>

#include "external_route_channel.h"
#include "flutter/generated_plugin_registrant.h"
#include "preferences_channel.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayShowCommand = 1001;
constexpr UINT kTrayExitCommand = 1002;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // Win32Window::Create calls Destroy before creating the first window.
  destroying_ = false;
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  external_route_channel_cleanup_ =
      RegisterExternalRouteChannel(flutter_controller_->engine()->messenger());
  preferences_channel_cleanup_ =
      RegisterPreferencesChannel(flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (destroying_) {
    return;
  }
  destroying_ = true;
  RemoveTrayIcon();
  if (auto cleanup = std::exchange(preferences_channel_cleanup_, nullptr)) {
    cleanup();
  }
  if (auto cleanup = std::exchange(external_route_channel_cleanup_, nullptr)) {
    cleanup();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  tray_window_ = data.hWnd;
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"AudioShare Bluetooth receiver");
  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  if (tray_icon_added_) {
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);
  }
  return tray_icon_added_;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = tray_window_;
  data.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kTrayShowCommand, L"显示 AudioShare");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"退出并停止接收");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (command == kTrayShowCommand) ShowFromTray();
  if (command == kTrayExitCommand) DestroyWindow(GetHandle());
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE: {
      if (close_prompt_open_ || destroying_) return 0;
      close_prompt_open_ = true;
      const int choice = MessageBoxW(
          hwnd,
          L"是否保留在托盘中继续接收音频？\n\n"
          L"是：隐藏窗口，继续接收。\n"
          L"否：退出应用，停止接收。\n"
          L"取消：返回窗口。",
          L"关闭 AudioShare", MB_YESNOCANCEL | MB_ICONQUESTION | MB_DEFBUTTON1);
      close_prompt_open_ = false;
      if (choice == IDYES) {
        if (tray_icon_added_ || AddTrayIcon()) {
          ShowWindow(hwnd, SW_HIDE);
        } else {
          MessageBoxW(hwnd,
                      L"无法创建托盘图标，窗口将保持打开。",
                      L"AudioShare", MB_OK | MB_ICONERROR);
        }
      } else if (choice == IDNO) {
        DestroyWindow(hwnd);
      }
      return 0;
    }
    case kTrayMessage:
      if (LOWORD(lparam) == NIN_SELECT || LOWORD(lparam) == NIN_KEYSELECT ||
          LOWORD(lparam) == WM_LBUTTONDBLCLK) ShowFromTray();
      if (LOWORD(lparam) == WM_CONTEXTMENU || LOWORD(lparam) == WM_RBUTTONUP)
        ShowTrayMenu();
      return 0;
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    if (!AddTrayIcon()) ShowFromTray();
    return 0;
  }

  if (flutter_controller_) {
    const auto result = flutter_controller_->HandleTopLevelWindowProc(
        hwnd, message, wparam, lparam);
    if (result) return *result;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
