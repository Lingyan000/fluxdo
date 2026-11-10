#define MyAppName "FluxDO"
#define MyAppExeName "fluxdo.exe"
#define MyAppPublisher "FluxDO"
#define MyAppURL "https://github.com/lingyan000/fluxdo"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=fluxdo-windows-x86_64-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent; Check: not IsAppUpdate
Filename: "{app}\{#MyAppExeName}"; Flags: nowait runasoriginaluser; Check: IsAppUpdate

[Code]
function OpenProcess(Access: LongWord; Inherit: Boolean; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function GetWindowThreadProcessId(Window: HWND; var ProcessId: LongWord): LongWord;
  external 'GetWindowThreadProcessId@user32.dll stdcall';

function IsAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ProcessId, WindowProcessId: LongWord;
  ProcessHandle: THandle;
  AppWindow: HWND;
begin
  Result := '';
  if not IsAppUpdate then Exit;

  ProcessId := StrToIntDef(ExpandConstant('{param:UPDATEPID|0}'), 0);
  AppWindow := StrToInt64Def(ExpandConstant('{param:UPDATEHWND|0}'), 0);
  WindowProcessId := 0;
  GetWindowThreadProcessId(AppWindow, WindowProcessId);
  if (ProcessId = 0) or (WindowProcessId <> ProcessId) then begin
    Result := 'Cannot find the FluxDO window. Close FluxDO and run the installer again.';
    Exit;
  end;
  ProcessHandle := OpenProcess($00100000, False, ProcessId);
  if ProcessHandle = 0 then begin
    Result := 'Cannot wait for FluxDO to exit. Close FluxDO and run the installer again.';
    Exit;
  end;
  try
    // UAC 和安装准备成功后才请求退出；让 Flutter 保存窗口状态并正常销毁插件。
    PostMessage(AppWindow, $0010, 0, 0);
    if WaitForSingleObject(ProcessHandle, 30000) <> 0 then
      Result := 'FluxDO did not exit in time. Close FluxDO and retry the update.';
  finally
    CloseHandle(ProcessHandle);
  end;
end;

procedure KillProcesses;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/f /im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeUninstall(): Boolean;
begin
  KillProcesses;
  Result := True;
end;
