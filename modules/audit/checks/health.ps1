# Стан системи: не безпека, а «діри» стабільності - місце на диску, здоров'я дисків, перезавантаження, відновлення.

@{
    Id = 'health'; Title = (T 'Стан системи' 'System health'); Order = 7
    Checks = @(
        @{
            Id = 'disk-space'; Title = (T 'Місце на системному диску' 'Free space on the system drive')
            Test = {
                $all = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
                $fmt = T '{0} вільно {1:N0} ГБ з {2:N0} ГБ ({3:N0}%)' '{0} {1:N0} GB free of {2:N0} GB ({3:N0}%)'
                $ev = @($all | ForEach-Object { $fmt -f $_.DeviceID, ($_.FreeSpace / 1GB), ($_.Size / 1GB), (100 * $_.FreeSpace / [Math]::Max([double]1, $_.Size)) })
                $c = $all | Where-Object DeviceID -eq $env:SystemDrive | Select-Object -First 1
                if (-not $c) { return Unknown (T 'Системний диск не знайдено.' 'System drive not found.') }
                $freeGb = $c.FreeSpace / 1GB; $pct = 100 * $c.FreeSpace / $c.Size
                $value = (T '{0:N0} ГБ ({1:N0}%)' '{0:N0} GB ({1:N0}%)') -f $freeGb, $pct
                if ($pct -lt 5 -or $freeGb -lt 5) { return Issue high $value (T 'Місця майже немає: оновлення Windows не встановляться, а програми й система можуть працювати з помилками.' 'Almost no space left: Windows updates will not install, and programs and the system may misbehave.') $ev }
                if ($pct -lt 10 -or $freeGb -lt 15) { return Issue medium $value (T 'Місця мало: великі оновлення Windows потребують 15-20 ГБ, а SSD сповільнюється, коли заповнений.' 'Space is low: big Windows updates need 15-20 GB, and an SSD slows down when full.') $ev }
                Ok $value '' $ev
            }
            Explain = (T 'Windows потрібне вільне місце для оновлень, файлу підкачки, тимчасових файлів і точок відновлення. SSD, заповнений більш ніж на 90%, працює повільніше і швидше зношується.' 'Windows needs free space for updates, the page file, temporary files and restore points. An SSD more than 90% full is slower and wears out faster.')
            Pros = @((T 'Оновлення встановлюються, система не гальмує' 'Updates install and the system stays responsive'))
            Cons = @()
            Fix = @{ Open = 'ms-settings:storagesense'; Steps = @((T '«Контроль пам''яті» → «Рекомендації щодо очищення»: тимчасові файли, кошик, старі завантаження.' 'Storage Sense → Cleanup recommendations: temporary files, Recycle Bin, old downloads.'), (T 'Великі ігри й медіа перенесіть на інший диск.' 'Move big games and media to another drive.')) }
        }
        @{
            Id = 'disk-health'; Title = (T 'Стан дисків' 'Disk health')
            Test = {
                $disks = @(Get-PhysicalDisk -ErrorAction Stop)
                $ev = @($disks | ForEach-Object { "$($_.FriendlyName) ($($_.MediaType)): $($_.HealthStatus), $(@($_.OperationalStatus) -join ', ')" })
                $bad = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' -or @($_.OperationalStatus) -match 'Predictive|Failed|Degraded' })
                if ($bad) { return Issue high (T "проблем: $($bad.Count)" "problems: $($bad.Count)") (T 'Windows бачить ознаки несправності диска. Негайно зробіть резервну копію важливих файлів.' 'Windows sees signs of a failing disk. Back up important files right away.') $ev }
                Ok (T "справні ($($disks.Count))" "healthy ($($disks.Count))") (T 'Детальніше (SMART, зависання дисків) - вкладка «Диски» в панелі DEADPIXEL.' 'More detail (SMART, disk stalls) is on the Disks tab of the DEADPIXEL panel.') $ev
            }
            Explain = (T 'Windows отримує від дисків самодіагностику (SMART). Попередження про несправність зазвичай з''являється за дні або тижні до відмови - час зберегти дані.' 'Windows receives self-diagnostics (SMART) from disks. A failure warning usually appears days or weeks before the disk dies - time to save your data.')
            Pros = @((T 'Встигаєте врятувати файли до відмови диска' 'You can rescue files before the disk fails'))
            Cons = @()
            Fix = @{ Steps = @((T 'Скопіюйте важливі файли на інший диск або в хмару, потім замініть несправний диск.' 'Copy important files to another disk or the cloud, then replace the failing disk.'), (T 'Подробиці - вкладка «Диски» в панелі DEADPIXEL.' 'Details are on the Disks tab of the DEADPIXEL panel.')) }
        }
        @{
            Id = 'uptime'; Title = (T 'Час без перезавантаження' 'Time since last restart')
            Test = {
                $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                $days = [int]((Get-Date) - $boot).TotalDays
                $value = if ($days -eq 0) { T 'менше доби' 'less than a day' } else { T "$days дн." "$days days" }
                if ($days -gt 30) { return Issue low $value (T "ПК не перезавантажувався з $($boot.ToString('dd.MM.yyyy')): частина оновлень і драйверів не застосована, а пам'ять фрагментована." "The PC has not restarted since $($boot.ToString('dd.MM.yyyy')): some updates and drivers are not applied, and memory is fragmented.") }
                Ok $value
            }
            Explain = (T '«Завершення роботи» зі швидким запуском не перезапускає ядро Windows - лише «Перезавантаження» робить це. Без нього не застосовуються оновлення ядра і драйверів.' 'Shut down with Fast Startup does not restart the Windows kernel - only Restart does. Without it, kernel and driver updates are not applied.')
            Pros = @((T 'Оновлення застосовані, витоки пам''яті в драйверах і програмах скинуто' 'Updates are applied and memory leaks in drivers and programs are cleared'))
            Cons = @()
            Fix = @{ Steps = @((T 'Перезавантажте ПК (саме «Перезавантаження», а не «Завершення роботи»).' 'Restart the PC (Restart specifically, not Shut down).')) }
        }
        @{
            Id = 'restore-points'; Title = (T 'Точки відновлення' 'Restore points')
            Admin = $true
            Test = {
                $rp = @(Get-ComputerRestorePoint -ErrorAction Stop)
                if (-not $rp) { return Issue low (T 'немає' 'none') (T 'Якщо після оновлення драйвера чи програми Windows почне збоїти, повернути систему до робочого стану буде нічим.' 'If Windows starts failing after a driver or program update, there is nothing to roll the system back to.') }
                $last = $rp | ForEach-Object { [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) } | Sort-Object | Select-Object -Last 1
                $days = [int]((Get-Date) - $last).TotalDays
                $ev = @($rp | Select-Object -Last 5 | ForEach-Object { "$([Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime).ToString('dd.MM.yyyy')) - $($_.Description)" })
                if ($days -gt 60) { return Issue info (T "остання $days дн. тому" "last one $days days ago") (T 'Остання точка відновлення давня - зміни після неї відкотити не вийде.' 'The latest restore point is old - changes made after it cannot be rolled back.') $ev }
                Ok (T "остання $($last.ToString('dd.MM.yyyy'))" "last $($last.ToString('dd.MM.yyyy'))") '' $ev
            }
            Explain = (T 'Точка відновлення - знімок системних файлів, драйверів і реєстру. Windows створює їх перед оновленнями; вони дозволяють відкотити систему, не чіпаючи ваших файлів. Це не резервна копія документів.' 'A restore point is a snapshot of system files, drivers and the registry. Windows creates them before updates; they let you roll the system back without touching your files. It is not a backup of your documents.')
            Pros = @((T 'Швидкий відкат після невдалого драйвера чи оновлення' 'Quick rollback after a bad driver or update'))
            Cons = @((T 'Займає кілька відсотків диска (налаштовується)' 'Takes a few percent of the disk (configurable)'))
            Fix = @{ Open = 'SystemPropertiesProtection.exe'; Steps = @((T '«Захист системи» → виберіть системний диск → «Налаштувати» → «Увімкнути захист системи», 5-10% місця.' 'System Protection → pick the system drive → Configure → Turn on system protection, 5-10% of space.')) }
        }
    )
}
