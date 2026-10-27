# Стан системи: не безпека, а «діри» стабільності - місце на диску, здоров'я дисків, перезавантаження, відновлення.

@{
    Id = 'health'; Title = 'Стан системи'; Order = 7
    Checks = @(
        @{
            Id = 'disk-space'; Title = 'Місце на системному диску'
            Test = {
                $all = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
                $ev = @($all | ForEach-Object { '{0} вільно {1:N0} ГБ з {2:N0} ГБ ({3:N0}%)' -f $_.DeviceID, ($_.FreeSpace / 1GB), ($_.Size / 1GB), (100 * $_.FreeSpace / [Math]::Max([double]1, $_.Size)) })
                $c = $all | Where-Object DeviceID -eq $env:SystemDrive | Select-Object -First 1
                if (-not $c) { return Unknown 'Системний диск не знайдено.' }
                $freeGb = $c.FreeSpace / 1GB; $pct = 100 * $c.FreeSpace / $c.Size
                $value = '{0:N0} ГБ ({1:N0}%)' -f $freeGb, $pct
                if ($pct -lt 5 -or $freeGb -lt 5) { return Issue high $value 'Місця майже немає: оновлення Windows не встановляться, а програми й система можуть працювати з помилками.' $ev }
                if ($pct -lt 10 -or $freeGb -lt 15) { return Issue medium $value 'Місця мало: великі оновлення Windows потребують 15-20 ГБ, а SSD сповільнюється, коли заповнений.' $ev }
                Ok $value '' $ev
            }
            Explain = 'Windows потрібне вільне місце для оновлень, файлу підкачки, тимчасових файлів і точок відновлення. SSD, заповнений більш ніж на 90%, працює повільніше і швидше зношується.'
            Pros = @('Оновлення встановлюються, система не гальмує')
            Cons = @()
            Fix = @{ Open = 'ms-settings:storagesense'; Steps = @('«Контроль пам''яті» → «Рекомендації щодо очищення»: тимчасові файли, кошик, старі завантаження.', 'Великі ігри й медіа перенесіть на інший диск.') }
        }
        @{
            Id = 'disk-health'; Title = 'Стан дисків'
            Test = {
                $disks = @(Get-PhysicalDisk -ErrorAction Stop)
                $ev = @($disks | ForEach-Object { "$($_.FriendlyName) ($($_.MediaType)): $($_.HealthStatus), $(@($_.OperationalStatus) -join ', ')" })
                $bad = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' -or @($_.OperationalStatus) -match 'Predictive|Failed|Degraded' })
                if ($bad) { return Issue high "проблем: $($bad.Count)" 'Windows бачить ознаки несправності диска. Негайно зробіть резервну копію важливих файлів.' $ev }
                Ok "справні ($($disks.Count))" 'Детальніше (SMART, зависання дисків) - вкладка «Диски» в панелі DEADPIXEL.' $ev
            }
            Explain = 'Windows отримує від дисків самодіагностику (SMART). Попередження про несправність зазвичай з''являється за дні або тижні до відмови - час зберегти дані.'
            Pros = @('Встигаєте врятувати файли до відмови диска')
            Cons = @()
            Fix = @{ Steps = @('Скопіюйте важливі файли на інший диск або в хмару, потім замініть несправний диск.', 'Подробиці - вкладка «Диски» в панелі DEADPIXEL.') }
        }
        @{
            Id = 'uptime'; Title = 'Час без перезавантаження'
            Test = {
                $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                $days = [int]((Get-Date) - $boot).TotalDays
                $value = if ($days -eq 0) { 'менше доби' } else { "$days дн." }
                if ($days -gt 30) { return Issue low $value "ПК не перезавантажувався з $($boot.ToString('dd.MM.yyyy')): частина оновлень і драйверів не застосована, а пам''ять фрагментована." }
                Ok $value
            }
            Explain = '«Завершення роботи» зі швидким запуском не перезапускає ядро Windows - лише «Перезавантаження» робить це. Без нього не застосовуються оновлення ядра і драйверів.'
            Pros = @('Оновлення застосовані, витоки пам''яті в драйверах і програмах скинуто')
            Cons = @()
            Fix = @{ Steps = @('Перезавантажте ПК (саме «Перезавантаження», а не «Завершення роботи»).') }
        }
        @{
            Id = 'restore-points'; Title = 'Точки відновлення'
            Admin = $true
            Test = {
                $rp = @(Get-ComputerRestorePoint -ErrorAction Stop)
                if (-not $rp) { return Issue low 'немає' 'Якщо після оновлення драйвера чи програми Windows почне збоїти, повернути систему до робочого стану буде нічим.' }
                $last = $rp | ForEach-Object { [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) } | Sort-Object | Select-Object -Last 1
                $days = [int]((Get-Date) - $last).TotalDays
                $ev = @($rp | Select-Object -Last 5 | ForEach-Object { "$([Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime).ToString('dd.MM.yyyy')) - $($_.Description)" })
                if ($days -gt 60) { return Issue info "остання $days дн. тому" 'Остання точка відновлення давня - зміни після неї відкотити не вийде.' $ev }
                Ok "остання $($last.ToString('dd.MM.yyyy'))" '' $ev
            }
            Explain = 'Точка відновлення - знімок системних файлів, драйверів і реєстру. Windows створює їх перед оновленнями; вони дозволяють відкотити систему, не чіпаючи ваших файлів. Це не резервна копія документів.'
            Pros = @('Швидкий відкат після невдалого драйвера чи оновлення')
            Cons = @('Займає кілька відсотків диска (налаштовується)')
            Fix = @{ Open = 'SystemPropertiesProtection.exe'; Steps = @('«Захист системи» → виберіть системний диск → «Налаштувати» → «Увімкнути захист системи», 5-10% місця.') }
        }
    )
}
