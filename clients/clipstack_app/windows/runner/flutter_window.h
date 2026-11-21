#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// Message another ClipStack.exe posts to the running one to bring it forward.
inline constexpr wchar_t kShowMessageName[] = L"ClipStack.Show";

// The ClipStack window: hosts the Flutter view and lives in the notification
// area. Closing the window hides it so clipboard sync keeps running; Quit in
// the tray menu exits.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // With |start_hidden| (launched at sign-in) only the tray icon shows.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void ShowFromTray();
  void HideToTray();
  void Quit();

  // The project to run.
  flutter::DartProject project_;
  bool start_hidden_;
  bool quitting_ = false;
  NOTIFYICONDATAW tray_icon_ = {};
  bool tray_added_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
