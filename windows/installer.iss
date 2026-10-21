[Setup]
AppId={{2502A6D6-DC31-48E1-BBBC-FBA25D95B4B1}
AppName=Hej's Pets
AppVersion=4.1.0
AppPublisher=Hej
AppPublisherURL=https://github.com/Hej28/Hejs-Pets
AppSupportURL=https://github.com/Hej28/Hejs-Pets/issues
DefaultDirName={localappdata}\Programs\HejsPets
DefaultGroupName=Hej's Pets
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=release
OutputBaseFilename=HejsPets-4.1.0-Windows-Setup
SetupIconFile=assets\AppIcon.ico
UninstallDisplayIcon={app}\HejsPets.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "dist\HejsPets\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Hej's Pets"; Filename: "{app}\HejsPets.exe"
Name: "{autodesktop}\Hej's Pets"; Filename: "{app}\HejsPets.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\HejsPets.exe"; Description: "Open Hej's Pets"; Flags: nowait postinstall skipifsilent

; User photos in LOCALAPPDATA\HejPets are deliberately preserved on uninstall.
