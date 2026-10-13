# Відеокарта: зависання драйвера (TDR, LiveKernelEvent 141/117) і BSOD 0x116 VIDEO_TDR_FAILURE.
# Тут немає пунктів "застосувати": усе, що змінюється автоматично, - у рецептах pcie-aspm і fast-startup.
# Решта - покрокові сценарії: BIOS, перевірка шини PCIe, тест живлення, діагностичні перемикачі, чиста установка драйвера.
@{
    Title       = 'Відеокарта: зависання і BSOD 0x116'
    Description = 'Порядок дій при TDR / VIDEO_TDR_FAILURE: шина PCIe, енергозбереження, живлення, драйвер. Міняйте по одному кроку і спостерігайте тиждень.'
    Items       = @()
    Steps       = @(
        @{ Text = 'Спершу застосуйте рецепт "PCIe ASPM вимкнено" — найдешевший крок проти зависань на виході з енергозбереження.'
           Hint = 'Якщо карта зависає і в простої, і після виходу з гри - це перший підозрюваний.' }
        @{ Text = 'Пройдіть сценарій "BIOS: шина PCIe" (Gen4, ASPM, вбудована графіка).'
           Hint = 'Подія nvlddmkm 153 "BusReset TDR" або зависання з повною втратою відповіді карти вказують на проблему зв''язку по PCIe. Gen5 найчутливіший до якості слота/райзера.' }
        @{ Text = 'Живлення: кожен вхід перехідника 12V-2x6 - окремим кабелем від БЖ, роз''єм вставлено до клацання, перші 3–4 см кабелю без згину.'
           Hint = 'Якщо БЖ має рідний кабель 12V-2x6 / 12VHPWR - краще без перехідника. Коли кабелів лише два, одна "косичка" (daisy-chain) допустима, якщо БЖ якісний.' }
        @{ Text = 'Оновіть BIOS материнської плати з сайту виробника (нова AGESA/мікрокод часто покращують стабільність PCIe).'
           Hint = 'Після оновлення налаштування BIOS скидаються - повторіть сценарій "BIOS: шина PCIe".' }
        'Якщо після всіх кроків карта все одно зависає на заводських налаштуваннях і нормальних температурах - зберіть пакет для діагностики в DEADPIXEL і звертайтеся по гарантії.'
    )

    Tabs        = @(
        @{ Id = 'bios-pcie'; Title = 'BIOS: шина PCIe'
           Description = 'Слот відеокарти в режим Gen4, ASPM на рівні BIOS вимкнено, вбудована графіка вимкнена. Прогрес зберігається через перезавантаження.'
           Steps = @(
               @{ Text = 'Подивіться, на якій швидкості зараз працює шина відеокарти (NVIDIA).'
                  Hint = 'hostmax - максимум слота, gpumax - карти. У простої current падає до Gen1–2, це нормально; під навантаженням має бути максимум.'
                  Run = 'nvidia-smi --query-gpu=name,pcie.link.gen.current,pcie.link.gen.gpumax,pcie.link.gen.hostmax,pcie.link.width.current --format=csv' }
               @{ Text = 'Дізнайтеся модель плати і версію BIOS.'
                  Run = 'Get-CimInstance Win32_BaseBoard | Format-List Manufacturer, Product; Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion, ReleaseDate' }
               @{ Text = 'Перезавантажте ПК одразу в BIOS/UEFI.'; Reboot = 'firmware'
                  Hint = 'Якщо плата не підтримує вхід з Windows - звичайне перезавантаження і Del / F2 під час старту.' }
               @{ Text = 'Слот відеокарти → Gen4 (не плутайте зі слотами M.2 для SSD).'
                  Hint = 'MSI: Settings → Advanced → PCIe/PCI Subsystem Settings → PCI_E1 Gen Switch. ASUS: Advanced → PCI Subsystem / Onboard Devices → PCIEX16_1 Link Mode. Gigabyte: Settings → IO Ports → PCIEX16 Bandwidth / PCIe Slot Configuration. Пункти "M2_x Gen Mode" стосуються SSD.' }
               @{ Text = 'ASPM на рівні BIOS → Disabled.'
                  Hint = 'MSI: "ASPM Control for CPU PCIe" у тому ж меню. Інші: Native ASPM, PEG ASPM, PCIe ASPM Support. Якщо BIOS не віддає ASPM системі, налаштування Windows на нього не впливає.' }
               @{ Text = 'Вбудована графіка → Disabled, якщо монітор підключений до відеокарти.'
                  Hint = 'MSI: Advanced → Integrated Graphics Configuration → Integrated Graphics = Disabled, HybridGraphics = Disabled. Гібридна конфігурація інколи провокує TDR.' }
               'Збережіть і вийдіть (зазвичай F10).'
               @{ Text = 'Після старту Windows перевірте, що вбудована графіка зникла зі списку адаптерів.'
                  Run = 'Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, Status -AutoSize' }
               @{ Text = 'Перевірте швидкість шини під навантаженням (запустіть гру/тест, потім виконайте) — має бути 4.'
                  Run = 'nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.hostmax,pstate --format=csv' }
           ) }

        @{ Id = 'power-limit'; Title = 'Тест живлення: Power Limit'
           Description = 'Тимчасово знизити ліміт потужності відеокарти. Якщо з обмеженням зависання зникають, а без нього повертаються - підозра на живлення (кабель, перехідник, БЖ). Ліміт скидається після перезавантаження.'
           Params = @(
               @{ Name = 'W'; Title = 'Ліміт, Вт'; Default = '240'; Pattern = '\d{2,3}'
                  Hint = 'Приблизно 80% від стандартного ліміту (подивіться у першому кроці). Для карти на 300 Вт - 240.' }
           )
           Steps = @(
               @{ Text = 'Подивіться поточний, стандартний і допустимий ліміт потужності.'
                  Run = 'nvidia-smi --query-gpu=name,power.limit,power.default_limit,power.min_limit,power.max_limit --format=csv' }
               @{ Text = 'Встановіть ліміт {W} Вт.'; Admin = $true
                  Hint = 'Це не розгін: карта просто не перевищує заданої потужності. Продуктивність падає на кілька відсотків.'
                  Run = 'nvidia-smi -pl {W}'; Expect = '(?i)power limit.*set' }
               @{ Text = 'nvidia-smi не дав змінити ліміт - зробіть це повзунком Power Limit у MSI Afterburner (80%).'; If = 'fail'
                  Open = 'https://www.msi.com/Landing/afterburner/graphics-cards' }
               @{ Text = 'Перевірте, що ліміт застосовано, і користуйтеся ПК як зазвичай кілька днів.'
                  Run = 'nvidia-smi --query-gpu=power.limit,power.draw --format=csv' }
               @{ Text = 'Повернути стандартний ліміт (або просто перезавантажте ПК).'; Admin = $true
                  Run = "`$d = (nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits).Trim(); nvidia-smi -pl `$d" }
           ) }

        @{ Id = 'toggles'; Title = 'Діагностичні перемикачі'
           Description = 'HAGS, MPO і TdrDelay - не "ліки", а способи звузити причину. Вмикайте по одному, кожен потребує перезавантаження, і повертайте, якщо не допомогло.'
           Steps = @(
               @{ Text = 'Подивіться поточні значення.'
                  Run = "`$g = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue; `$d = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -ErrorAction SilentlyContinue; 'HAGS (HwSchMode, 2=увімк, 1=вимк): ' + `$g.HwSchMode; 'TdrDelay, с (порожньо = 2): ' + `$g.TdrDelay; 'MPO (OverlayTestMode, 5 = вимкнено): ' + `$d.OverlayTestMode" }
               @{ Text = 'Вимкнути апаратне планування GPU (HAGS).'; Admin = $true
                  Hint = 'Те саме, що Параметри → Дисплей → Графіка → "Апаратне прискорення планування GPU". Корисно, якщо TDR з''явилися після оновлення Windows/драйвера.'
                  Run = "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 1 -Type DWord; 'HAGS вимкнено, потрібне перезавантаження'" }
               @{ Text = 'Вимкнути Multiplane Overlay (MPO).'; Admin = $true
                  Hint = 'Відомий винуватець мерехтіння, чорних екранів і TDR у простої/на робочому столі з кількома моніторами або HDR.'
                  Run = "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name OverlayTestMode -Value 5 -Type DWord; 'MPO вимкнено, потрібне перезавантаження'" }
               @{ Text = 'Збільшити TdrDelay до 8 с (за замовчуванням 2 с).'; Admin = $true
                  Confirm = 'TdrDelay не лікує зависання, а лише дає драйверу більше часу. Справжнє зависання стане довшим замороженням перед відновленням. Продовжити?'
                  Hint = 'Має сенс, якщо TDR трапляються під важкими обчисленнями (рендер, ШІ), а не через несправність.'
                  Run = "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name TdrDelay -Value 8 -Type DWord; 'TdrDelay = 8, потрібне перезавантаження'" }
               @{ Text = 'Перезавантажте ПК, щоб зміни набули чинності.'; Reboot = 'restart' }
               @{ Text = 'Повернути все як за замовчуванням (HAGS увімк., MPO увімк., TdrDelay стандартний).'; Admin = $true
                  Run = "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 2 -Type DWord; Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name TdrDelay -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name OverlayTestMode -ErrorAction SilentlyContinue; 'Повернуто, потрібне перезавантаження'" }
           ) }

        @{ Id = 'clean-driver'; Title = 'Чиста установка драйвера'
           Description = 'Повне видалення відеодрайвера через DDU у безпечному режимі і встановлення свіжого з сайту виробника.'
           Steps = @(
               @{ Text = 'Подивіться поточну версію драйвера.'
                  Run = 'nvidia-smi --query-gpu=name,driver_version --format=csv; Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, DriverDate -AutoSize' }
               @{ Text = 'Завантажте свіжий драйвер з сайту виробника відеокарти (не запускайте ще).'; Open = 'https://www.nvidia.com/Download/index.aspx' }
               @{ Text = 'Завантажте Display Driver Uninstaller (DDU).'; Open = 'https://www.guru3d.com/download/display-driver-uninstaller-download/'
                  Hint = 'Офіційна сторінка DDU - на guru3d.com і wagnardsoft.com. Не качайте з інших сайтів.' }
               'Від''єднайте інтернет (щоб Windows Update не поставив свій драйвер), завантажтеся в безпечний режим.'
               'Запустіть DDU → виберіть GPU і виробника → "Clean and restart".'
               'Після старту встановіть завантажений драйвер (вибіркова установка → "Чиста установка", якщо є така опція), підключіть інтернет.'
           ) }
    )
}
