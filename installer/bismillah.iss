; Inno Setup script for Bismillah Constructions (Windows desktop build).
;
; Build the app first, then compile this script:
;   flutter build windows --release --target lib/main_desktop.dart
;   iscc installer\bismillah.iss
; (or just run scripts\build_windows.ps1, which does both).
;
; Produces installer\output\BismillahConstructionsSetup.exe — a single
; self-contained installer that copies the app to Program Files, adds Start
; menu + optional desktop shortcuts, and registers an uninstaller.

#define MyAppName "Bismillah Constructions"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Bismillah Constructions"
#define MyAppExeName "bismillah_constructions.exe"

[Setup]
; A stable AppId keeps upgrades in-place (same GUID = upgrade, not a 2nd copy).
AppId={{A7E3F2C1-9B4D-4E6A-8F12-3C5D7E9A1B24}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Bismillah Constructions
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=output
OutputBaseFilename=BismillahConstructionsSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-machine install (Program Files) needs admin; installer will prompt.
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The entire Flutter release output — exe, DLLs and the data/ folder.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
