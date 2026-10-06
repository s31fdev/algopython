; AlgoVSCode installer (formerly Algoritmika Python). Built by build.ps1 (last step: tools\innosetup\ISCC.exe algopython.iss).
; Expects build\python (Python 3.13 with all libraries) and build\vscode (portable VS Code with data\).
#define Ver "5.0.3"
; passed by build.ps1 (/DPyVer=... /DPyTag=...); defaults only for a manual compile
#ifndef PyVer
  #define PyVer "3.13.16"
#endif
#ifndef PyTag
  #define PyTag "3.13"
#endif

[Setup]
; same AppId as 4.7, so Windows sees an upgrade, not a second app
AppId={{E2D7C524-3019-44E3-A2B2-34D17FFAD95F}}
AppName=AlgoVSCode
AppVersion={#Ver}
AppPublisher=Algoritmika
; the path is hardcoded in vscode\data\user-data\User\settings.json
DefaultDirName={autopf}\Algoritmika
DisableDirPage=yes
DefaultGroupName=AlgoVSCode
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
ChangesEnvironment=yes
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4
OutputBaseFilename=AlgoVSCode-{#Ver}
SetupIconFile=assets\algovscode.ico
UninstallDisplayIcon={app}\algovscode.ico

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Dirs]
; students can pip install without admin rights
Name: "{app}\python"; Permissions: users-modify
; portable VS Code keeps settings, extensions and temp files here
Name: "{app}\vscode\data"; Permissions: users-modify

[Files]
Source: "cleanup.ps1"; Flags: dontcopy
Source: "cleanup.ps1"; DestDir: "{app}"
Source: "assets\algovscode.ico"; DestDir: "{app}"
Source: "build\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Registry]
; PEP 514 registration. VS Code's Python extension finds interpreters through this key, not through
; PATH: without it students get "No Python found ... install uv". cleanup.ps1 (pre) wipes the old keys first.
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}"; ValueType: string; ValueName: "DisplayName"; ValueData: "Python {#PyTag} (AlgoVSCode)"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}"; ValueType: string; ValueName: "SupportUrl"; ValueData: "https://www.python.org/"
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}"; ValueType: string; ValueName: "Version"; ValueData: "{#PyVer}"
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}"; ValueType: string; ValueName: "SysVersion"; ValueData: "{#PyTag}"
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}"; ValueType: string; ValueName: "SysArchitecture"; ValueData: "64bit"
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}\InstallPath"; ValueType: string; ValueName: ""; ValueData: "{app}\python"
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}\InstallPath"; ValueType: string; ValueName: "ExecutablePath"; ValueData: "{app}\python\python.exe"
Root: HKLM; Subkey: "SOFTWARE\Python\PythonCore\{#PyTag}\InstallPath"; ValueType: string; ValueName: "WindowedExecutablePath"; ValueData: "{app}\python\pythonw.exe"

[Icons]
; same AppUserModelID that build.ps1 writes into product.json (win32AppUserModelId), so the taskbar button
; takes this shortcut's name and icon. Alt+Tab still shows the icon built into Code.exe.
Name: "{group}\AlgoVSCode"; Filename: "{app}\vscode\Code.exe"; IconFilename: "{app}\algovscode.ico"; AppUserModelID: "Algoritmika.AlgoVSCode"
Name: "{group}\{cm:UninstallProgram,AlgoVSCode}"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\cleanup.ps1"" -Phase uninstall -AppDir ""{app}"""; Flags: runhidden; RunOnceId: "path"

[Code]
var
  CleanupPage: TOutputProgressWizardPage;

function RunHelper(Script, Phase: String): Integer;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + Script + '" -Phase ' + Phase + ' -AppDir "' + ExpandConstant('{app}') + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := Code;
end;

procedure InitializeWizard;
begin
  CleanupPage := CreateOutputProgressPage('Подготовка к установке',
    'Удаляем прошлые версии AlgoVSCode и все версии Python. Это может занять несколько минут.');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CleanupPage.SetProgress(0, 1);
  CleanupPage.ProgressBar.Style := npbstMarquee;
  CleanupPage.Show;
  try
    ExtractTemporaryFile('cleanup.ps1');
    RunHelper(ExpandConstant('{tmp}\cleanup.ps1'), 'pre');
  finally
    CleanupPage.Hide;
  end;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and (RunHelper(ExpandConstant('{app}\cleanup.ps1'), 'post') <> 0) then
    SuppressibleMsgBox('Не удалось добавить Python в PATH. Подробности: ' +
      ExpandConstant('{%TEMP}') + '\algopython-post.log', mbError, MB_OK, IDOK);
end;
