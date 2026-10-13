# Вимикає енергозбереження дисків і USB від мережі: диски не "засинають" і не ловлять зависання
# на виході з low-power станів (такі зависання ловить детектор на вкладці "Диски").
@{
    Title       = 'Диски без енергозбереження (від мережі)'
    Description = 'AHCI HIPM/DIPM, вимкнення дисків і USB selective suspend у поточній схемі живлення.'
    Items       = @(
        @{ Kind = 'Power'; Id = 'ahci-lpm-ac'; Title = 'AHCI Link Power Management'
           Sub = 'SUB_DISK'; Setting = '0b2d69d7-a2a1-449c-9680-f91c70521c60'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = 'Active'; 1 = 'HIPM'; 2 = 'HIPM+DIPM'; 3 = 'DIPM'; 4 = 'Lowest' }
           Hint = 'Енергозбереження лінії SATA. У станах HIPM/DIPM диск відповідає з затримкою, а деякі SSD і контролери зависають на кілька секунд — у журналі це події disk 129/153. Active = лінія завжди активна.' }
        @{ Kind = 'Power'; Id = 'disk-idle-ac'; Title = 'Вимикати диск через, с (0 = ніколи)'
           Sub = 'SUB_DISK'; Setting = 'DISKIDLE'; Power = 'AC'; Desired = 0
           Hint = 'Через скільки секунд простою Windows зупиняє диск. HDD потім розкручується 5–10 с, і програми в цей час "висять". 0 = ніколи не зупиняти.' }
        @{ Kind = 'Power'; Id = 'usb-suspend-ac'; Title = 'USB selective suspend'
           Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = 'вимкнено'; 1 = 'увімкнено' }
           Hint = 'Windows присипляє USB-пристрої, які вважає неактивними. Зовнішні диски (UASP) і хаби від цього інколи відвалюються або зависають. Вимкнення — стандартний крок при "зникненні" USB-дисків.' }
    )
    Steps       = @(
        @{ Text = 'Диспетчер пристроїв → Контролери USB → кожен "USB Root Hub" / "Generic USB Hub" → Властивості → Керування живленням → зняти "Дозволити вимикати цей пристрій для економії енергії".'; Open = 'devmgmt.msc' }
        'Для NVMe: оновіть прошивку SSD утилітою виробника (Samsung Magician, WD Dashboard, Crucial Storage Executive тощо).'
    )

    Tabs        = @(
        @{ Id = 'disk-check'; Title = 'Перевірка дисків'
           Description = 'Чи є скидання контролера і повтори операцій, що каже SMART, і онлайн-перевірка файлової системи. Нічого не змінює.'
           Steps = @(
               @{ Text = 'Скидання дисків контролером (storahci/stornvme 129) і повтори операцій (disk 153) за 14 днів, по днях.'
                  Hint = '129 + 153 = диск не відповів вчасно і Windows скинула з''єднання: у цей момент відео/гра "висять" до хвилини, а Диспетчер завдань показує нуль активності. Найчастіша причина - енергозбереження SATA і зупинка HDD (пункти вище).'
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'storahci', 'stornvme', 'disk'; Id = 129, 153; StartTime = (Get-Date).AddDays(-14) } -ErrorAction SilentlyContinue | Group-Object { '{0:yyyy-MM-dd} {1} {2}' -f `$_.TimeCreated, `$_.ProviderName, `$_.Id } | Sort-Object Name | Format-Table Count, Name -AutoSize" }
               @{ Text = 'Апаратні помилки (disk 7/154/51) і втрати запису (Ntfs 50/140) за 30 днів.'
                  Hint = 'Ntfs 50/140 "Delayed Write Failed" - Windows не змогла дописати файл: дані на цьому томі могли пошкодитися. Перевірте файли і зробіть копію.'
                  Run = "Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs'; Id = 7, 154, 51, 50, 140; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | Select-Object -First 30 | ForEach-Object { '{0:yyyy-MM-dd HH:mm} {1} {2}: {3}' -f `$_.TimeCreated, `$_.ProviderName, `$_.Id, ((`$_.Properties | ForEach-Object { `$_.Value } | Where-Object { `$_ -is [string] -and `$_ }) -join ' | ') }" }
               @{ Text = 'SMART і лічильники надійності.'; Admin = $true
                  Hint = 'Reallocated/Pending/Uncorrectable > 0 - диск деградує. UDMA CRC > 0 - кабель SATA. LoadUnload (паркування головок) ~300 000 - розрахунковий ресурс настільних HDD (Windows показує його 16-бітним, тож велике число може "переповнитися"; точне значення - у DEADPIXEL → Диски).'
                  Run = 'Get-PhysicalDisk | ForEach-Object { $c = $_ | Get-StorageReliabilityCounter; [pscustomobject]@{ Disk = $_.DeviceId; Model = $_.FriendlyName; Media = $_.MediaType; Health = $_.HealthStatus; TempC = $c.Temperature; Hours = $c.PowerOnHours; StartStop = $c.StartStopCycleCount; LoadUnload = $c.LoadUnloadCycleCount; ReadErrUncorr = $c.ReadErrorsUncorrected; WearPct = $c.Wear } } | Format-Table -AutoSize' }
               @{ Text = 'Як підключені диски: модель, шина (SATA/NVMe/USB) і літери.'
                  Run = 'Get-PhysicalDisk | Sort-Object DeviceId | Format-Table DeviceId, FriendlyName, BusType, MediaType, HealthStatus -AutoSize; Get-Partition | Where-Object DriveLetter | Format-Table DiskNumber, DriveLetter, @{ n = "GB"; e = { [math]::Round($_.Size / 1GB) } } -AutoSize' }
           ) }
        @{ Id = 'fs-scan'; Title = 'Перевірка файлової системи'
           Description = 'chkdsk /scan - онлайн-перевірка тому без відключення диска і без виправлень. Якщо знайде проблеми, підкаже, що робити далі.'
           Params = @(
               @{ Name = 'DRIVE'; Title = 'Літера диска'; Default = 'D:'; Pattern = '[A-Za-z]:'; Hint = 'Наприклад, F: або S:. Для зовнішнього диска після помилок запису - обов''язково.' }
           )
           Steps = @(
               @{ Text = 'Онлайн-перевірка {DRIVE} (лише читання).'; Admin = $true
                  Run = 'chkdsk {DRIVE} /scan'; Expect = '(?i)no problems|не виявлено|found no problems' }
               @{ Text = 'Знайдено проблеми - виправте їх (диск буде тимчасово недоступний; для C: - під час перезавантаження).'; If = 'fail'; Admin = $true
                  Confirm = 'Закрийте програми, що використовують цей диск. Продовжити виправлення?'
                  Run = 'chkdsk {DRIVE} /spotfix' }
           ) }
        @{ Id = 'usb-disk'; Title = 'Зовнішній USB-диск зависає'
           Description = 'USB-кишеня/док: зависання по кілька хвилин, помилки читання, "Delayed Write Failed".'
           Steps = @(
               'Не записуйте на нього важливе без копії, доки причину не знайдено.'
               'Підключіть до USB-порту на задній панелі (прямо в материнську плату), без хабів і подовжувачів. Спробуйте інший кабель.'
               @{ Text = 'Застосуйте пункт "USB selective suspend" на вкладці Рекомендовані.' }
               @{ Text = 'Перевірте SMART через CrystalDiskInfo (вона бачить диски в більшості USB-кишень).'; Open = 'https://crystalmark.info/en/software/crystaldiskinfo/' }
               'Якщо кишеня розбирається - підключіть диск напряму по SATA: так видно, винен диск чи контролер кишені.'
           ) }
    )
}
