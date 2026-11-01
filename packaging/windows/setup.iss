; Build with scripts/build-setup.ps1. Keep the menu layout aligned with
; scripts/install-context-menu.ps1; Inno owns these keys so uninstall and
; installation rollback work without PowerShell on the recipient's machine.
#ifndef AppVersion
  #error AppVersion must be supplied by build-setup.ps1
#endif

#define MenuRoot "Software\Classes\SystemFileAssociations\.svg\shell\SvgConverter"

[Setup]
AppId=SvgConverter.Classic
AppName=SVG Converter
AppVersion={#AppVersion}
AppPublisher=Ali Zreik
AppPublisherURL=https://github.com/alizreik-au/svg-to-image-converter
AppSupportURL=https://github.com/alizreik-au/svg-to-image-converter/issues
DefaultDirName={localappdata}\Programs\SvgConverter
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=SvgConverter-{#AppVersion}-windows-x64-setup
SetupIconFile={#StageDir}\SvgConverter.ico
UninstallDisplayIcon={app}\SvgConverter.ico
LicenseFile={#RepoRoot}\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=no
RestartApplications=no
UninstallDisplayName=SVG Converter
VersionInfoVersion={#AppVersion}
VersionInfoDescription=SVG Converter Setup

[Files]
Source: "{#BinDir}\svg-converter.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\svg-converterw.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\SvgConverter.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\INSTALL.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Registry]
Root: HKCU; Subkey: "{#MenuRoot}"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Convert SVG"; Flags: uninsdeletekey
Root: HKCU; Subkey: "{#MenuRoot}"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\SvgConverter.ico"
Root: HKCU; Subkey: "{#MenuRoot}"; ValueType: string; ValueName: "SubCommands"; ValueData: ""
Root: HKCU; Subkey: "{#MenuRoot}\shell\01_quick_png"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Quick: PNG (1x)"
Root: HKCU; Subkey: "{#MenuRoot}\shell\01_quick_png\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f png -s 1.0 --quiet"

Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png"; ValueType: string; ValueName: "MUIVerb"; ValueData: "PNG"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png"; ValueType: string; ValueName: "SubCommands"; ValueData: ""
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\1_3x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "3.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\1_3x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f png -s 3.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\2_2x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "2.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\2_2x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f png -s 2.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\3_1x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "1.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\3_1x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f png -s 1.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\4_0.5x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "0.5x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\02_png\shell\4_0.5x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f png -s 0.5 --quiet"

Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg"; ValueType: string; ValueName: "MUIVerb"; ValueData: "JPEG"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg"; ValueType: string; ValueName: "SubCommands"; ValueData: ""
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\1_3x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "3.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\1_3x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f jpg -s 3.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\2_2x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "2.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\2_2x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f jpg -s 2.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\3_1x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "1.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\3_1x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f jpg -s 1.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\4_0.5x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "0.5x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\03_jpeg\shell\4_0.5x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f jpg -s 0.5 --quiet"

Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp"; ValueType: string; ValueName: "MUIVerb"; ValueData: "WebP"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp"; ValueType: string; ValueName: "SubCommands"; ValueData: ""
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\1_3x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "3.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\1_3x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f webp -s 3.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\2_2x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "2.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\2_2x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f webp -s 2.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\3_1x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "1.0x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\3_1x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f webp -s 1.0 --quiet"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\4_0.5x"; ValueType: string; ValueName: "MUIVerb"; ValueData: "0.5x"
Root: HKCU; Subkey: "{#MenuRoot}\shell\04_webp\shell\4_0.5x\command"; ValueType: string; ValueData: """{app}\svg-converterw.exe"" convert ""%1"" -f webp -s 0.5 --quiet"

[Messages]
FinishedLabel=SVG Converter is installed.%n%nRight-click an .svg file, choose Convert SVG, then choose a format and scale. The image is saved beside the original.%n%nOn Windows 11, choose Show more options first.
