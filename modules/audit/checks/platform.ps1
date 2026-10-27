# Захист платформи: залізо, прошивка і ядро Windows. Усе читається без прав адміністратора.
# Тексти - парами T 'українською' 'English' (modules\common\Lang.ps1).

function Get-FirmwareType {
    # 1 - Legacy BIOS, 2 - UEFI. GetFirmwareType є з Windows 8 і не потребує прав
    if (-not ('DeadPixelAudit.Firmware' -as [type])) {
        Add-Type -Namespace DeadPixelAudit -Name Firmware -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool GetFirmwareType(out uint t);'
    }
    $t = [uint32]0
    if ([DeadPixelAudit.Firmware]::GetFirmwareType([ref]$t)) { $t } else { 0 }
}

function Get-DeviceGuard {
    Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
}

@{
    Id = 'platform'; Title = (T 'Захист платформи' 'Platform protection'); Order = 1
    Checks = @(
        @{
            Id = 'uefi'; Title = (T 'Режим завантаження UEFI' 'UEFI boot mode')
            Test = {
                switch (Get-FirmwareType) {
                    2 { Ok 'UEFI' }
                    1 { Issue medium 'Legacy BIOS' (T 'Windows завантажується у старому режимі BIOS (CSM). У ньому не працюють Secure Boot і частина захисту ядра.' 'Windows boots in the old BIOS mode (CSM). Secure Boot and part of kernel protection do not work in it.') }
                    default { Unknown (T 'Windows не повідомила режим завантаження.' 'Windows did not report the boot mode.') }
                }
            }
            Explain = (T 'UEFI - сучасний спосіб завантаження ПК, на ньому тримаються Secure Boot, BitLocker з TPM і захист ядра. Legacy BIOS (CSM) - режим сумісності зі старими системами.' 'UEFI is the modern way to boot a PC; Secure Boot, BitLocker with TPM and kernel protection rely on it. Legacy BIOS (CSM) is a compatibility mode for old systems.')
            Pros = @((T 'Можна увімкнути Secure Boot і повний захист ядра' 'Secure Boot and full kernel protection become possible'), (T 'Швидший старт, диски понад 2 ТБ' 'Faster boot, disks larger than 2 TB'))
            Cons = @((T 'Перехід із Legacy потребує конвертації системного диска з MBR у GPT (mbr2gpt) - без резервної копії це ризиковано' 'Moving from Legacy requires converting the system disk from MBR to GPT (mbr2gpt) - risky without a backup'))
            Fix = @{ Steps = @(
                (T 'Зробіть резервну копію важливих файлів.' 'Back up important files.'),
                (T 'Перевірте диск: у командному рядку від адміністратора виконайте mbr2gpt /validate /allowFullOS.' 'Check the disk: in an administrator command prompt run mbr2gpt /validate /allowFullOS.'),
                (T 'Якщо перевірка успішна - mbr2gpt /convert /allowFullOS, потім у BIOS вимкніть CSM і ввімкніть UEFI-завантаження.' 'If it passes - mbr2gpt /convert /allowFullOS, then turn off CSM in BIOS and enable UEFI boot.')
            ) }
        }
        @{
            Id = 'secure-boot'; Title = 'Secure Boot'
            Test = {
                if ((Get-FirmwareType) -ne 2) { return NotApplicable (T 'Secure Boot працює лише в режимі UEFI.' 'Secure Boot works only in UEFI mode.') }
                switch (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled') {
                    1 { Ok (T 'увімкнено' 'on') }
                    0 { Issue high (T 'вимкнено' 'off') (T 'Під час старту ПК прошивка не перевіряє, чи завантажувач Windows справжній.' 'At startup the firmware does not verify that the Windows boot loader is genuine.') }
                    default { Unknown (T 'Не вдалося прочитати стан Secure Boot.' 'Could not read the Secure Boot state.') }
                }
            }
            Explain = (T 'Secure Boot дозволяє прошивці запускати лише підписані завантажувачі. Так буткіт - вірус, що стартує раніше за Windows і антивірус, - не зможе підмінити завантаження.' 'Secure Boot lets the firmware start only signed boot loaders. A bootkit - malware that starts before Windows and the antivirus - cannot hijack the boot.')
            Pros = @(
                (T 'Захист від буткітів і руткітів, які антивірус не бачить' 'Protection from bootkits and rootkits the antivirus cannot see'),
                (T 'Вимога Windows 11 і анти-читів у багатьох онлайн-іграх (Battlefield 6, Valorant, Call of Duty та інші)' 'Required by Windows 11 and by anti-cheats in many online games (Battlefield 6, Valorant, Call of Duty and others)')
            )
            Cons = @(
                (T 'Старі завантажувачі Linux без підпису і дуже старі відеокарти без UEFI-прошивки можуть не запуститися' 'Old unsigned Linux boot loaders and very old graphics cards without UEFI firmware may not start'),
                (T 'Вмикається в BIOS; якщо Windows стоїть у режимі Legacy/MBR, спершу потрібна конвертація диска' 'It is turned on in BIOS; if Windows is installed in Legacy/MBR mode, the disk needs converting first')
            )
            Fix = @{ Recipe = 'secure-boot' }
        }
        @{
            Id = 'tpm'; Title = (T 'Модуль TPM' 'TPM module')
            Test = {
                $out = tpmtool getdeviceinformation 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $out) { return Unknown (T 'tpmtool не відповів.' 'tpmtool did not respond.') }
                $info = @{}
                foreach ($l in $out) { if ($l -match '^\s*-(.+?):\s*(.*)$') { $info[$Matches[1].Trim()] = $Matches[2].Trim() } }
                if ($info['TPM Present'] -ne 'True') { return Issue medium (T 'не знайдено' 'not found') (T 'TPM немає або його вимкнено в BIOS (fTPM у AMD, PTT в Intel).' 'There is no TPM or it is disabled in BIOS (fTPM on AMD, PTT on Intel).') }
                $ver = $info['TPM Version']; $maker = $info['TPM Manufacturer Full Name']
                if ($ver -notlike '2.*') { return Issue low "TPM $ver" (T 'Застаріла версія TPM: Windows 11 і сучасне шифрування потребують TPM 2.0.' 'An outdated TPM version: Windows 11 and modern encryption need TPM 2.0.') }
                Ok "TPM $ver$(if ($maker) { " ($maker)" })"
            }
            Explain = (T 'TPM - захищений чип (або його програмна версія в процесорі), який зберігає ключі шифрування і перевіряє, що систему не підмінили.' 'A TPM is a secure chip (or its firmware version inside the CPU) that stores encryption keys and verifies the system has not been tampered with.')
            Pros = @((T 'Потрібен для BitLocker без пароля при старті, Windows Hello і Windows 11' 'Needed for BitLocker without a boot password, Windows Hello and Windows 11'), (T 'Ключі неможливо скопіювати з диска' 'Keys cannot be copied off the disk'))
            Cons = @((T 'fTPM вмикається в BIOS; скидання fTPM (наприклад, під час оновлення BIOS) потребує ключа відновлення BitLocker' 'fTPM is enabled in BIOS; resetting fTPM (for example during a BIOS update) requires the BitLocker recovery key'))
            Fix = @{ Steps = @((T 'У BIOS увімкніть TPM: на AMD - «AMD fTPM», на Intel - «Intel PTT» (зазвичай у розділі Security або Advanced).' 'Enable the TPM in BIOS: on AMD - "AMD fTPM", on Intel - "Intel PTT" (usually under Security or Advanced).')) }
        }
        @{
            Id = 'vbs'; Title = (T 'Безпека на основі віртуалізації (VBS)' 'Virtualization-based security (VBS)')
            Test = {
                switch ((Get-DeviceGuard).VirtualizationBasedSecurityStatus) {
                    2 { Ok (T 'працює' 'running') }
                    1 { Issue info (T 'увімкнено, але не працює' 'enabled but not running') (T 'VBS налаштовано, але воно не запустилося - часто через вимкнену віртуалізацію (SVM / VT-x) у BIOS.' 'VBS is configured but did not start - often because virtualization (SVM / VT-x) is off in BIOS.') }
                    default { Issue info (T 'вимкнено' 'off') (T 'VBS - основа для «Цілісності пам''яті» і Credential Guard; без нього вони не працюють.' 'VBS is the base for "Memory integrity" and Credential Guard; they do not work without it.') }
                }
            }
            Explain = (T 'VBS запускає найважливіші частини Windows в окремому ізольованому середовищі за допомогою віртуалізації процесора. На ньому працюють «Цілісність пам''яті» (HVCI) і Credential Guard.' 'VBS runs the most critical parts of Windows in a separate isolated environment using CPU virtualization. Memory integrity (HVCI) and Credential Guard run on it.')
            Pros = @((T 'Основа для захисту ядра і паролів' 'The foundation for kernel and credential protection'))
            Cons = @((T 'Потрібна увімкнена віртуалізація процесора в BIOS (SVM / VT-x)' 'Needs CPU virtualization enabled in BIOS (SVM / VT-x)'), (T 'Невелике навантаження на CPU' 'A small CPU overhead'))
            Fix = @{ Open = 'windowsdefender://coreisolation' }
        }
        @{
            Id = 'hvci'; Title = (T 'Цілісність пам''яті (Memory Integrity, HVCI)' 'Memory integrity (HVCI)')
            Test = {
                $dg = Get-DeviceGuard
                if (@($dg.SecurityServicesRunning) -contains 2) { return Ok (T 'увімкнено' 'on') }
                $cfg = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
                if ($cfg -eq 1) { return Issue medium (T 'увімкнено, але не працює' 'enabled but not running') (T 'Налаштування увімкнене, але захист не запустився: потрібне перезавантаження, або його блокує несумісний драйвер (список - у «Безпеці Windows» → «Ізоляція ядра»).' 'The setting is on but protection did not start: a restart is needed, or an incompatible driver blocks it (the list is in Windows Security → Core isolation).') }
                Issue medium (T 'вимкнено' 'off') (T 'Драйвер зі шкідливим кодом або відомою вразливістю може змінити ядро Windows.' 'A driver with malicious code or a known vulnerability can modify the Windows kernel.')
            }
            Explain = (T 'Цілісність пам''яті перевіряє кожен драйвер перед завантаженням в ізольованому середовищі (VBS) і не дає змінювати код ядра під час роботи. Це головний захист від атак через драйвери.' 'Memory integrity checks every driver in an isolated environment (VBS) before it loads and prevents kernel code from being modified at runtime. It is the main defense against driver-based attacks.')
            Pros = @(
                (T 'Шкідливий або вразливий драйвер не зможе впровадити код у ядро' 'A malicious or vulnerable driver cannot inject code into the kernel'),
                (T 'Вимога деяких анти-читів і корпоративних політик' 'Required by some anti-cheats and corporate policies')
            )
            Cons = @(
                (T 'У частині ігор −1…5% FPS (на нових процесорах менше)' '−1…5% FPS in some games (less on newer CPUs)'),
                (T 'Старі драйвери (утиліти розгону, RGB, деякі аудіо й VPN) можуть не завантажитися - Windows покаже список несумісних' 'Old drivers (overclocking utilities, RGB, some audio and VPN) may fail to load - Windows lists the incompatible ones'),
                (T 'Можливі конфлікти зі старими програмами віртуалізації та емуляторами' 'Possible conflicts with old virtualization software and emulators')
            )
            Fix = @{ Recipe = 'hvci'; Open = 'windowsdefender://coreisolation' }
        }
        @{
            Id = 'credential-guard'; Title = 'Credential Guard'
            Test = {
                if ((Get-OsInfo).IsHome) { return NotApplicable (T 'Доступно лише у Windows Pro, Enterprise і Education.' 'Available only in Windows Pro, Enterprise and Education.') }
                if (@((Get-DeviceGuard).SecurityServicesRunning) -contains 1) { return Ok (T 'увімкнено' 'on') }
                Issue info (T 'вимкнено' 'off') (T 'Корисно здебільшого в корпоративних мережах (домен); для домашнього ПК - необов''язково.' 'Useful mostly in corporate (domain) networks; optional for a home PC.')
            }
            Explain = (T 'Credential Guard ховає хеші паролів і квитки входу в ізольоване середовище VBS, щоб їх не можна було викрасти з пам''яті й використати для входу на інші комп''ютери мережі.' 'Credential Guard keeps password hashes and sign-in tickets in the isolated VBS environment so they cannot be stolen from memory and reused to sign in to other computers on the network.')
            Pros = @((T 'Захист від крадіжки облікових даних у корпоративній мережі' 'Protection from credential theft on a corporate network'))
            Cons = @((T 'Ламає деякі старі протоколи входу (NTLMv1, MS-CHAPv2 у VPN, Kerberos DES)' 'Breaks some old sign-in protocols (NTLMv1, MS-CHAPv2 in VPNs, Kerberos DES)'), (T 'Вдома майже не дає користі' 'Little benefit at home'))
            Fix = @{ Steps = @((T 'Налаштовується через групову політику: Конфігурація комп''ютера → Адміністративні шаблони → Система → Device Guard.' 'Configured via Group Policy: Computer Configuration → Administrative Templates → System → Device Guard.')) }
        }
        @{
            Id = 'lsa'; Title = (T 'Захист LSA (процес входу в систему)' 'LSA protection (sign-in process)')
            Test = {
                switch (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL') {
                    1 { Ok (T 'увімкнено (з блокуванням UEFI)' 'on (with UEFI lock)') }
                    2 { Ok (T 'увімкнено' 'on') }
                    default { Issue medium (T 'вимкнено' 'off') (T 'Програма з правами адміністратора може прочитати пам''ять LSA і витягти з неї паролі (як це робить Mimikatz).' 'A program with administrator rights can read LSA memory and extract passwords from it (as Mimikatz does).') }
                }
            }
            Explain = (T 'LSA - процес Windows, що перевіряє паролі й зберігає дані входу. У захищеному режимі в нього можуть заходити лише підписані Microsoft компоненти.' 'LSA is the Windows process that checks passwords and holds sign-in data. In protected mode only Microsoft-signed components can load into it.')
            Pros = @((T 'Ускладнює крадіжку паролів і токенів з пам''яті' 'Makes stealing passwords and tokens from memory harder'))
            Cons = @((T 'Старі плагіни входу, смарт-карт або менеджерів паролів, що вбудовуються в LSA, перестануть працювати (Windows запише це в журнал подій)' 'Old sign-in, smart card or password manager plug-ins that load into LSA stop working (Windows logs this)'))
            Fix = @{ Recipe = 'lsa-protection' }
        }
        @{
            Id = 'driver-blocklist'; Title = (T 'Блок-лист вразливих драйверів' 'Vulnerable driver blocklist')
            Test = {
                $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable'
                if ($v -eq 1) { return Ok (T 'увімкнено' 'on') }
                if ($v -eq 0) { return Issue medium (T 'вимкнено' 'off') (T 'Windows дозволяє завантажувати драйвери з відомими вразливостями, якими атакують ядро.' 'Windows allows loading drivers with known vulnerabilities that are used to attack the kernel.') }
                # Не налаштовано явно: з Windows 11 22H2 блок-лист типово увімкнений
                if ((Get-OsInfo).Build -ge 22621) { Ok (T 'увімкнено (типово)' 'on (default)') } else { Issue medium (T 'не налаштовано' 'not configured') (T 'У цій версії Windows блок-лист типово вимкнений.' 'In this Windows version the blocklist is off by default.') }
            }
            Explain = (T 'Microsoft веде список легітимних, але вразливих драйверів (старі утиліти розгону, моніторингу, анти-читів), через які шкідливі програми отримують доступ до ядра. Блок-лист забороняє їх завантажувати.' 'Microsoft keeps a list of legitimate but vulnerable drivers (old overclocking, monitoring and anti-cheat utilities) that malware uses to reach the kernel. The blocklist prevents them from loading.')
            Pros = @((T 'Закриває популярний спосіб атаки «принеси свій вразливий драйвер» (BYOVD)' 'Closes the popular "bring your own vulnerable driver" (BYOVD) attack'))
            Cons = @((T 'Зрідка блокує старий драйвер легітимної програми - її потрібно оновити' 'Occasionally blocks an old driver of a legitimate program - it needs updating'))
            Fix = @{ Recipe = 'driver-blocklist' }
        }
        @{
            Id = 'bitlocker'; Title = (T 'Шифрування системного диска' 'System disk encryption')
            Test = {
                $drive = "$env:SystemDrive\"
                $state = (New-Object -ComObject Shell.Application).NameSpace($drive).Self.ExtendedProperty('System.Volume.BitLockerProtection')
                $portable = Test-Portable
                switch ($state) {
                    { $_ -in 1, 3, 6 } { return Ok $(if ($_ -eq 3) { T 'шифрується…' 'encrypting…' } else { T 'увімкнено' 'on' }) }
                    5 { return Issue medium (T 'призупинено' 'suspended') (T 'Шифрування призупинене: ключ зберігається на диску відкрито, тож диск фактично не захищений. Зазвичай Windows відновлює захист після перезавантаження.' 'Encryption is suspended: the key is stored on the disk in the clear, so the disk is effectively unprotected. Windows usually resumes protection after a restart.') }
                    4 { return Issue low (T 'розшифровується' 'decrypting') (T 'Диск зараз розшифровується.' 'The disk is being decrypted.') }
                    2 {
                        $why = T 'Якщо диск або ПК вкрадуть чи здадуть у ремонт, усі файли можна прочитати, під''єднавши диск до іншого комп''ютера.' 'If the disk or PC is stolen or sent for repair, every file can be read by connecting the disk to another computer.'
                        return Issue $(if ($portable) { 'medium' } else { 'low' }) (T 'вимкнено' 'off') $why
                    }
                    default { return Unknown (T 'Windows не повідомила стан шифрування.' 'Windows did not report the encryption state.') }
                }
            }
            Explain = (T 'BitLocker (у Windows Home - «Шифрування пристрою») шифрує диск. Без ключа, який зберігається в TPM, дані на диску - випадковий набір байтів. Особливо важливо для ноутбуків.' 'BitLocker ("Device encryption" in Windows Home) encrypts the disk. Without the key stored in the TPM, the data is random bytes. Especially important for laptops.')
            Pros = @((T 'Вкрадений ноутбук або диск, зданий у ремонт, не розкриє ваших файлів' 'A stolen laptop or a disk sent for repair will not reveal your files'), (T 'Працює непомітно: ключ видає TPM під час старту' 'Works invisibly: the TPM releases the key at startup'))
            Cons = @(
                (T 'ОБОВ''ЯЗКОВО збережіть ключ відновлення (в обліковому записі Microsoft або роздрукуйте): після оновлення BIOS чи скидання TPM без нього дані втрачено назавжди' 'You MUST save the recovery key (in your Microsoft account or on paper): after a BIOS update or TPM reset, the data is lost forever without it'),
                (T 'Невелике сповільнення SSD на важкому записі (зазвичай 1-10%)' 'A small SSD slowdown on heavy writes (usually 1-10%)'),
                (T 'Для настільного ПК, що стоїть удома, користь менша, ніж для ноутбука' 'Less benefit for a desktop PC at home than for a laptop')
            )
            Fix = @{ Open = $(if ((Get-OsInfo).IsHome) { 'ms-settings:deviceencryption' } else { 'control.exe /name Microsoft.BitLockerDriveEncryption' }) }
        }
        @{
            Id = 'bios-age'; Title = (T 'Вік BIOS/UEFI' 'BIOS/UEFI age')
            Test = {
                $b = Get-CimInstance Win32_BIOS
                $board = Get-CimInstance Win32_BaseBoard
                $ev = @(((T 'Плата: ' 'Board: ') + "$($board.Manufacturer) $($board.Product)"), "BIOS: $($b.Manufacturer) $($b.SMBIOSBIOSVersion)")
                if (-not $b.ReleaseDate) { return Unknown (T 'Дата BIOS невідома.' 'The BIOS date is unknown.') }
                $date = $b.ReleaseDate.ToString('dd.MM.yyyy')
                $years = ((Get-Date) - $b.ReleaseDate).TotalDays / 365.25
                $value = (T 'від ' 'dated ') + $date
                if ($years -gt 5) { return Issue medium $value (T 'BIOS старший за 5 років: у ньому, найімовірніше, є виправлені пізніше вразливості процесора та прошивки.' 'The BIOS is older than 5 years: it most likely has CPU and firmware vulnerabilities fixed in later versions.') $ev }
                if ($years -gt 3) { return Issue low $value (T 'Варто перевірити на сайті виробника плати, чи немає новішої версії: оновлення BIOS закривають вразливості і покращують стабільність.' 'Check the board vendor site for a newer version: BIOS updates close vulnerabilities and improve stability.') $ev }
                Ok $value '' $ev
            }
            Explain = (T 'BIOS (UEFI) - прошивка материнської плати. Виробники оновлюють її, щоб закрити вразливості процесора (на кшталт Spectre, Zenbleed, SinkClose) і виправити проблеми стабільності та сумісності з пам''яттю.' 'The BIOS (UEFI) is the motherboard firmware. Vendors update it to close CPU vulnerabilities (like Spectre, Zenbleed, SinkClose) and fix stability and memory compatibility problems.')
            Pros = @((T 'Закриває вразливості прошивки і процесора' 'Closes firmware and CPU vulnerabilities'), (T 'Часто покращує стабільність і сумісність з оперативною пам''яттю' 'Often improves stability and RAM compatibility'))
            Cons = @(
                (T 'Вимкнення живлення під час оновлення може «вбити» плату - оновлюйте з ДБЖ або хоча б не під час грози' 'A power loss during the update can brick the board - update with a UPS, or at least not during a storm'),
                (T 'Налаштування BIOS (XMP/EXPO, вентилятори) скидаються; скидання fTPM вимагатиме ключа BitLocker' 'BIOS settings (XMP/EXPO, fans) reset; an fTPM reset will require the BitLocker key')
            )
            Fix = @{ Steps = @((T 'Знайдіть свою плату на сайті виробника (модель - у «Доказах»), завантажте новішу версію BIOS і встановіть її вбудованою утилітою (MSI M-Flash, ASUS EZ Flash, Gigabyte Q-Flash).' 'Find your board on the vendor site (the model is in "Evidence"), download a newer BIOS and install it with the built-in tool (MSI M-Flash, ASUS EZ Flash, Gigabyte Q-Flash).')) }
        }
    )
}
