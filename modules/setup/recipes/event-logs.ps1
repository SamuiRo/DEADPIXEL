# Щоб після краша було що аналізувати: більші журнали подій і запис дампу пам'яті при BSOD.
@{
    Title       = 'Журнали і дампи для діагностики'
    Description = 'Системний журнал зберігає лише кілька тижнів (20 МБ за замовчуванням). Збільшення і увімкнений дамп пам''яті дають історію для аналізу крашів.'
    Items       = @(
        @{ Kind = 'Custom'; Id = 'log-system'; Title = 'Розмір журналу System, МБ'; Desired = 100
           Hint = 'Сюди пишуть драйвери, диски, перезавантаження. За замовчуванням ~20 МБ - вистачає на кілька тижнів, а для пошуку закономірності між рідкісними крашами потрібно більше. Значення 100 означає "100 МБ або більше".'
           Get = { $mb = [math]::Round((Get-WinEvent -ListLog System).MaximumSizeInBytes / 1MB); if ($mb -ge 100) { 100 } else { $mb } }
           Set = { param($value) wevtutil sl System /ms:$([long]$value * 1MB); if ($LASTEXITCODE -ne 0) { throw "wevtutil: код $LASTEXITCODE" } } }
        @{ Kind = 'Custom'; Id = 'log-application'; Title = 'Розмір журналу Application, МБ'; Desired = 64
           Hint = 'Тут падіння і зависання програм (Application Error / Hang) і звіти WER про зависання GPU. 64 = "64 МБ або більше".'
           Get = { $mb = [math]::Round((Get-WinEvent -ListLog Application).MaximumSizeInBytes / 1MB); if ($mb -ge 64) { 64 } else { $mb } }
           Set = { param($value) wevtutil sl Application /ms:$([long]$value * 1MB); if ($LASTEXITCODE -ne 0) { throw "wevtutil: код $LASTEXITCODE" } } }
        @{ Kind = 'Custom'; Id = 'crash-dump'; Title = 'Дамп пам''яті при BSOD'; Desired = 'увімкнено'
           Hint = 'Без дампу синій екран не залишає доказів: не видно, який драйвер винен. Підходить будь-який режим, крім "не записувати": малий (3) пише лише мінідамп у C:\Windows\Minidump - цього досить для аналізу в DEADPIXEL; автоматичний (7, стандарт Windows) - ще й дамп ядра. Якщо вимкнено, застосування поставить автоматичний; відкат поверне попередній режим.'
           Get = {
               $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -ErrorAction SilentlyContinue).CrashDumpEnabled
               if ($v -in 1, 2, 3, 7) { 'увімкнено' } else { [string][int]$v }
           }
           Set = { param($value)
               $n = if ($value -eq 'увімкнено') { 7 } else { [int]$value }
               Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value $n -Type DWord } }
    )
    Steps       = @(
        @{ Text = 'Переконайтеся, що файл підкачки увімкнений на диску C: (хоча б "Автоматично"): без нього Windows не запише дамп під час BSOD.'
           Open = 'SystemPropertiesAdvanced.exe'
           Hint = 'Додатково → Швидкодія → Параметри → Додатково → Віртуальна пам''ять.' }
    )

    Tabs        = @(
        @{ Id = 'history'; Title = 'Історія крашів'
           Description = 'Швидкий огляд без DEADPIXEL: синіх екранів, неочікуваних вимкнень і зависань GPU, які зберіг Windows.'
           Steps = @(
               @{ Text = 'Сині екрани (код, параметри, файл дампу).'
                  Hint = 'Читаються службові поля події, тож працює на Windows будь-якою мовою.'
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -MaxEvents 20 -ErrorAction SilentlyContinue | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  {1}  {2}' -f `$_.TimeCreated, `$_.Properties[0].Value, `$_.Properties[1].Value }" }
               @{ Text = 'Аварійні перезавантаження (Kernel-Power 41): BugcheckCode 0 = вимкнення без синього екрана (живлення, ресет, БЖ).'
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -MaxEvents 20 -ErrorAction SilentlyContinue | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  BugcheckCode=0x{1:X}' -f `$_.TimeCreated, [long]`$_.Properties[0].Value }" }
               @{ Text = 'Дампи зависань GPU, відновлених без синього екрана (LiveKernelReports).'
                  Run = "Get-ChildItem `$env:SystemRoot\LiveKernelReports -Recurse -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20 LastWriteTime, @{ n = 'Тип'; e = { `$_.Directory.Name } }, Name | Format-Table -AutoSize" }
               @{ Text = 'Мінідампи синіх екранів.'
                  Run = "Get-ChildItem `$env:SystemRoot\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Format-Table LastWriteTime, Name, Length -AutoSize" }
               @{ Text = 'Звідки береться найдавніший запис журналу System (тобто скільки історії є).'
                  Run = "'Найстаріша подія: ' + (Get-WinEvent -LogName System -MaxEvents 1 -Oldest).TimeCreated; 'Розмір журналу, МБ: ' + [math]::Round((Get-WinEvent -ListLog System).MaximumSizeInBytes / 1MB)" }
           ) }
    )
}
