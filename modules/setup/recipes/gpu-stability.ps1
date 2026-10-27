# Відеокарта: зависання драйвера (TDR, LiveKernelEvent 141/117) і BSOD 0x116 VIDEO_TDR_FAILURE.
# Тут немає пунктів "застосувати": усе, що змінюється автоматично, - у рецептах pcie-aspm і fast-startup.
# Решта - покрокові сценарії: BIOS, перевірка шини PCIe, тест живлення, діагностичні перемикачі, чиста установка драйвера.
# Тексти - парами T 'українською' 'English' (modules\common\Lang.ps1); повідомлення команд Run підставляються під час завантаження.
@{
    Title       = (T 'Відеокарта: зависання і BSOD 0x116' 'Graphics card: hangs and BSOD 0x116')
    Description = (T 'Порядок дій при TDR / VIDEO_TDR_FAILURE: шина PCIe, енергозбереження, живлення, драйвер. Міняйте по одному кроку і спостерігайте тиждень.' 'What to do about TDR / VIDEO_TDR_FAILURE: PCIe bus, power saving, power delivery, driver. Change one thing at a time and watch for a week.')
    Items       = @()
    Steps       = @(
        @{ Text = (T 'Спершу застосуйте рецепт "PCIe ASPM вимкнено" — найдешевший крок проти зависань на виході з енергозбереження.' 'First apply the "PCIe ASPM off" recipe — the cheapest step against hangs when leaving power saving.')
           Hint = (T 'Якщо карта зависає і в простої, і після виходу з гри - це перший підозрюваний.' 'If the card hangs both at idle and after leaving a game, this is the first suspect.') }
        @{ Text = (T 'Пройдіть сценарій "BIOS: шина PCIe" (Gen4, ASPM, вбудована графіка).' 'Go through the "BIOS: PCIe bus" scenario (Gen4, ASPM, integrated graphics).')
           Hint = (T 'Подія nvlddmkm 153 "BusReset TDR" або зависання з повною втратою відповіді карти вказують на проблему зв''язку по PCIe. Gen5 найчутливіший до якості слота/райзера.' 'Event nvlddmkm 153 "BusReset TDR" or a hang where the card stops responding entirely points to a PCIe link problem. Gen5 is the most sensitive to slot/riser quality.') }
        @{ Text = (T 'Живлення: кожен вхід перехідника 12V-2x6 - окремим кабелем від БЖ, роз''єм вставлено до клацання, перші 3–4 см кабелю без згину.' 'Power: each input of the 12V-2x6 adapter on its own PSU cable, the connector fully clicked in, no bend in the first 3–4 cm of cable.')
           Hint = (T 'Якщо БЖ має рідний кабель 12V-2x6 / 12VHPWR - краще без перехідника. Коли кабелів лише два, одна "косичка" (daisy-chain) допустима, якщо БЖ якісний.' 'If the PSU has a native 12V-2x6 / 12VHPWR cable, skip the adapter. With only two cables, one daisy-chain is acceptable on a quality PSU.') }
        @{ Text = (T 'Оновіть BIOS материнської плати з сайту виробника (нова AGESA/мікрокод часто покращують стабільність PCIe).' 'Update the motherboard BIOS from the vendor site (new AGESA/microcode often improves PCIe stability).')
           Hint = (T 'Після оновлення налаштування BIOS скидаються - повторіть сценарій "BIOS: шина PCIe".' 'BIOS settings reset after the update — repeat the "BIOS: PCIe bus" scenario.') }
        (T 'Якщо після всіх кроків карта все одно зависає на заводських налаштуваннях і нормальних температурах - зберіть пакет для діагностики в DEADPIXEL і звертайтеся по гарантії.' 'If the card still hangs at stock settings and normal temperatures after all steps, build a diagnostics package in DEADPIXEL and file a warranty claim.')
    )

    Tabs        = @(
        @{ Id = 'bios-pcie'; Title = (T 'BIOS: шина PCIe' 'BIOS: PCIe bus')
           Description = (T 'Слот відеокарти в режим Gen4, ASPM на рівні BIOS вимкнено, вбудована графіка вимкнена. Прогрес зберігається через перезавантаження.' 'Graphics slot in Gen4 mode, ASPM off in BIOS, integrated graphics off. Progress survives restarts.')
           Steps = @(
               @{ Text = (T 'Подивіться, на якій швидкості зараз працює шина відеокарти (NVIDIA).' 'See which speed the graphics bus runs at now (NVIDIA).')
                  Hint = (T 'hostmax - максимум слота, gpumax - карти. У простої current падає до Gen1–2, це нормально; під навантаженням має бути максимум.' 'hostmax is the slot maximum, gpumax the card''s. At idle current drops to Gen1–2, which is normal; under load it should be at maximum.')
                  Run = 'nvidia-smi --query-gpu=name,pcie.link.gen.current,pcie.link.gen.gpumax,pcie.link.gen.hostmax,pcie.link.width.current --format=csv' }
               @{ Text = (T 'Дізнайтеся модель плати і версію BIOS.' 'Find out the board model and BIOS version.')
                  Run = 'Get-CimInstance Win32_BaseBoard | Format-List Manufacturer, Product; Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion, ReleaseDate' }
               @{ Text = (T 'Перезавантажте ПК одразу в BIOS/UEFI.' 'Restart the PC straight into BIOS/UEFI.'); Reboot = 'firmware'
                  Hint = (T 'Якщо плата не підтримує вхід з Windows - звичайне перезавантаження і Del / F2 під час старту.' 'If the board cannot enter UEFI from Windows, restart normally and press Del / F2 during boot.') }
               @{ Text = (T 'Слот відеокарти → Gen4 (не плутайте зі слотами M.2 для SSD).' 'Graphics slot → Gen4 (not the M.2 slots for SSDs).')
                  Hint = (T 'MSI: Settings → Advanced → PCIe/PCI Subsystem Settings → PCI_E1 Gen Switch. ASUS: Advanced → PCI Subsystem / Onboard Devices → PCIEX16_1 Link Mode. Gigabyte: Settings → IO Ports → PCIEX16 Bandwidth / PCIe Slot Configuration. Пункти "M2_x Gen Mode" стосуються SSD.' 'MSI: Settings → Advanced → PCIe/PCI Subsystem Settings → PCI_E1 Gen Switch. ASUS: Advanced → PCI Subsystem / Onboard Devices → PCIEX16_1 Link Mode. Gigabyte: Settings → IO Ports → PCIEX16 Bandwidth / PCIe Slot Configuration. "M2_x Gen Mode" items are for SSDs.') }
               @{ Text = (T 'ASPM на рівні BIOS → Disabled.' 'BIOS-level ASPM → Disabled.')
                  Hint = (T 'MSI: "ASPM Control for CPU PCIe" у тому ж меню. Інші: Native ASPM, PEG ASPM, PCIe ASPM Support. Якщо BIOS не віддає ASPM системі, налаштування Windows на нього не впливає.' 'MSI: "ASPM Control for CPU PCIe" in the same menu. Others: Native ASPM, PEG ASPM, PCIe ASPM Support. If the BIOS does not hand ASPM to the OS, the Windows setting has no effect.') }
               @{ Text = (T 'Вбудована графіка → Disabled, якщо монітор підключений до відеокарти.' 'Integrated graphics → Disabled if the monitor is connected to the graphics card.')
                  Hint = (T 'MSI: Advanced → Integrated Graphics Configuration → Integrated Graphics = Disabled, HybridGraphics = Disabled. Гібридна конфігурація інколи провокує TDR.' 'MSI: Advanced → Integrated Graphics Configuration → Integrated Graphics = Disabled, HybridGraphics = Disabled. A hybrid setup sometimes provokes TDRs.') }
               (T 'Збережіть і вийдіть (зазвичай F10).' 'Save and exit (usually F10).')
               @{ Text = (T 'Після старту Windows перевірте, що вбудована графіка зникла зі списку адаптерів.' 'After Windows starts, check that integrated graphics is gone from the adapter list.')
                  Run = 'Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, Status -AutoSize' }
               @{ Text = (T 'Перевірте швидкість шини під навантаженням (запустіть гру/тест, потім виконайте) — має бути 4.' 'Check the bus speed under load (start a game or test, then run this) — it should be 4.')
                  Run = 'nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.hostmax,pstate --format=csv' }
           ) }

        @{ Id = 'power-limit'; Title = (T 'Тест живлення: Power Limit' 'Power test: Power Limit')
           Description = (T 'Тимчасово знизити ліміт потужності відеокарти. Якщо з обмеженням зависання зникають, а без нього повертаються - підозра на живлення (кабель, перехідник, БЖ). Ліміт скидається після перезавантаження.' 'Temporarily lower the graphics card power limit. If hangs disappear with the limit and return without it, suspect power delivery (cable, adapter, PSU). The limit resets on restart.')
           Params = @(
               @{ Name = 'W'; Title = (T 'Ліміт, Вт' 'Limit, W'); Default = '240'; Pattern = '\d{2,3}'
                  Hint = (T 'Приблизно 80% від стандартного ліміту (подивіться у першому кроці). Для карти на 300 Вт - 240.' 'About 80% of the default limit (see the first step). For a 300 W card — 240.') }
           )
           Steps = @(
               @{ Text = (T 'Подивіться поточний, стандартний і допустимий ліміт потужності.' 'See the current, default and allowed power limits.')
                  Run = 'nvidia-smi --query-gpu=name,power.limit,power.default_limit,power.min_limit,power.max_limit --format=csv' }
               @{ Text = (T 'Встановіть ліміт {W} Вт.' 'Set the limit to {W} W.'); Admin = $true
                  Hint = (T 'Це не розгін: карта просто не перевищує заданої потужності. Продуктивність падає на кілька відсотків.' 'This is not overclocking: the card simply stays under the set power. Performance drops by a few percent.')
                  Run = 'nvidia-smi -pl {W}'; Expect = '(?i)power limit.*set' }
               @{ Text = (T 'nvidia-smi не дав змінити ліміт - зробіть це повзунком Power Limit у MSI Afterburner (80%).' 'nvidia-smi could not change the limit — use the Power Limit slider in MSI Afterburner (80%).'); If = 'fail'
                  Open = 'https://www.msi.com/Landing/afterburner/graphics-cards' }
               @{ Text = (T 'Перевірте, що ліміт застосовано, і користуйтеся ПК як зазвичай кілька днів.' 'Check that the limit is applied and use the PC as usual for a few days.')
                  Run = 'nvidia-smi --query-gpu=power.limit,power.draw --format=csv' }
               @{ Text = (T 'Повернути стандартний ліміт (або просто перезавантажте ПК).' 'Restore the default limit (or just restart the PC).'); Admin = $true
                  Run = "`$d = (nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits).Trim(); nvidia-smi -pl `$d" }
           ) }

        @{ Id = 'toggles'; Title = (T 'Діагностичні перемикачі' 'Diagnostic toggles')
           Description = (T 'HAGS, MPO і TdrDelay - не "ліки", а способи звузити причину. Вмикайте по одному, кожен потребує перезавантаження, і повертайте, якщо не допомогло.' 'HAGS, MPO and TdrDelay are not "cures" but ways to narrow down the cause. Change one at a time, each needs a restart, and revert it if it did not help.')
           Steps = @(
               @{ Text = (T 'Подивіться поточні значення.' 'See the current values.')
                  Run = "`$g = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue; `$d = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -ErrorAction SilentlyContinue; '" + (T 'HAGS (HwSchMode, 2=увімк, 1=вимк): ' 'HAGS (HwSchMode, 2=on, 1=off): ') + "' + `$g.HwSchMode; '" + (T 'TdrDelay, с (порожньо = 2): ' 'TdrDelay, s (empty = 2): ') + "' + `$g.TdrDelay; '" + (T 'MPO (OverlayTestMode, 5 = вимкнено): ' 'MPO (OverlayTestMode, 5 = off): ') + "' + `$d.OverlayTestMode" }
               @{ Text = (T 'Вимкнути апаратне планування GPU (HAGS).' 'Turn off hardware-accelerated GPU scheduling (HAGS).'); Admin = $true
                  Hint = (T 'Те саме, що Параметри → Дисплей → Графіка → "Апаратне прискорення планування GPU". Корисно, якщо TDR з''явилися після оновлення Windows/драйвера.' 'Same as Settings → Display → Graphics → "Hardware-accelerated GPU scheduling". Useful if TDRs appeared after a Windows or driver update.')
                  Run = "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 1 -Type DWord; '" + (T 'HAGS вимкнено, потрібне перезавантаження' 'HAGS off, restart required') + "'" }
               @{ Text = (T 'Вимкнути Multiplane Overlay (MPO).' 'Turn off Multiplane Overlay (MPO).'); Admin = $true
                  Hint = (T 'Відомий винуватець мерехтіння, чорних екранів і TDR у простої/на робочому столі з кількома моніторами або HDR.' 'A known cause of flicker, black screens and TDRs at idle/on the desktop with multiple monitors or HDR.')
                  Run = "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name OverlayTestMode -Value 5 -Type DWord; '" + (T 'MPO вимкнено, потрібне перезавантаження' 'MPO off, restart required') + "'" }
               @{ Text = (T 'Збільшити TdrDelay до 8 с (за замовчуванням 2 с).' 'Raise TdrDelay to 8 s (default 2 s).'); Admin = $true
                  Confirm = (T 'TdrDelay не лікує зависання, а лише дає драйверу більше часу. Справжнє зависання стане довшим замороженням перед відновленням. Продовжити?' 'TdrDelay does not cure hangs, it only gives the driver more time. A real hang becomes a longer freeze before recovery. Continue?')
                  Hint = (T 'Має сенс, якщо TDR трапляються під важкими обчисленнями (рендер, ШІ), а не через несправність.' 'Makes sense if TDRs happen under heavy compute (rendering, AI) rather than from a fault.')
                  Run = "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name TdrDelay -Value 8 -Type DWord; '" + (T 'TdrDelay = 8, потрібне перезавантаження' 'TdrDelay = 8, restart required') + "'" }
               @{ Text = (T 'Перезавантажте ПК, щоб зміни набули чинності.' 'Restart the PC for the changes to take effect.'); Reboot = 'restart' }
               @{ Text = (T 'Повернути все як за замовчуванням (HAGS увімк., MPO увімк., TdrDelay стандартний).' 'Restore defaults (HAGS on, MPO on, TdrDelay default).'); Admin = $true
                  Run = "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 2 -Type DWord; Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name TdrDelay -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name OverlayTestMode -ErrorAction SilentlyContinue; '" + (T 'Повернуто, потрібне перезавантаження' 'Restored, restart required') + "'" }
           ) }

        @{ Id = 'clean-driver'; Title = (T 'Чиста установка драйвера' 'Clean driver install')
           Description = (T 'Повне видалення відеодрайвера через DDU у безпечному режимі і встановлення свіжого з сайту виробника.' 'Fully remove the graphics driver with DDU in Safe Mode and install a fresh one from the vendor site.')
           Steps = @(
               @{ Text = (T 'Подивіться поточну версію драйвера.' 'See the current driver version.')
                  Run = 'nvidia-smi --query-gpu=name,driver_version --format=csv; Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, DriverDate -AutoSize' }
               @{ Text = (T 'Завантажте свіжий драйвер з сайту виробника відеокарти (не запускайте ще).' 'Download a fresh driver from the graphics vendor site (do not run it yet).'); Open = 'https://www.nvidia.com/Download/index.aspx' }
               @{ Text = (T 'Завантажте Display Driver Uninstaller (DDU).' 'Download Display Driver Uninstaller (DDU).'); Open = 'https://www.guru3d.com/download/display-driver-uninstaller-download/'
                  Hint = (T 'Офіційна сторінка DDU - на guru3d.com і wagnardsoft.com. Не качайте з інших сайтів.' 'The official DDU pages are guru3d.com and wagnardsoft.com. Do not download it elsewhere.') }
               (T 'Від''єднайте інтернет (щоб Windows Update не поставив свій драйвер), завантажтеся в безпечний режим.' 'Disconnect from the internet (so Windows Update does not install its own driver) and boot into Safe Mode.')
               (T 'Запустіть DDU → виберіть GPU і виробника → "Clean and restart".' 'Run DDU → select GPU and vendor → "Clean and restart".')
               (T 'Після старту встановіть завантажений драйвер (вибіркова установка → "Чиста установка", якщо є така опція), підключіть інтернет.' 'After restart, install the downloaded driver (custom install → "Clean install" if offered), then reconnect the internet.')
           ) }
    )
}
