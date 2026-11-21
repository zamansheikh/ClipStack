#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

// Also the installer's AppMutex: setup waits for ClipStack to close.
constexpr wchar_t kInstanceMutex[] = L"ClipStackSingleInstance";

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One ClipStack per user session: a second copy couldn't listen on the sync
  // port. Launching it again brings the running one forward instead.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ClipStack");
    if (running) {
      ::AllowSetForegroundWindow(ASFW_ANY);
      ::PostMessageW(running, ::RegisterWindowMessageW(kShowMessageName), 0,
                     0);
    }
    if (instance_mutex) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // The sign-in shortcut passes --hidden: start in the notification area.
  const bool start_hidden =
      command_line != nullptr && std::wcsstr(command_line, L"--hidden");

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(460, 860);
  if (!window.Create(L"ClipStack", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
