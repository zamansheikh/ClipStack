; ClipStack for Windows: Inno Setup 6 script.
;
; Built by .github/workflows/windows.yml after `flutter build windows`:
;   iscc /DMyAppVersion=0.3.0 clients\clipstack_app\windows\installer\clipstack.iss
; Paths are relative to this file. The Release folder must already hold the
; Visual C++ runtime DLLs (the workflow copies them in).

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

#define MyAppName "ClipStack"
#define MyAppExe "ClipStack.exe"
#define FirewallRule "ClipStack"

[Setup]
; Never change AppId: upgrades find the installed copy by it.
AppId={{36C07ED3-4FE4-4DEA-8CF6-5E06D4EA650A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=Silifton
AppPublisherURL=https://github.com/zamansheikh/ClipStack
AppSupportURL=https://github.com/zamansheikh/ClipStack/issues
AppUpdatesURL=https://github.com/zamansheikh/ClipStack/releases
AppCopyright=Copyright (C) 2026 Zaman Sheikh. MIT License.
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Admin: the firewall rule needs it.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Bonjour-style discovery (DnsServiceRegister) needs Windows 10 1903 or later.
MinVersion=10.0.18362
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExe}
UninstallDisplayName={#MyAppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=ClipStack-Windows-{#MyAppVersion}-setup
; ClipStack hides in the notification area; close it for an upgrade.
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "startup"; Description: "Start ClipStack when I sign in (keeps your clipboard in sync)"; GroupDescription: "Sync:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Assets from an older version.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon
Name: "{autostartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Parameters: "--hidden"; Tasks: startup

[Registry]
; The app's own flags (the "still syncing" hint).
Root: HKCU; Subkey: "Software\Silifton\ClipStack"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Silifton"; Flags: uninsdeletekeyifempty dontcreatekey

[Run]
; Paired phones connect to this PC, so let them in on private networks only.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden; StatusMsg: "Allowing ClipStack through Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FirewallRule}"" dir=in action=allow program=""{app}\{#MyAppExe}"" enable=yes profile=private,domain"; Flags: runhidden
Filename: "{app}\{#MyAppExe}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#MyAppExe}"; Flags: runhidden; RunOnceId: "StopClipStack"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"
