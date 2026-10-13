# Безкоштовні інструменти, які знадобилися під час діагностики, і як ними користуватися.
# Пункт = "встановлено" (True/False); застосування ставить через winget, відкат видаляє те, що ставили.
@{
    Title       = 'Інструменти діагностики'
    Description = 'WinDbg (аналіз дампів), LibreHardwareMonitor (температура CPU і датчики), CrystalDiskInfo (SMART). Плюс сценарії тестів відеопам''яті і стрес-тестів.'
    Items       = @(
        @{ Kind = 'Custom'; Id = 'windbg'; Title = 'WinDbg (аналіз дампів BSOD/TDR)'; Desired = 'True'
           Hint = 'Налагоджувач Microsoft. DEADPIXEL використовує його cdb.exe для !analyze -v: показує драйвер і місце збою в дампі.'
           Get = { [string][bool](Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction SilentlyContinue) }
           Set = { param($value)
               if ($value -eq 'True') { winget install --id Microsoft.WinDbg -e --silent --accept-package-agreements --accept-source-agreements }
               else { winget uninstall --id Microsoft.WinDbg -e --silent } } }
        @{ Kind = 'Custom'; Id = 'lhm'; Title = 'LibreHardwareMonitor (температура CPU)'; Desired = 'True'
           Hint = 'Windows не віддає температуру Ryzen без драйвера. Запущений LibreHardwareMonitor (від адміністратора) публікує датчики через WMI, і DEADPIXEL сам їх підхоплює. В Options увімкніть Run On Windows Startup, Start Minimized, Minimize To Tray.'
           Get = { $o = winget list --id LibreHardwareMonitor.LibreHardwareMonitor -e --accept-source-agreements 2>$null | Out-String; [string]($LASTEXITCODE -eq 0 -and $o -match 'LibreHardwareMonitor') }
           Set = { param($value)
               if ($value -eq 'True') { winget install --id LibreHardwareMonitor.LibreHardwareMonitor -e --silent --accept-package-agreements --accept-source-agreements }
               else { winget uninstall --id LibreHardwareMonitor.LibreHardwareMonitor -e --silent } } }
        @{ Kind = 'Custom'; Id = 'cdi'; Title = 'CrystalDiskInfo (SMART дисків)'; Desired = 'True'
           Hint = 'Зручний перегляд SMART, зокрема для USB-кишень, які Windows не завжди показує. Дивіться Reallocated/Pending/Uncorrectable (мають бути 0) і UDMA CRC (помилки кабелю).'
           Get = { $o = winget list --id CrystalDewWorld.CrystalDiskInfo -e --accept-source-agreements 2>$null | Out-String; [string]($LASTEXITCODE -eq 0 -and $o -match 'CrystalDiskInfo') }
           Set = { param($value)
               if ($value -eq 'True') { winget install --id CrystalDewWorld.CrystalDiskInfo -e --silent --accept-package-agreements --accept-source-agreements }
               else { winget uninstall --id CrystalDewWorld.CrystalDiskInfo -e --silent } } }
    )
    Steps       = @(
        'Якщо winget немає (старі збірки Windows 10, LTSC) - встановіть "App Installer" з Microsoft Store або завантажте програми з сайтів виробників.'
    )

    Tabs        = @(
        @{ Id = 'vram'; Title = 'Тест відеопам''яті'
           Description = 'memtest_vulkan перевіряє майже весь обсяг VRAM. Несправна пам''ять зазвичай дає артефакти і вильоти; повне зникнення карти з шини більше схоже на PCIe/живлення.'
           Steps = @(
               @{ Text = 'Завантажте memtest_vulkan (розділ Releases, архів для Windows).'; Open = 'https://github.com/GpuZelenograd/memtest_vulkan/releases' }
               'Закрийте ігри і браузер. DEADPIXEL залиште працювати - якщо карта зависне під час тесту, чорна скринька запише момент.'
               'Розпакуйте й запустіть memtest_vulkan.exe, виберіть відеокарту. Стандартний тест - 5 хвилин; дайте попрацювати 30–60 хв, щоб пам''ять прогрілася, і зупиніть Ctrl+C.'
               @{ Text = 'Результат: "no any errors, testing PASSed" - пам''ять справна. Будь-яке ERROR - несправна, це гарантійний випадок.'
                  Hint = 'Зробіть скріншот підсумку - знадобиться для звернення по гарантії.' }
           ) }
        @{ Id = 'stress'; Title = 'Стрес-тести GPU'
           Description = 'Навантаження, схоже на ігрове: графічний чип і живлення. Корисно відтворити зависання під наглядом DEADPIXEL.'
           Steps = @(
               @{ Text = 'OCCT: тест "3D Adaptive" або "Power", 30–60 хв. Помилок має бути 0.'; Open = 'https://www.ocbase.com/' }
               @{ Text = '3DMark: Steel Nomad / Time Spy Stress Test (20 циклів). Стабільність від 97% - норма.'; Open = 'https://store.steampowered.com/app/223850/3DMark/' }
               'Якщо карта зависла під тестом - відкрийте DEADPIXEL → Краші: таймлайн покаже стан за хвилини до збою (частоти, споживання, обмеження).'
           ) }
        @{ Id = 'dump'; Title = 'Аналіз дампу вручну'
           Description = 'Те саме, що робить DEADPIXEL кнопкою "Аналізувати", але вручну в консолі.'
           Params = @(
               @{ Name = 'DUMP'; Title = 'Шлях до .dmp'; Default = 'C:\Windows\Minidump\'; Pattern = '.+\.dmp'
                  Hint = 'Мінідампи (C:\Windows\Minidump) читає лише адміністратор; дампи TDR (C:\Windows\LiveKernelReports\WATCHDOG) - будь-хто.' }
           )
           Steps = @(
               @{ Text = 'Знайдіть cdb.exe з пакета WinDbg.'
                  Run = "`$p = (Get-AppxPackage Microsoft.WinDbg).InstallLocation; if (`$p) { Join-Path `$p 'amd64\cdb.exe' } else { 'WinDbg не встановлено - пункт вище на вкладці Рекомендовані' }"
                  Expect = 'cdb\.exe' }
               @{ Text = 'Проаналізуйте {DUMP}. Дивіться MODULE_NAME / IMAGE_NAME (винний драйвер), SYMBOL_NAME (місце) і FAILURE_BUCKET_ID (сигнатура для пошуку).'; Admin = $true; If = 'ok'
                  Hint = 'Перший запуск довгий: завантажуються символи Microsoft (кеш у %TEMP%\symbols).'
                  Run = "`$cdb = Join-Path (Get-AppxPackage Microsoft.WinDbg).InstallLocation 'amd64\cdb.exe'; & `$cdb -z {DUMP} -y ('srv*' + `$env:TEMP + '\symbols*https://msdl.microsoft.com/download/symbols') -c '!analyze -v; q' | Select-String '^(BUGCHECK_CODE|MODULE_NAME|IMAGE_NAME|SYMBOL_NAME|FAILURE_BUCKET_ID|PROCESS_NAME):'" }
           ) }
    )
}
