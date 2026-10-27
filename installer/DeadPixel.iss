; DEADPIXEL — інсталятор Inno Setup 6. Збирається tools\Package.ps1 (локально і на GitHub Actions):
;   ISCC.exe /DAppVersion=0.2.0 /DStageDir=<dist\DEADPIXEL> /O<dist> installer\DeadPixel.iss
; Встановлення для поточного користувача (%LOCALAPPDATA%\Programs\DEADPIXEL) — без прав адміністратора;
; дані програми (data\, reports\) лежать поруч з exe, як у portable-версії.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\dist\DEADPIXEL"
#endif

[Setup]
; AppId не змінювати: за ним інсталятор знаходить попередню версію для оновлення
AppId={{6F1D2C4B-8A3E-4F57-9B21-D3E0A7C5F914}
AppName=DEADPIXEL
AppVersion={#AppVersion}
AppVerName=DEADPIXEL {#AppVersion}
AppPublisher=StarLith
AppPublisherURL=https://github.com/SamuiRo/DEADPIXEL
AppSupportURL=https://github.com/SamuiRo/DEADPIXEL/issues
AppUpdatesURL=https://github.com/SamuiRo/DEADPIXEL/releases
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
DefaultDirName={autopf}\DEADPIXEL
DisableProgramGroupPage=yes
OutputBaseFilename=DEADPIXEL-{#AppVersion}-setup
SetupIconFile=..\assets\deadpixel.ico
UninstallDisplayIcon={app}\DeadPixel.exe
UninstallDisplayName=DEADPIXEL
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
MinVersion=10.0
; Оновлення поверх запущеної програми: інсталятор попросить її закрити (той самий mutex, що в Program.cs)
AppMutex=DeadPixel_SingleInstance
CloseApplications=yes

[Languages]
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
uk.Autostart=Запускати DEADPIXEL разом із Windows
en.Autostart=Start DEADPIXEL with Windows
uk.DeleteData=Видалити також зібрані дані (чорна скринька, звіти, налаштування)?%n%nЯкщо плануєте встановити DEADPIXEL знову, натисніть «Ні» — історія крашів збережеться.
en.DeleteData=Also delete collected data (black box, reports, settings)?%n%nChoose "No" if you plan to reinstall DEADPIXEL and want to keep crash history.
uk.ShortcutComment=DEADPIXEL — моніторинг і діагностика збоїв
en.ShortcutComment=DEADPIXEL — monitoring and crash diagnostics

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "{cm:Autostart}"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Ті самі імена, що створює програма (Shortcuts.cs), — щоб не було двох однакових ярликів
Name: "{autoprograms}\DEADPIXEL"; Filename: "{app}\DeadPixel.exe"; Parameters: "--show"; Comment: "{cm:ShortcutComment}"
Name: "{autodesktop}\DEADPIXEL"; Filename: "{app}\DeadPixel.exe"; Parameters: "--show"; Comment: "{cm:ShortcutComment}"; Tasks: desktopicon

[Registry]
; Те саме значення, що пише галочка автозапуску в налаштуваннях програми (Settings.cs)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "DeadPixel"; ValueData: """{app}\DeadPixel.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\DeadPixel.exe"; Description: "{cm:LaunchProgram,DEADPIXEL}"; Flags: nowait postinstall skipifsilent

[Code]
// DEADPIXEL не повинен лишати хвостів: прибираємо й те, що програма створила сама, а не інсталятор
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'DeadPixel');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\RunOnce', 'DeadPixelSetup');
    DeleteFile(ExpandConstant('{userdesktop}\DEADPIXEL.lnk'));
    DeleteFile(ExpandConstant('{userprograms}\DEADPIXEL.lnk'));
    // Розклад аудиту працює без прав адміністратора - видаляємо звичайно; лише завдання від ранніх збірок
    // (створене з найвищими правами) потребує UAC
    Exec(ExpandConstant('{sys}\schtasks.exe'), '/Delete /TN "\DEADPIXEL\DEADPIXEL Audit" /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if Exec(ExpandConstant('{sys}\schtasks.exe'), '/Query /TN "\DEADPIXEL\DEADPIXEL Audit"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
      ShellExec('runas', ExpandConstant('{sys}\schtasks.exe'), '/Delete /TN "\DEADPIXEL\DEADPIXEL Audit" /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    if (DirExists(ExpandConstant('{app}\data')) or DirExists(ExpandConstant('{app}\reports'))
        or DirExists(ExpandConstant('{localappdata}\DeadPixel'))) and not UninstallSilent then
      if MsgBox(CustomMessage('DeleteData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(ExpandConstant('{app}\data'), True, True, True);
        DelTree(ExpandConstant('{app}\reports'), True, True, True);
        DelTree(ExpandConstant('{localappdata}\DeadPixel'), True, True, True);
      end;
    RemoveDir(ExpandConstant('{app}'));
  end;
end;
