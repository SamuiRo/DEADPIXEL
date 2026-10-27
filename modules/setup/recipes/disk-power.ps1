# Вимикає енергозбереження дисків і USB від мережі: диски не "засинають" і не ловлять зависання
# на виході з low-power станів (такі зависання ловить детектор на вкладці "Диски").
@{
    Title       = (T 'Диски без енергозбереження (від мережі)' 'Disks without power saving (on AC)')
    Description = (T 'AHCI HIPM/DIPM, вимкнення дисків і USB selective suspend у поточній схемі живлення.' 'AHCI HIPM/DIPM, disk spin-down and USB selective suspend in the current power plan.')
    Items       = @(
        @{ Kind = 'Power'; Id = 'ahci-lpm-ac'; Title = 'AHCI Link Power Management'
           Sub = 'SUB_DISK'; Setting = '0b2d69d7-a2a1-449c-9680-f91c70521c60'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = 'Active'; 1 = 'HIPM'; 2 = 'HIPM+DIPM'; 3 = 'DIPM'; 4 = 'Lowest' }
           Hint = (T 'Енергозбереження лінії SATA. У станах HIPM/DIPM диск відповідає з затримкою, а деякі SSD і контролери зависають на кілька секунд — у журналі це події disk 129/153. Active = лінія завжди активна.' 'SATA link power saving. In HIPM/DIPM states the disk responds with a delay, and some SSDs and controllers freeze for seconds — logged as disk 129/153 events. Active = the link is always on.') }
        @{ Kind = 'Power'; Id = 'disk-idle-ac'; Title = (T 'Вимикати диск через, с (0 = ніколи)' 'Turn off disk after, s (0 = never)')
           Sub = 'SUB_DISK'; Setting = 'DISKIDLE'; Power = 'AC'; Desired = 0
           Hint = (T 'Через скільки секунд простою Windows зупиняє диск. HDD потім розкручується 5–10 с, і програми в цей час "висять". 0 = ніколи не зупиняти.' 'After how many idle seconds Windows spins the disk down. An HDD then takes 5–10 s to spin up, and programs "hang" meanwhile. 0 = never.') }
        @{ Kind = 'Power'; Id = 'usb-suspend-ac'; Title = 'USB selective suspend'
           Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Windows присипляє USB-пристрої, які вважає неактивними. Зовнішні диски (UASP) і хаби від цього інколи відвалюються або зависають. Вимкнення — стандартний крок при "зникненні" USB-дисків.' 'Windows suspends USB devices it considers idle. External disks (UASP) and hubs sometimes drop off or hang because of it. Turning it off is the standard step when USB disks "disappear".') }
    )
    Steps       = @(
        @{ Text = (T 'Диспетчер пристроїв → Контролери USB → кожен "USB Root Hub" / "Generic USB Hub" → Властивості → Керування живленням → зняти "Дозволити вимикати цей пристрій для економії енергії".' 'Device Manager → Universal Serial Bus controllers → each "USB Root Hub" / "Generic USB Hub" → Properties → Power Management → untick "Allow the computer to turn off this device to save power".'); Open = 'devmgmt.msc' }
        (T 'Для NVMe: оновіть прошивку SSD утилітою виробника (Samsung Magician, WD Dashboard, Crucial Storage Executive тощо).' 'For NVMe: update the SSD firmware with the vendor tool (Samsung Magician, WD Dashboard, Crucial Storage Executive, etc.).')
    )

    Tabs        = @(
        @{ Id = 'disk-check'; Title = (T 'Перевірка дисків' 'Disk check')
           Description = (T 'Чи є скидання контролера і повтори операцій, що каже SMART, і онлайн-перевірка файлової системи. Нічого не змінює.' 'Controller resets and retried operations, what SMART says, and an online file system check. Changes nothing.')
           Steps = @(
               @{ Text = (T 'Скидання дисків контролером (storahci/stornvme 129) і повтори операцій (disk 153) за 14 днів, по днях.' 'Disk resets by the controller (storahci/stornvme 129) and retried operations (disk 153) over 14 days, per day.')
                  Hint = (T '129 + 153 = диск не відповів вчасно і Windows скинула з''єднання: у цей момент відео/гра "висять" до хвилини, а Диспетчер завдань показує нуль активності. Найчастіша причина - енергозбереження SATA і зупинка HDD (пункти вище).' '129 + 153 = the disk did not respond in time and Windows reset the link: video or a game "hangs" for up to a minute while Task Manager shows zero activity. The most common cause is SATA power saving and HDD spin-down (items above).')
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'storahci', 'stornvme', 'disk'; Id = 129, 153; StartTime = (Get-Date).AddDays(-14) } -ErrorAction SilentlyContinue | Group-Object { '{0:yyyy-MM-dd} {1} {2}' -f `$_.TimeCreated, `$_.ProviderName, `$_.Id } | Sort-Object Name | Format-Table Count, Name -AutoSize" }
               @{ Text = (T 'Апаратні помилки (disk 7/154/51) і втрати запису (Ntfs 50/140) за 30 днів.' 'Hardware errors (disk 7/154/51) and lost writes (Ntfs 50/140) over 30 days.')
                  Hint = (T 'Ntfs 50/140 "Delayed Write Failed" - Windows не змогла дописати файл: дані на цьому томі могли пошкодитися. Перевірте файли і зробіть копію.' 'Ntfs 50/140 "Delayed Write Failed" — Windows could not finish writing a file: data on that volume may be damaged. Check your files and make a backup.')
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs'; Id = 7, 154, 51, 50, 140; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | Select-Object -First 30 | ForEach-Object { '{0:yyyy-MM-dd HH:mm} {1} {2}: {3}' -f `$_.TimeCreated, `$_.ProviderName, `$_.Id, ((`$_.Properties | ForEach-Object { `$_.Value } | Where-Object { `$_ -is [string] -and `$_ }) -join ' | ') }" }
               @{ Text = (T 'SMART і лічильники надійності.' 'SMART and reliability counters.'); Admin = $true
                  Hint = (T 'Reallocated/Pending/Uncorrectable > 0 - диск деградує. UDMA CRC > 0 - кабель SATA. LoadUnload (паркування головок) ~300 000 - розрахунковий ресурс настільних HDD (Windows показує його 16-бітним, тож велике число може "переповнитися"; точне значення - у DEADPIXEL → Диски).' 'Reallocated/Pending/Uncorrectable > 0 — the disk is degrading. UDMA CRC > 0 — the SATA cable. LoadUnload (head parking) ~300,000 is the rated life of desktop HDDs (Windows shows it as 16-bit, so large numbers can "wrap"; the exact value is in DEADPIXEL → Disks).')
                  Run = 'Get-PhysicalDisk | ForEach-Object { $c = $_ | Get-StorageReliabilityCounter; [pscustomobject]@{ Disk = $_.DeviceId; Model = $_.FriendlyName; Media = $_.MediaType; Health = $_.HealthStatus; TempC = $c.Temperature; Hours = $c.PowerOnHours; StartStop = $c.StartStopCycleCount; LoadUnload = $c.LoadUnloadCycleCount; ReadErrUncorr = $c.ReadErrorsUncorrected; WearPct = $c.Wear } } | Format-Table -AutoSize' }
               @{ Text = (T 'Як підключені диски: модель, шина (SATA/NVMe/USB) і літери.' 'How the disks are connected: model, bus (SATA/NVMe/USB) and letters.')
                  Run = 'Get-PhysicalDisk | Sort-Object DeviceId | Format-Table DeviceId, FriendlyName, BusType, MediaType, HealthStatus -AutoSize; Get-Partition | Where-Object DriveLetter | Format-Table DiskNumber, DriveLetter, @{ n = "GB"; e = { [math]::Round($_.Size / 1GB) } } -AutoSize' }
           ) }
        @{ Id = 'fs-scan'; Title = (T 'Перевірка файлової системи' 'File system check')
           Description = (T 'chkdsk /scan - онлайн-перевірка тому без відключення диска і без виправлень. Якщо знайде проблеми, підкаже, що робити далі.' 'chkdsk /scan — an online volume check without taking the disk offline and without fixing anything. If it finds problems, it tells you what to do next.')
           Params = @(
               @{ Name = 'DRIVE'; Title = (T 'Літера диска' 'Drive letter'); Default = 'D:'; Pattern = '[A-Za-z]:'; Hint = (T 'Наприклад, F: або S:. Для зовнішнього диска після помилок запису - обов''язково.' 'For example, F: or S:. A must for an external disk after write errors.') }
           )
           Steps = @(
               @{ Text = (T 'Онлайн-перевірка {DRIVE} (лише читання).' 'Online check of {DRIVE} (read-only).'); Admin = $true
                  Run = 'chkdsk {DRIVE} /scan'; Expect = '(?i)no problems|не виявлено|found no problems' }
               @{ Text = (T 'Знайдено проблеми - виправте їх (диск буде тимчасово недоступний; для C: - під час перезавантаження).' 'Problems found — fix them (the disk is temporarily unavailable; for C: — during a restart).'); If = 'fail'; Admin = $true
                  Confirm = (T 'Закрийте програми, що використовують цей диск. Продовжити виправлення?' 'Close programs that use this disk. Continue with the repair?')
                  Run = 'chkdsk {DRIVE} /spotfix' }
           ) }
        @{ Id = 'usb-disk'; Title = (T 'Зовнішній USB-диск зависає' 'External USB disk hangs')
           Description = (T 'USB-кишеня/док: зависання по кілька хвилин, помилки читання, "Delayed Write Failed".' 'USB enclosure/dock: multi-minute hangs, read errors, "Delayed Write Failed".')
           Steps = @(
               (T 'Не записуйте на нього важливе без копії, доки причину не знайдено.' 'Do not write anything important to it without a copy until the cause is found.')
               (T 'Підключіть до USB-порту на задній панелі (прямо в материнську плату), без хабів і подовжувачів. Спробуйте інший кабель.' 'Connect it to a rear USB port (directly on the motherboard), without hubs or extension cables. Try another cable.')
               @{ Text = (T 'Застосуйте пункт "USB selective suspend" на вкладці Рекомендовані.' 'Apply the "USB selective suspend" item on the Recommended tab.') }
               @{ Text = (T 'Перевірте SMART через CrystalDiskInfo (вона бачить диски в більшості USB-кишень).' 'Check SMART with CrystalDiskInfo (it sees disks in most USB enclosures).'); Open = 'https://crystalmark.info/en/software/crystaldiskinfo/' }
               (T 'Якщо кишеня розбирається - підключіть диск напряму по SATA: так видно, винен диск чи контролер кишені.' 'If the enclosure opens, connect the disk directly via SATA: that shows whether the disk or the enclosure controller is at fault.')
           ) }
    )
}
