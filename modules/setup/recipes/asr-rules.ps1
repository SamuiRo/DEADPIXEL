# Microsoft Defender: правила зменшення поверхні атаки (ASR) - рекомендований для домашнього ПК набір.
# Кожне правило - окремий пункт, щоб його можна було відкотити незалежно. Правила, що заважають розробці
# (обфусковані скрипти, блокування за поширеністю, PsExec/WMI), сюди свідомо не входять.

# Пункт рецепта для одного правила: 0 вимкнено, 1 блокувати, 2 аудит, 6 попереджати
function New-AsrItem([string]$Guid, [string]$Title, [string]$Hint) {
    @{ Kind = 'Custom'; Id = $Guid; Title = $Title; Desired = 1; Hint = $Hint
       Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'блокувати' 'block'); 2 = (T 'лише аудит' 'audit only'); 6 = (T 'попереджати' 'warn') }
       Get = {
           $p = Get-MpPreference
           $ids = @($p.AttackSurfaceReductionRules_Ids); $actions = @($p.AttackSurfaceReductionRules_Actions)
           for ($i = 0; $i -lt $ids.Count; $i++) { if ("$($ids[$i])" -eq $Guid) { return [int]$actions[$i] } }
           0
       }.GetNewClosure()
       Set = { param($value) Add-MpPreference -AttackSurfaceReductionRules_Ids $Guid -AttackSurfaceReductionRules_Actions ([int]$value) }.GetNewClosure() }
}

@{
    Title       = (T 'Defender: правила зменшення поверхні атаки (ASR)' 'Defender: attack surface reduction (ASR) rules')
    Description = (T 'Блокує прийоми атак, а не конкретні віруси: документ запускає PowerShell, скрипт із листа завантажує програму, програма читає паролі з пам''яті Windows. Працює лише з Microsoft Defender. Заблоковане видно в «Безпека Windows» → «Журнал захисту».' 'Blocks attack techniques rather than specific malware: a document launching PowerShell, an emailed script downloading a program, a program reading passwords from Windows memory. Works only with Microsoft Defender. Blocked actions show in Windows Security → Protection history.')
    Items       = @(
        (New-AsrItem '56a863a9-875e-4185-98a7-b882c64b5ce5' (T 'Вразливі підписані драйвери' 'Vulnerable signed drivers') (T 'Не дає програмі встановити драйвер із відомою вразливістю, щоб отримати доступ до ядра.' 'Stops a program from installing a driver with a known vulnerability to reach the kernel.'))
        (New-AsrItem '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' (T 'Крадіжка паролів із пам''яті Windows (LSASS)' 'Credential stealing from Windows memory (LSASS)') (T 'Програми не можуть читати пам''ять процесу входу. У журналі бувають записи про легітимні програми, які просто перелічують процеси, - це нормально.' 'Programs cannot read the sign-in process memory. The log may list legitimate programs that merely enumerate processes - that is normal.'))
        (New-AsrItem 'e6db77e5-3df2-4cf1-b95a-636979351e5b' (T 'Закріплення через підписки WMI' 'Persistence through WMI subscriptions') (T 'Блокує «безфайловий» автозапуск, якого не видно в автозавантаженні.' 'Blocks "fileless" autostart that Startup lists do not show.'))
        (New-AsrItem 'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' (T 'Програми з листів і вебпошти' 'Executables from email and webmail') (T 'Вкладення .exe, .js, .vbs тощо з Outlook і вебпошти не запускаються.' 'Attachments such as .exe, .js, .vbs from Outlook and webmail do not run.'))
        (New-AsrItem 'd3e037e1-3eb8-44c8-a917-57927947596d' (T 'JS/VBS запускає завантажену програму' 'JS/VBS launching a downloaded executable') (T 'Типовий ланцюжок зараження: скрипт завантажує і запускає exe.' 'The typical infection chain: a script downloads and runs an exe.'))
        (New-AsrItem 'd4f940ab-401b-4efc-aadc-ad5f3c50688a' (T 'Office запускає інші програми' 'Office creating child processes') (T 'Word/Excel не можуть запустити PowerShell чи cmd. Заважає лише макросам, які навмисно запускають зовнішні програми.' 'Word/Excel cannot launch PowerShell or cmd. Only affects macros that deliberately start external programs.'))
        (New-AsrItem '3b576869-a4ec-4529-8536-b80a7769e899' (T 'Office створює програми' 'Office creating executable content') (T 'Документ не може записати на диск exe чи скрипт.' 'A document cannot write an exe or script to disk.'))
        (New-AsrItem '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' (T 'Office втручається в інші процеси' 'Office injecting into other processes') '')
        (New-AsrItem '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' (T 'Виклики Win32 API з макросів Office' 'Win32 API calls from Office macros') (T 'Складні макроси з викликами Windows API перестануть працювати.' 'Complex macros calling the Windows API stop working.'))
        (New-AsrItem '26190899-1602-49e8-8b27-eb1d0a1ce869' (T 'Outlook запускає інші програми' 'Outlook creating child processes') '')
        (New-AsrItem '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' (T 'Adobe Reader запускає інші програми' 'Adobe Reader creating child processes') '')
        (New-AsrItem 'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' (T 'Непідписані програми з USB-носіїв' 'Unsigned programs from USB drives') (T 'Портативні утиліти без підпису з флешки не запустяться - скопіюйте їх на диск.' 'Unsigned portable tools will not run from a USB stick - copy them to the disk first.'))
        (New-AsrItem 'c1db55ab-c21a-4637-bb3f-a12568109d35' (T 'Розширений захист від програм-вимагачів' 'Advanced ransomware protection') (T 'Потрібен увімкнений хмарний захист Defender.' 'Needs Defender cloud-delivered protection turned on.'))
        (New-AsrItem 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' (T 'Підроблені копії системних утиліт' 'Impersonated system tools') (T 'Блокує копії cmd.exe, powershell.exe тощо, перейменовані або покладені в іншу папку.' 'Blocks copies of cmd.exe, powershell.exe and the like that were renamed or placed elsewhere.'))
        (New-AsrItem '33ddedf1-c6e0-47cb-833e-de6133960387' (T 'Перезавантаження в безпечний режим' 'Rebooting into Safe Mode') (T 'Вимагачі перезавантажують ПК у безпечний режим, де антивірус не працює. Вручну зайти в безпечний режим можна як і раніше.' 'Ransomware reboots the PC into Safe Mode, where the antivirus does not run. You can still enter Safe Mode manually.'))
    )
}
