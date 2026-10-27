# Безкоштовні інструменти, які знадобилися під час діагностики, і як ними користуватися.
# Пункт = "встановлено" (True/False); застосування ставить через winget, відкат видаляє те, що ставили.
@{
    Title       = (T 'Інструменти діагностики' 'Diagnostic tools')
    Description = (T 'WinDbg (аналіз дампів), LibreHardwareMonitor (температура CPU і датчики), CrystalDiskInfo (SMART). Плюс сценарії тестів відеопам''яті і стрес-тестів.' 'WinDbg (dump analysis), LibreHardwareMonitor (CPU temperature and sensors), CrystalDiskInfo (SMART). Plus VRAM test and stress test scenarios.')
    Items       = @(
        @{ Kind = 'Custom'; Id = 'windbg'; Title = (T 'WinDbg (аналіз дампів BSOD/TDR)' 'WinDbg (BSOD/TDR dump analysis)'); Desired = 'True'
           Hint = (T 'Налагоджувач Microsoft. DEADPIXEL використовує його cdb.exe для !analyze -v: показує драйвер і місце збою в дампі.' 'Microsoft''s debugger. DEADPIXEL uses its cdb.exe for !analyze -v: it shows the driver and the failure point in a dump.')
           Get = { [string][bool](Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction SilentlyContinue) }
           Set = { param($value)
               if ($value -eq 'True') { winget install --id Microsoft.WinDbg -e --silent --accept-package-agreements --accept-source-agreements }
               else { winget uninstall --id Microsoft.WinDbg -e --silent } } }
        @{ Kind = 'Custom'; Id = 'lhm'; Title = (T 'LibreHardwareMonitor (температура CPU)' 'LibreHardwareMonitor (CPU temperature)'); Desired = 'True'
           Hint = (T 'Windows не віддає температуру Ryzen без драйвера. Запущений LibreHardwareMonitor (від адміністратора) публікує датчики через WMI, і DEADPIXEL сам їх підхоплює. В Options увімкніть Run On Windows Startup, Start Minimized, Minimize To Tray.' 'Windows does not expose Ryzen temperature without a driver. A running LibreHardwareMonitor (as administrator) publishes sensors via WMI and DEADPIXEL picks them up. In Options enable Run On Windows Startup, Start Minimized, Minimize To Tray.')
           Get = { $o = winget list --id LibreHardwareMonitor.LibreHardwareMonitor -e --accept-source-agreements 2>$null | Out-String; [string]($LASTEXITCODE -eq 0 -and $o -match 'LibreHardwareMonitor') }
           Set = { param($value)
               if ($value -eq 'True') { winget install --id LibreHardwareMonitor.LibreHardwareMonitor -e --silent --accept-package-agreements --accept-source-agreements }
               else { winget uninstall --id LibreHardwareMonitor.LibreHardwareMonitor -e --silent } } }
        @{ Kind = 'Custom'; Id = 'cdi'; Title = (T 'CrystalDiskInfo (SMART дисків)' 'CrystalDiskInfo (disk SMART)'); Desired = 'True'
           Hint = (T 'Зручний перегляд SMART, зокрема для USB-кишень, які Windows не завжди показує. Дивіться Reallocated/Pending/Uncorrectable (мають бути 0) і UDMA CRC (помилки кабелю).' 'A convenient SMART viewer, including for USB enclosures Windows does not always show. Watch Reallocated/Pending/Uncorrectable (should be 0) and UDMA CRC (cable errors).')
           Get = { $o = winget list --id CrystalDewWorld.CrystalDiskInfo -e --accept-source-agreements 2>$null | Out-String; [string]($LASTEXITCODE -eq 0 -and $o -match 'CrystalDiskInfo') }
           Set = { param($value)
               if ($value -eq 'True') { winget install --id CrystalDewWorld.CrystalDiskInfo -e --silent --accept-package-agreements --accept-source-agreements }
               else { winget uninstall --id CrystalDewWorld.CrystalDiskInfo -e --silent } } }
    )
    Steps       = @(
        (T 'Якщо winget немає (старі збірки Windows 10, LTSC) - встановіть "App Installer" з Microsoft Store або завантажте програми з сайтів виробників.' 'If winget is missing (old Windows 10 builds, LTSC), install "App Installer" from the Microsoft Store or download the programs from their vendors.')
    )

    Tabs        = @(
        @{ Id = 'vram'; Title = (T 'Тест відеопам''яті' 'VRAM test')
           Description = (T 'memtest_vulkan перевіряє майже весь обсяг VRAM. Несправна пам''ять зазвичай дає артефакти і вильоти; повне зникнення карти з шини більше схоже на PCIe/живлення.' 'memtest_vulkan tests almost all of the VRAM. Faulty memory usually causes artifacts and crashes; the card vanishing from the bus looks more like PCIe/power.')
           Steps = @(
               @{ Text = (T 'Завантажте memtest_vulkan (розділ Releases, архів для Windows).' 'Download memtest_vulkan (the Releases section, the Windows archive).'); Open = 'https://github.com/GpuZelenograd/memtest_vulkan/releases' }
               (T 'Закрийте ігри і браузер. DEADPIXEL залиште працювати - якщо карта зависне під час тесту, чорна скринька запише момент.' 'Close games and the browser. Leave DEADPIXEL running — if the card hangs during the test, the black box records the moment.')
               (T 'Розпакуйте й запустіть memtest_vulkan.exe, виберіть відеокарту. Стандартний тест - 5 хвилин; дайте попрацювати 30–60 хв, щоб пам''ять прогрілася, і зупиніть Ctrl+C.' 'Unpack and run memtest_vulkan.exe, pick the graphics card. The standard test is 5 minutes; let it run 30–60 min so the memory warms up, then stop with Ctrl+C.')
               @{ Text = (T 'Результат: "no any errors, testing PASSed" - пам''ять справна. Будь-яке ERROR - несправна, це гарантійний випадок.' 'Result: "no any errors, testing PASSed" — the memory is fine. Any ERROR means it is faulty — a warranty case.')
                  Hint = (T 'Зробіть скріншот підсумку - знадобиться для звернення по гарантії.' 'Take a screenshot of the summary — you will need it for a warranty claim.') }
           ) }
        @{ Id = 'stress'; Title = (T 'Стрес-тести GPU' 'GPU stress tests')
           Description = (T 'Навантаження, схоже на ігрове: графічний чип і живлення. Корисно відтворити зависання під наглядом DEADPIXEL.' 'A game-like load on the graphics chip and power delivery. Useful to reproduce a hang while DEADPIXEL watches.')
           Steps = @(
               @{ Text = (T 'OCCT: тест "3D Adaptive" або "Power", 30–60 хв. Помилок має бути 0.' 'OCCT: the "3D Adaptive" or "Power" test, 30–60 min. There should be 0 errors.'); Open = 'https://www.ocbase.com/' }
               @{ Text = (T '3DMark: Steel Nomad / Time Spy Stress Test (20 циклів). Стабільність від 97% - норма.' '3DMark: Steel Nomad / Time Spy Stress Test (20 loops). Frame stability of 97% or more is normal.'); Open = 'https://store.steampowered.com/app/223850/3DMark/' }
               (T 'Якщо карта зависла під тестом - відкрийте DEADPIXEL → Краші: таймлайн покаже стан за хвилини до збою (частоти, споживання, обмеження).' 'If the card hung during a test, open DEADPIXEL → Crashes: the timeline shows the state in the minutes before the failure (clocks, power, throttling).')
           ) }
        @{ Id = 'dump'; Title = (T 'Аналіз дампу вручну' 'Manual dump analysis')
           Description = (T 'Те саме, що робить DEADPIXEL кнопкою "Аналізувати", але вручну в консолі.' 'The same thing DEADPIXEL''s "Analyze" button does, but manually in a console.')
           Params = @(
               @{ Name = 'DUMP'; Title = (T 'Шлях до .dmp' 'Path to .dmp'); Default = 'C:\Windows\Minidump\'; Pattern = '.+\.dmp'
                  Hint = (T 'Мінідампи (C:\Windows\Minidump) читає лише адміністратор; дампи TDR (C:\Windows\LiveKernelReports\WATCHDOG) - будь-хто.' 'Minidumps (C:\Windows\Minidump) are readable only by administrators; TDR dumps (C:\Windows\LiveKernelReports\WATCHDOG) by anyone.') }
           )
           Steps = @(
               @{ Text = (T 'Знайдіть cdb.exe з пакета WinDbg.' 'Find cdb.exe from the WinDbg package.')
                  Run = "`$p = (Get-AppxPackage Microsoft.WinDbg).InstallLocation; if (`$p) { Join-Path `$p 'amd64\cdb.exe' } else { '" + (T 'WinDbg не встановлено - пункт вище на вкладці Рекомендовані' 'WinDbg is not installed - see the item on the Recommended tab') + "' }"
                  Expect = 'cdb\.exe' }
               @{ Text = (T 'Проаналізуйте {DUMP}. Дивіться MODULE_NAME / IMAGE_NAME (винний драйвер), SYMBOL_NAME (місце) і FAILURE_BUCKET_ID (сигнатура для пошуку).' 'Analyze {DUMP}. Look at MODULE_NAME / IMAGE_NAME (the faulting driver), SYMBOL_NAME (the location) and FAILURE_BUCKET_ID (a signature to search for).'); Admin = $true; If = 'ok'
                  Hint = (T 'Перший запуск довгий: завантажуються символи Microsoft (кеш у %TEMP%\symbols).' 'The first run is slow: Microsoft symbols are downloaded (cached in %TEMP%\symbols).')
                  Run = "`$cdb = Join-Path (Get-AppxPackage Microsoft.WinDbg).InstallLocation 'amd64\cdb.exe'; & `$cdb -z {DUMP} -y ('srv*' + `$env:TEMP + '\symbols*https://msdl.microsoft.com/download/symbols') -c '!analyze -v; q' | Select-String '^(BUGCHECK_CODE|MODULE_NAME|IMAGE_NAME|SYMBOL_NAME|FAILURE_BUCKET_ID|PROCESS_NAME):'" }
           ) }
    )
}
