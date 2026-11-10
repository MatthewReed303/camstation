; Inno Setup script for CamStation (built by .github/workflows/release.yml).
; Build locally: ISCC.exe /DAppVersion=0.3.0 packaging\windows\camstation.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6C1B7C4E-2A58-4C61-9E0B-3E7C5B1F2A90}
AppName=CamStation
AppVersion={#AppVersion}
AppPublisher=CamStation
AppPublisherURL=https://github.com/MatthewReed303/camstation
DefaultDirName={autopf}\CamStation
DefaultGroupName=CamStation
UninstallDisplayIcon={app}\camstation.exe
OutputDir=..\..\dist
OutputBaseFilename=CamStation-{#AppVersion}-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\CamStation"; Filename: "{app}\camstation.exe"
Name: "{autodesktop}\CamStation"; Filename: "{app}\camstation.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\camstation.exe"; Description: "{cm:LaunchProgram,CamStation}"; Flags: nowait postinstall skipifsilent
