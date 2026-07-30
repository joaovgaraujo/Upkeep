; Upkeep.iss - Inno Setup script for the Upkeep installer.
; Build with Build-Installer.ps1 (or: ISCC.exe installer\Upkeep.iss)

#define MyAppName "Upkeep"
#define MyAppVersion "1.3.0"
#define MyAppExeName "Upkeep.exe"

[Setup]
; Stable AppId so upgrades replace the existing install
AppId={{B7E3F2A9-51C4-4D8B-9E67-0A2D84C11A55}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=joaovguedes
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; The app itself requires admin (UAC manifest); install machine-wide
PrivilegesRequired=admin
OutputDir=..\dist
OutputBaseFilename=Upkeep-Setup
SetupIconFile=..\gui\assets\upkeep.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\gui\target\release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SystemUpdate_Topgrade.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\steps\*.ps1"; DestDir: "{app}\steps"; Flags: ignoreversion
Source: "..\apps.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\presets\*.json"; DestDir: "{app}\presets"; Flags: ignoreversion
Source: "..\presets\*.cfg"; DestDir: "{app}\presets"; Flags: ignoreversion
Source: "..\Install-Apps.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Export-InstalledApps.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Setup-NewPC.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Export-StartupReport.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Get-NVCleanstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Get-NvidiaDriver.ps1"; DestDir: "{app}"; Flags: ignoreversion
; Optional: not in the repo (one machine's startup timings). Ship it only if
; the person building has made their own.
Source: "..\boot-times.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent shellexec

[UninstallDelete]
; Files the app creates at runtime next to itself
Type: files; Name: "{app}\settings.json"
Type: files; Name: "{app}\SystemUpdate_Topgrade.bat.bak"
Type: filesandordirs; Name: "{app}\Logs"
