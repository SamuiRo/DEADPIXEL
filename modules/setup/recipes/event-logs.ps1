# Щоб після краша було що аналізувати: більші журнали подій і запис дампу пам'яті при BSOD.
@{
    Title       = (T 'Журнали і дампи для діагностики' 'Logs and dumps for diagnostics')
    Description = (T 'Системний журнал зберігає лише кілька тижнів (20 МБ за замовчуванням). Збільшення і увімкнений дамп пам''яті дають історію для аналізу крашів.' 'The System log keeps only a few weeks (20 MB by default). A bigger log and an enabled memory dump give history for crash analysis.')
    Items       = @(
        @{ Kind = 'Custom'; Id = 'log-system'; Title = (T 'Розмір журналу System, МБ' 'System log size, MB'); Desired = 100
           Hint = (T 'Сюди пишуть драйвери, диски, перезавантаження. За замовчуванням ~20 МБ - вистачає на кілька тижнів, а для пошуку закономірності між рідкісними крашами потрібно більше. Значення 100 означає "100 МБ або більше".' 'Drivers, disks and reboots log here. The default ~20 MB lasts a few weeks; finding a pattern between rare crashes needs more. The value 100 means "100 MB or more".')
           Get = { $mb = [math]::Round((Get-WinEvent -ListLog System).MaximumSizeInBytes / 1MB); if ($mb -ge 100) { 100 } else { $mb } }
           Set = { param($value) wevtutil sl System /ms:$([long]$value * 1MB); if ($LASTEXITCODE -ne 0) { throw "wevtutil: $LASTEXITCODE" } } }
        @{ Kind = 'Custom'; Id = 'log-application'; Title = (T 'Розмір журналу Application, МБ' 'Application log size, MB'); Desired = 64
           Hint = (T 'Тут падіння і зависання програм (Application Error / Hang) і звіти WER про зависання GPU. 64 = "64 МБ або більше".' 'Application crashes and hangs (Application Error / Hang) and WER reports about GPU hangs go here. 64 = "64 MB or more".')
           Get = { $mb = [math]::Round((Get-WinEvent -ListLog Application).MaximumSizeInBytes / 1MB); if ($mb -ge 64) { 64 } else { $mb } }
           Set = { param($value) wevtutil sl Application /ms:$([long]$value * 1MB); if ($LASTEXITCODE -ne 0) { throw "wevtutil: $LASTEXITCODE" } } }
        # Значення «увімкнено» потрапляє в бекап; якщо мову змінили між «Застосувати» і «Відкотити», Set приймає будь-яку з двох
        @{ Kind = 'Custom'; Id = 'crash-dump'; Title = (T 'Дамп пам''яті при BSOD' 'Memory dump on BSOD'); Desired = (T 'увімкнено' 'enabled')
           Hint = (T 'Без дампу синій екран не залишає доказів: не видно, який драйвер винен. Підходить будь-який режим, крім "не записувати": малий (3) пише лише мінідамп у C:\Windows\Minidump - цього досить для аналізу в DEADPIXEL; автоматичний (7, стандарт Windows) - ще й дамп ядра. Якщо вимкнено, застосування поставить автоматичний; відкат поверне попередній режим.' 'Without a dump a blue screen leaves no evidence: you cannot see which driver is at fault. Any mode except "none" works: small (3) writes only a minidump to C:\Windows\Minidump — enough for analysis in DEADPIXEL; automatic (7, the Windows default) adds a kernel dump. If off, applying sets automatic; reverting restores the previous mode.')
           Get = {
               $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -ErrorAction SilentlyContinue).CrashDumpEnabled
               if ($v -in 1, 2, 3, 7) { T 'увімкнено' 'enabled' } else { [string][int]$v }
           }
           Set = { param($value)
               $n = if ($value -in 'увімкнено', 'enabled') { 7 } else { [int]$value }
               Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value $n -Type DWord } }
    )
    Steps       = @(
        @{ Text = (T 'Переконайтеся, що файл підкачки увімкнений на диску C: (хоча б "Автоматично"): без нього Windows не запише дамп під час BSOD.' 'Make sure the page file is enabled on drive C: (at least "Automatic"): without it Windows cannot write a dump during a BSOD.')
           Open = 'SystemPropertiesAdvanced.exe'
           Hint = (T 'Додатково → Швидкодія → Параметри → Додатково → Віртуальна пам''ять.' 'Advanced → Performance → Settings → Advanced → Virtual memory.') }
    )

    Tabs        = @(
        @{ Id = 'history'; Title = (T 'Історія крашів' 'Crash history')
           Description = (T 'Швидкий огляд без DEADPIXEL: синіх екранів, неочікуваних вимкнень і зависань GPU, які зберіг Windows.' 'A quick overview without DEADPIXEL: blue screens, unexpected shutdowns and GPU hangs that Windows recorded.')
           Steps = @(
               @{ Text = (T 'Сині екрани (код, параметри, файл дампу).' 'Blue screens (code, parameters, dump file).')
                  Hint = (T 'Читаються службові поля події, тож працює на Windows будь-якою мовою.' 'Reads the event''s data fields, so it works on Windows in any language.')
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -MaxEvents 20 -ErrorAction SilentlyContinue | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  {1}  {2}' -f `$_.TimeCreated, `$_.Properties[0].Value, `$_.Properties[1].Value }" }
               @{ Text = (T 'Аварійні перезавантаження (Kernel-Power 41): BugcheckCode 0 = вимкнення без синього екрана (живлення, ресет, БЖ).' 'Unexpected reboots (Kernel-Power 41): BugcheckCode 0 = a shutdown without a blue screen (power, reset, PSU).')
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -MaxEvents 20 -ErrorAction SilentlyContinue | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  BugcheckCode=0x{1:X}' -f `$_.TimeCreated, [long]`$_.Properties[0].Value }" }
               @{ Text = (T 'Дампи зависань GPU, відновлених без синього екрана (LiveKernelReports).' 'Dumps of GPU hangs recovered without a blue screen (LiveKernelReports).')
                  Run = "Get-ChildItem `$env:SystemRoot\LiveKernelReports -Recurse -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20 LastWriteTime, @{ n = 'Type'; e = { `$_.Directory.Name } }, Name | Format-Table -AutoSize" }
               @{ Text = (T 'Мінідампи синіх екранів.' 'Blue screen minidumps.')
                  Run = "Get-ChildItem `$env:SystemRoot\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Format-Table LastWriteTime, Name, Length -AutoSize" }
               @{ Text = (T 'Звідки береться найдавніший запис журналу System (тобто скільки історії є).' 'The oldest System log record (that is, how much history there is).')
                  Run = "'" + (T 'Найстаріша подія: ' 'Oldest event: ') + "' + (Get-WinEvent -LogName System -MaxEvents 1 -Oldest).TimeCreated; '" + (T 'Розмір журналу, МБ: ' 'Log size, MB: ') + "' + [math]::Round((Get-WinEvent -ListLog System).MaximumSizeInBytes / 1MB)" }
           ) }
    )
}
