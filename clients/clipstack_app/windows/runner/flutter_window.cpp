#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuQuit = 2;

// Where ClipStack remembers that the "still running" hint was shown.
constexpr wchar_t kSettingsKey[] = L"Software\\Silifton\\ClipStack";
constexpr wchar_t kHintShownValue[] = L"TrayHintShown";

UINT TaskbarCreatedMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"TaskbarCreated");
  return message;
}

UINT ShowMessage() {
  static const UINT message = ::RegisterWindowMessageW(kShowMessageName);
  return message;
}

bool TrayHintShown() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  return ::RegGetValueW(HKEY_CURRENT_USER, kSettingsKey, kHintShownValue,
                        RRF_RT_REG_DWORD, nullptr, &value,
                        &size) == ERROR_SUCCESS &&
         value != 0;
}

void SetTrayHintShown() {
  DWORD value = 1;
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kSettingsKey, kHintShownValue,
                    REG_DWORD, &value, sizeof(value));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  AddTrayIcon();
  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::AddTrayIcon() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = hwnd;
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  wcscpy_s(tray_icon_.szTip, L"ClipStack");
  tray_added_ = ::Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_added_) {
    ::Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_added_ = false;
  }
  if (tray_icon_.hIcon) {
    ::DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  HMENU menu = ::CreatePopupMenu();
  if (!menu) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kMenuOpen, L"Open ClipStack");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuQuit, L"Quit ClipStack");
  ::SetMenuDefaultItem(menu, kMenuOpen, FALSE);

  POINT cursor;
  ::GetCursorPos(&cursor);
  // Without this the menu doesn't close when you click somewhere else.
  ::SetForegroundWindow(hwnd);
  const UINT command = ::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      cursor.x, cursor.y, 0, hwnd, nullptr);
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  if (command == kMenuOpen) {
    ShowFromTray();
  } else if (command == kMenuQuit) {
    Quit();
  }
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  start_hidden_ = false;
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(hwnd);
}

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  ::ShowWindow(hwnd, SW_HIDE);
  // Once, ever: tell people where the window went.
  if (tray_added_ && !TrayHintShown()) {
    NOTIFYICONDATAW hint = tray_icon_;
    hint.uFlags = NIF_INFO;
    hint.dwInfoFlags = NIIF_INFO;
    wcscpy_s(hint.szInfoTitle, L"ClipStack is still syncing");
    wcscpy_s(hint.szInfo,
             L"It keeps your clipboard in sync from here. Right-click the "
             L"ClipStack icon to quit.");
    ::Shell_NotifyIconW(NIM_MODIFY, &hint);
    SetTrayHintShown();
  }
}

void FlutterWindow::Quit() {
  quitting_ = true;
  RemoveTrayIcon();
  // WM_DESTROY posts WM_QUIT (quit on close is set in main.cpp).
  ::DestroyWindow(GetHandle());
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowFromTray();
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        break;
    }
    return 0;
  }
  if (message == ShowMessage()) {
    ShowFromTray();
    return 0;
  }
  if (message == TaskbarCreatedMessage()) {
    // Explorer restarted and forgot the icon.
    tray_added_ = false;
    if (tray_icon_.hIcon) {
      ::DestroyIcon(tray_icon_.hIcon);
      tray_icon_.hIcon = nullptr;
    }
    AddTrayIcon();
    return 0;
  }
  switch (message) {
    case WM_CLOSE:
      if (!quitting_) {
        HideToTray();
        return 0;
      }
      break;
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      // Signing out, shutting down, or an installer closing the app.
      if (wparam) {
        Quit();
      }
      return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
