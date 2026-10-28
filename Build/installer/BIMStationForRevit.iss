; BIM Station for Revit - installer
;
; Builds a single self-contained .exe that drops the connector and the bundled panel UI
; into the per-user Revit Addins folder. Per-user on purpose: Revit modellers should not
; need admin rights, and Revit reads %AppData%\Autodesk\Revit\Addins by default.
;
; Build with:  ISCC.exe Build\installer\BIMStationForRevit.iss
; Expects Release builds to exist and the UI to be generated (see PreBuild checks below).

#define AppName "BIM Station for Revit"
#define AppPublisher "Blackbird Industries"
#define AppVersion "1.1.0"

; Connector Release output
#define Out2026 "..\..\Connectors\Revit\Speckle.Connectors.Revit2026\bin\Release\net8.0-windows"
#define Out2027 "..\..\Connectors\Revit\Speckle.Connectors.Revit2027\bin\Release\net10.0-windows"
; Static panel UI generated from the sibling speckle-connectors-dui repo
#define UiDir "..\..\..\speckle-connectors-dui\.output\public"

; Our own Addins folder and manifest name. Upstream's Speckle.Connectors.Revit<ver> is the
; official Speckle connector's location, and installing there would overwrite it.
#define Addin2026 "BIMStation.Revit2026"
#define Addin2027 "BIMStation.Revit2027"

[Setup]
; Kept from the BIM Cost releases: the same AppId makes this an in-place upgrade of them.
AppId={{b01889a6-e55c-437a-8d34-87a5f6bb633e}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
DefaultDirName={userappdata}\Autodesk\Revit\Addins
DisableDirPage=yes
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
OutputDir=..\..\output
OutputBaseFilename=BIMStationForRevit-{#AppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Per-user install: no elevation prompt.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "pt"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Types]
Name: "custom"; Description: "Custom"; Flags: iscustom

[Components]
Name: "r2026"; Description: "Revit 2026"; Types: custom; Check: RevitInstalled('2026')
Name: "r2027"; Description: "Revit 2027"; Types: custom; Check: RevitInstalled('2027')

[Files]
; --- Revit 2026 ---
Source: "{#Out2026}\*"; DestDir: "{userappdata}\Autodesk\Revit\Addins\2026\{#Addin2026}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs; Components: r2026
Source: "{#UiDir}\*"; DestDir: "{userappdata}\Autodesk\Revit\Addins\2026\{#Addin2026}\ui"; \
  Flags: ignoreversion recursesubdirs createallsubdirs; Components: r2026
Source: "{#Out2026}\Plugin\Speckle.Connectors.Revit2026.addin"; DestDir: "{userappdata}\Autodesk\Revit\Addins\2026"; \
  DestName: "{#Addin2026}.addin"; Flags: ignoreversion; Components: r2026

; --- Revit 2027 ---
Source: "{#Out2027}\*"; DestDir: "{userappdata}\Autodesk\Revit\Addins\2027\{#Addin2027}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs; Components: r2027
Source: "{#UiDir}\*"; DestDir: "{userappdata}\Autodesk\Revit\Addins\2027\{#Addin2027}\ui"; \
  Flags: ignoreversion recursesubdirs createallsubdirs; Components: r2027
Source: "{#Out2027}\Plugin\Speckle.Connectors.Revit2027.addin"; DestDir: "{userappdata}\Autodesk\Revit\Addins\2027"; \
  DestName: "{#Addin2027}.addin"; Flags: ignoreversion; Components: r2027

[InstallDelete]
; Before 2026-10-27 the entry assembly was named Speckle.Connectors.Revit<ver>; an upgrade
; would leave that copy next to the renamed BIMStation.Revit<ver>.dll.
Type: files; Name: "{userappdata}\Autodesk\Revit\Addins\2026\{#Addin2026}\Speckle.Connectors.Revit2026.*"
Type: files; Name: "{userappdata}\Autodesk\Revit\Addins\2027\{#Addin2027}\Speckle.Connectors.Revit2027.*"

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\Autodesk\Revit\Addins\2026\{#Addin2026}"
Type: filesandordirs; Name: "{userappdata}\Autodesk\Revit\Addins\2027\{#Addin2027}"

[Code]
const
  { The addin ClientId every BIM Cost / BIM Station manifest carries. }
  OurClientId = '8ae12a74-b713-4fe8-8183-8d10099a88ef';

{ Revit is detected by its install directory rather than the registry: the registry layout
  varies between Autodesk releases, the folder does not. }
function RevitInstalled(Version: String): Boolean;
begin
  Result := DirExists(ExpandConstant('{commonpf}\Autodesk\Revit ') + Version);
end;

{ BIM Cost releases (1.0.x) installed into upstream's Speckle.Connectors.Revit<ver> folder.
  Left in place after the upgrade, that manifest would load next to the new one with the same
  ClientId and Revit would refuse one of them. The folder is removed only when its manifest is
  ours: the same path may hold the official Speckle connector, which must not be touched. }
procedure RemoveLegacyBimCostInstall(Version: String);
var
  AddinsDir, Manifest: String;
  Content: AnsiString;
begin
  AddinsDir := ExpandConstant('{userappdata}\Autodesk\Revit\Addins\') + Version;
  Manifest := AddinsDir + '\Speckle.Connectors.Revit' + Version + '.addin';
  if not FileExists(Manifest) then
    Exit;
  if not LoadStringFromFile(Manifest, Content) then
    Exit;
  if Pos(OurClientId, Lowercase(String(Content))) = 0 then
    Exit;

  DelTree(AddinsDir + '\Speckle.Connectors.Revit' + Version, True, True, True);
  DeleteFile(Manifest);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    RemoveLegacyBimCostInstall('2026');
    RemoveLegacyBimCostInstall('2027');
  end;
end;

{ Copying over DLLs that Revit has loaded fails mid-install and leaves a half-written addin,
  so refuse to start while Revit is open. }
function IsRevitRunning: Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec('powershell.exe',
          '-NoProfile -NonInteractive -Command "if (Get-Process Revit -ErrorAction SilentlyContinue) { exit 1 } exit 0"',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode = 1;
end;

{ The panel is a WebView2 control. Windows 11 ships the Evergreen runtime, but older or
  stripped images may not have it, and without it the panel stays blank. }
function IsWebView2Present: Boolean;
var
  Value: String;
begin
  Result :=
    RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Value) or
    RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Value) or
    RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Value);
end;

function InitializeSetup: Boolean;
begin
  Result := True;

  if IsRevitRunning then
  begin
    MsgBox('Revit is currently running.' + #13#10#13#10 +
           'Close every open Revit window and run this installer again.',
           mbError, MB_OK);
    Result := False;
    Exit;
  end;

  if not (RevitInstalled('2026') or RevitInstalled('2027')) then
  begin
    MsgBox('No supported Revit version was found.' + #13#10#13#10 +
           'This build supports Revit 2026 and 2027.',
           mbError, MB_OK);
    Result := False;
    Exit;
  end;

  if not IsWebView2Present then
    MsgBox('The Microsoft Edge WebView2 Runtime was not detected.' + #13#10#13#10 +
           'BIM Station uses it to draw its panel. Installation will continue, but if the panel ' +
           'appears blank inside Revit, install the WebView2 Runtime from Microsoft and restart Revit.',
           mbInformation, MB_OK);
end;
