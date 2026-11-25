; Installer Zterm untuk Windows (Inno Setup 6.3+).
; Build:
;   iscc /DAppVersion=0.1.0 /DArch=x64 /DSourceDir=..\publish\win-x64 /DOutputDir=..\dist Zterm.iss
; Hasil: Zterm-<versi>-Windows-<arch>-Setup.exe
; Dipasang per user (tanpa admin) di %LOCALAPPDATA%\Programs\Zterm.

#ifndef AppVersion
  #define AppVersion "1.0.1"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\publish\win-" + Arch
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif
; x64 juga boleh dipasang di Windows ARM (lewat emulasi)
#if Arch == "x64"
  #define ArchAllowed "x64compatible"
#else
  #define ArchAllowed "arm64"
#endif
; Skema URL login Google (sama dengan GoogleAuth.Scheme di app)
#define OAuthScheme "com.googleusercontent.apps.903065765040-0e2gd7b3in557ndevksb2jjmkbaf24ga"

[Setup]
AppId={{6E1C9B9A-4D7B-4F0E-9C5A-D71E5E11A001}
AppName=Zterm
AppVersion={#AppVersion}
AppVerName=Zterm {#AppVersion}
AppPublisher=latiefahmad
AppPublisherURL=https://latief.id/zterm/
AppSupportURL=https://github.com/latiefahmad/zterm/issues
AppUpdatesURL=https://github.com/latiefahmad/zterm/releases/latest
DefaultDirName={localappdata}\Programs\Zterm
DefaultGroupName=Zterm
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#ArchAllowed}
MinVersion=10.0.19041
OutputDir={#OutputDir}
OutputBaseFilename=Zterm-{#AppVersion}-Windows-{#Arch}-Setup
SetupIconFile=..\Zterm\Assets\zterm.ico
UninstallDisplayIcon={app}\Zterm.exe
UninstallDisplayName=Zterm
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Zterm

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Bersihkan versi lama supaya tidak ada DLL sisa
Type: filesandordirs; Name: "{app}\*"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Zterm"; Filename: "{app}\Zterm.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Zterm"; Filename: "{app}\Zterm.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; Supaya browser bisa kembali ke app setelah login Google
Root: HKCU; Subkey: "Software\Classes\{#OAuthScheme}"; ValueType: string; ValueName: ""; ValueData: "URL:Zterm"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#OAuthScheme}"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\{#OAuthScheme}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Zterm.exe"" ""%1"""

[Run]
Filename: "{app}\Zterm.exe"; Description: "{cm:LaunchProgram,Zterm}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Hanya file sementara; vault & pengaturan di %APPDATA%\Zterm tetap aman
Type: filesandordirs; Name: "{localappdata}\Zterm\session-keys"
