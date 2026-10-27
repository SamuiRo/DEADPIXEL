# Secure Boot вмикається лише в BIOS/UEFI - тут покроковий сценарій із перевірками до і після.
@{
    Title       = 'Secure Boot'
    Description = 'Прошивка запускатиме лише підписані завантажувачі: захист від буткітів, вимога Windows 11 і анти-читів. Вмикається в BIOS - сценарій веде крок за кроком.'
    Tabs        = @(
        @{ Id = 'enable'; Title = 'Увімкнути Secure Boot'
           Description = 'Спершу дві перевірки, без яких Windows після зміни може не завантажитися; потім перезавантаження в BIOS. Прогрес зберігається.'
           Steps = @(
               @{ Text = 'Перевірте, що Windows завантажується в режимі UEFI.'
                  Run = 'Confirm-SecureBootUEFI'; Admin = $true; Expect = '^(True|False)'
                  Hint = 'False - UEFI є, Secure Boot вимкнено: можна продовжувати. Помилка «не підтримується на цій платформі» - ПК у режимі Legacy BIOS: зупиніться, спершу потрібна конвертація диска (див. «Аудит» → «Режим завантаження UEFI»).' }
               @{ Text = 'Перевірте, що системний диск має розмітку GPT.'
                  Run = '$n = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber; "Розмітка диска ${n}: " + (Get-Disk -Number $n).PartitionStyle'
                  Admin = $true; Expect = 'GPT'
                  Hint = 'З MBR-диска Windows не завантажиться, коли в BIOS вимкнено CSM.' }
               @{ If = 'fail'; Text = 'Диск у MBR - далі не йдіть. Конвертація (після резервної копії): mbr2gpt /validate /allowFullOS, потім mbr2gpt /convert /allowFullOS.' }
               'Сфотографуйте або запишіть налаштування BIOS, які змінюватимете, - щоб за потреби повернути як було.'
               @{ Text = 'Перезавантажте ПК одразу в BIOS/UEFI.'; Reboot = 'firmware'
                  Confirm = 'ПК перезавантажиться в налаштування BIOS. Збережіть відкриті файли.'
                  Hint = 'Кнопка виконує shutdown /r /fw. Якщо плата не підтримує вхід у UEFI з Windows - перезавантажте звичайно і тисніть Del або F2 під час старту.' }
               @{ Text = 'У BIOS вимкніть CSM (Compatibility Support Module / Legacy Boot), якщо він увімкнений.'
                  Hint = 'MSI: Settings → Advanced → Windows OS Configuration → BIOS UEFI/CSM Mode = UEFI. ASUS: Boot → CSM → Disabled. Gigabyte: Boot → CSM Support → Disabled.' }
               @{ Text = 'Увімкніть Secure Boot (режим Standard), збережіть і вийдіть (зазвичай F10).'
                  Hint = 'MSI: Settings → Advanced → Windows OS Configuration → Secure Boot → Enabled. ASUS: Boot → Secure Boot → OS Type = Windows UEFI mode. Gigabyte: Boot → Secure Boot → Enabled. Якщо пункт неактивний або Secure Boot не вмикається - виберіть «Install/Restore Factory Default Keys».' }
               @{ Text = 'Перевірте, що Secure Boot працює.'
                  Run = 'Confirm-SecureBootUEFI'; Admin = $true; Expect = '^True'
                  Hint = 'True - готово. Якщо Windows не завантажилася - поверніться в BIOS і ввімкніть CSM назад: дані не постраждали.' }
           ) }
    )
}
