# Захист платформи: залізо, прошивка і ядро Windows. Усе читається без прав адміністратора.

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
    Id = 'platform'; Title = 'Захист платформи'; Order = 1
    Checks = @(
        @{
            Id = 'uefi'; Title = 'Режим завантаження UEFI'
            Test = {
                switch (Get-FirmwareType) {
                    2 { Ok 'UEFI' }
                    1 { Issue medium 'Legacy BIOS' 'Windows завантажується у старому режимі BIOS (CSM). У ньому не працюють Secure Boot і частина захисту ядра.' }
                    default { Unknown 'Windows не повідомила режим завантаження.' }
                }
            }
            Explain = 'UEFI - сучасний спосіб завантаження ПК, на ньому тримаються Secure Boot, BitLocker з TPM і захист ядра. Legacy BIOS (CSM) - режим сумісності зі старими системами.'
            Pros = @('Можна увімкнути Secure Boot і повний захист ядра', 'Швидший старт, диски понад 2 ТБ')
            Cons = @('Перехід із Legacy потребує конвертації системного диска з MBR у GPT (mbr2gpt) - без резервної копії це ризиковано')
            Fix = @{ Steps = @(
                'Зробіть резервну копію важливих файлів.',
                'Перевірте диск: у командному рядку від адміністратора виконайте mbr2gpt /validate /allowFullOS.',
                'Якщо перевірка успішна - mbr2gpt /convert /allowFullOS, потім у BIOS вимкніть CSM і ввімкніть UEFI-завантаження.'
            ) }
        }
        @{
            Id = 'secure-boot'; Title = 'Secure Boot'
            Test = {
                if ((Get-FirmwareType) -ne 2) { return NotApplicable 'Secure Boot працює лише в режимі UEFI.' }
                switch (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled') {
                    1 { Ok 'увімкнено' }
                    0 { Issue high 'вимкнено' 'Під час старту ПК прошивка не перевіряє, чи завантажувач Windows справжній.' }
                    default { Unknown 'Не вдалося прочитати стан Secure Boot.' }
                }
            }
            Explain = 'Secure Boot дозволяє прошивці запускати лише підписані завантажувачі. Так буткіт - вірус, що стартує раніше за Windows і антивірус, - не зможе підмінити завантаження.'
            Pros = @(
                'Захист від буткітів і руткітів, які антивірус не бачить',
                'Вимога Windows 11 і анти-читів у багатьох онлайн-іграх (Battlefield 6, Valorant, Call of Duty та інші)'
            )
            Cons = @(
                'Старі завантажувачі Linux без підпису і дуже старі відеокарти без UEFI-прошивки можуть не запуститися',
                'Вмикається в BIOS; якщо Windows стоїть у режимі Legacy/MBR, спершу потрібна конвертація диска'
            )
            Fix = @{ Recipe = 'secure-boot' }
        }
        @{
            Id = 'tpm'; Title = 'Модуль TPM'
            Test = {
                $out = tpmtool getdeviceinformation 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $out) { return Unknown 'tpmtool не відповів.' }
                $info = @{}
                foreach ($l in $out) { if ($l -match '^\s*-(.+?):\s*(.*)$') { $info[$Matches[1].Trim()] = $Matches[2].Trim() } }
                if ($info['TPM Present'] -ne 'True') { return Issue medium 'не знайдено' 'TPM немає або його вимкнено в BIOS (fTPM у AMD, PTT в Intel).' }
                $ver = $info['TPM Version']; $maker = $info['TPM Manufacturer Full Name']
                if ($ver -notlike '2.*') { return Issue low "TPM $ver" 'Застаріла версія TPM: Windows 11 і сучасне шифрування потребують TPM 2.0.' }
                Ok "TPM $ver$(if ($maker) { " ($maker)" })"
            }
            Explain = 'TPM - захищений чип (або його програмна версія в процесорі), який зберігає ключі шифрування і перевіряє, що систему не підмінили.'
            Pros = @('Потрібен для BitLocker без пароля при старті, Windows Hello і Windows 11', 'Ключі неможливо скопіювати з диска')
            Cons = @('fTPM вмикається в BIOS; скидання fTPM (наприклад, під час оновлення BIOS) потребує ключа відновлення BitLocker')
            Fix = @{ Steps = @('У BIOS увімкніть TPM: на AMD - «AMD fTPM», на Intel - «Intel PTT» (зазвичай у розділі Security або Advanced).') }
        }
        @{
            Id = 'vbs'; Title = 'Безпека на основі віртуалізації (VBS)'
            Test = {
                switch ((Get-DeviceGuard).VirtualizationBasedSecurityStatus) {
                    2 { Ok 'працює' }
                    1 { Issue info 'увімкнено, але не працює' 'VBS налаштовано, але воно не запустилося - часто через вимкнену віртуалізацію (SVM / VT-x) у BIOS.' }
                    default { Issue info 'вимкнено' 'VBS - основа для «Цілісності пам''яті» і Credential Guard; без нього вони не працюють.' }
                }
            }
            Explain = 'VBS запускає найважливіші частини Windows в окремому ізольованому середовищі за допомогою віртуалізації процесора. На ньому працюють «Цілісність пам''яті» (HVCI) і Credential Guard.'
            Pros = @('Основа для захисту ядра і паролів')
            Cons = @('Потрібна увімкнена віртуалізація процесора в BIOS (SVM / VT-x)', 'Невелике навантаження на CPU')
            Fix = @{ Open = 'windowsdefender://coreisolation' }
        }
        @{
            Id = 'hvci'; Title = 'Цілісність пам''яті (Memory Integrity, HVCI)'
            Test = {
                $dg = Get-DeviceGuard
                if (@($dg.SecurityServicesRunning) -contains 2) { return Ok 'увімкнено' }
                $cfg = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
                if ($cfg -eq 1) { return Issue medium 'увімкнено, але не працює' 'Налаштування увімкнене, але захист не запустився: потрібне перезавантаження, або його блокує несумісний драйвер (список - у «Безпеці Windows» → «Ізоляція ядра»).' }
                Issue medium 'вимкнено' 'Драйвер зі шкідливим кодом або відомою вразливістю може змінити ядро Windows.'
            }
            Explain = 'Цілісність пам''яті перевіряє кожен драйвер перед завантаженням в ізольованому середовищі (VBS) і не дає змінювати код ядра під час роботи. Це головний захист від атак через драйвери.'
            Pros = @(
                'Шкідливий або вразливий драйвер не зможе впровадити код у ядро',
                'Вимога деяких анти-читів і корпоративних політик'
            )
            Cons = @(
                'У частині ігор −1…5% FPS (на нових процесорах менше)',
                'Старі драйвери (утиліти розгону, RGB, деякі аудіо й VPN) можуть не завантажитися - Windows покаже список несумісних',
                'Можливі конфлікти зі старими програмами віртуалізації та емуляторами'
            )
            Fix = @{ Recipe = 'hvci'; Open = 'windowsdefender://coreisolation' }
        }
        @{
            Id = 'credential-guard'; Title = 'Credential Guard'
            Test = {
                if ((Get-OsInfo).IsHome) { return NotApplicable 'Доступно лише у Windows Pro, Enterprise і Education.' }
                if (@((Get-DeviceGuard).SecurityServicesRunning) -contains 1) { return Ok 'увімкнено' }
                Issue info 'вимкнено' 'Корисно здебільшого в корпоративних мережах (домен); для домашнього ПК - необов''язково.'
            }
            Explain = 'Credential Guard ховає хеші паролів і квитки входу в ізольоване середовище VBS, щоб їх не можна було викрасти з пам''яті й використати для входу на інші комп''ютери мережі.'
            Pros = @('Захист від крадіжки облікових даних у корпоративній мережі')
            Cons = @('Ламає деякі старі протоколи входу (NTLMv1, MS-CHAPv2 у VPN, Kerberos DES)', 'Вдома майже не дає користі')
            Fix = @{ Steps = @('Налаштовується через групову політику: Конфігурація комп''ютера → Адміністративні шаблони → Система → Device Guard.') }
        }
        @{
            Id = 'lsa'; Title = 'Захист LSA (процес входу в систему)'
            Test = {
                switch (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL') {
                    1 { Ok 'увімкнено (з блокуванням UEFI)' }
                    2 { Ok 'увімкнено' }
                    default { Issue medium 'вимкнено' 'Програма з правами адміністратора може прочитати пам''ять LSA і витягти з неї паролі (як це робить Mimikatz).' }
                }
            }
            Explain = 'LSA - процес Windows, що перевіряє паролі й зберігає дані входу. У захищеному режимі в нього можуть заходити лише підписані Microsoft компоненти.'
            Pros = @('Ускладнює крадіжку паролів і токенів з пам''яті')
            Cons = @('Старі плагіни входу, смарт-карт або менеджерів паролів, що вбудовуються в LSA, перестануть працювати (Windows запише це в журнал подій)')
            Fix = @{ Recipe = 'lsa-protection' }
        }
        @{
            Id = 'driver-blocklist'; Title = 'Блок-лист вразливих драйверів'
            Test = {
                $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable'
                if ($v -eq 1) { return Ok 'увімкнено' }
                if ($v -eq 0) { return Issue medium 'вимкнено' 'Windows дозволяє завантажувати драйвери з відомими вразливостями, якими атакують ядро.' }
                # Не налаштовано явно: з Windows 11 22H2 блок-лист типово увімкнений
                if ((Get-OsInfo).Build -ge 22621) { Ok 'увімкнено (типово)' } else { Issue medium 'не налаштовано' 'У цій версії Windows блок-лист типово вимкнений.' }
            }
            Explain = 'Microsoft веде список легітимних, але вразливих драйверів (старі утиліти розгону, моніторингу, анти-читів), через які шкідливі програми отримують доступ до ядра. Блок-лист забороняє їх завантажувати.'
            Pros = @('Закриває популярний спосіб атаки «принеси свій вразливий драйвер» (BYOVD)')
            Cons = @('Зрідка блокує старий драйвер легітимної програми - її потрібно оновити')
            Fix = @{ Recipe = 'driver-blocklist' }
        }
        @{
            Id = 'bitlocker'; Title = 'Шифрування системного диска'
            Test = {
                $drive = "$env:SystemDrive\"
                $state = (New-Object -ComObject Shell.Application).NameSpace($drive).Self.ExtendedProperty('System.Volume.BitLockerProtection')
                $portable = Test-Portable
                switch ($state) {
                    { $_ -in 1, 3, 6 } { return Ok $(if ($_ -eq 3) { 'шифрується…' } else { 'увімкнено' }) }
                    5 { return Issue medium 'призупинено' 'Шифрування призупинене: ключ зберігається на диску відкрито, тож диск фактично не захищений. Зазвичай Windows відновлює захист після перезавантаження.' }
                    4 { return Issue low 'розшифровується' 'Диск зараз розшифровується.' }
                    2 {
                        $why = 'Якщо диск або ПК вкрадуть чи здадуть у ремонт, усі файли можна прочитати, під''єднавши диск до іншого комп''ютера.'
                        return Issue $(if ($portable) { 'medium' } else { 'low' }) 'вимкнено' $why
                    }
                    default { return Unknown 'Windows не повідомила стан шифрування.' }
                }
            }
            Explain = 'BitLocker (у Windows Home - «Шифрування пристрою») шифрує диск. Без ключа, який зберігається в TPM, дані на диску - випадковий набір байтів. Особливо важливо для ноутбуків.'
            Pros = @('Вкрадений ноутбук або диск, зданий у ремонт, не розкриє ваших файлів', 'Працює непомітно: ключ видає TPM під час старту')
            Cons = @(
                'ОБОВ''ЯЗКОВО збережіть ключ відновлення (в обліковому записі Microsoft або роздрукуйте): після оновлення BIOS чи скидання TPM без нього дані втрачено назавжди',
                'Невелике сповільнення SSD на важкому записі (зазвичай 1-10%)',
                'Для настільного ПК, що стоїть удома, користь менша, ніж для ноутбука'
            )
            Fix = @{ Open = $(if ((Get-OsInfo).IsHome) { 'ms-settings:deviceencryption' } else { 'control.exe /name Microsoft.BitLockerDriveEncryption' }) }
        }
        @{
            Id = 'bios-age'; Title = 'Вік BIOS/UEFI'
            Test = {
                $b = Get-CimInstance Win32_BIOS
                $board = Get-CimInstance Win32_BaseBoard
                $ev = @("Плата: $($board.Manufacturer) $($board.Product)", "BIOS: $($b.Manufacturer) $($b.SMBIOSBIOSVersion)")
                if (-not $b.ReleaseDate) { return Unknown 'Дата BIOS невідома.' }
                $date = $b.ReleaseDate.ToString('dd.MM.yyyy')
                $years = ((Get-Date) - $b.ReleaseDate).TotalDays / 365.25
                if ($years -gt 5) { return Issue medium "від $date" ('BIOS старший за 5 років: у ньому, найімовірніше, є виправлені пізніше вразливості процесора та прошивки.') $ev }
                if ($years -gt 3) { return Issue low "від $date" 'Варто перевірити на сайті виробника плати, чи немає новішої версії: оновлення BIOS закривають вразливості і покращують стабільність.' $ev }
                Ok "від $date" '' $ev
            }
            Explain = 'BIOS (UEFI) - прошивка материнської плати. Виробники оновлюють її, щоб закрити вразливості процесора (на кшталт Spectre, Zenbleed, SinkClose) і виправити проблеми стабільності та сумісності з пам''яттю.'
            Pros = @('Закриває вразливості прошивки і процесора', 'Часто покращує стабільність і сумісність з оперативною пам''яттю')
            Cons = @(
                'Вимкнення живлення під час оновлення може «вбити» плату - оновлюйте з ДБЖ або хоча б не під час грози',
                'Налаштування BIOS (XMP/EXPO, вентилятори) скидаються; скидання fTPM вимагатиме ключа BitLocker'
            )
            Fix = @{ Steps = @('Знайдіть свою плату на сайті виробника (модель - у «Доказах»), завантажте новішу версію BIOS і встановіть її вбудованою утилітою (MSI M-Flash, ASUS EZ Flash, Gigabyte Q-Flash).') }
        }
    )
}
