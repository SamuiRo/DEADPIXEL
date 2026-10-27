# Secure Boot вмикається лише в BIOS/UEFI - тут покроковий сценарій із перевірками до і після.
@{
    Title       = 'Secure Boot'
    Description = (T 'Прошивка запускатиме лише підписані завантажувачі: захист від буткітів, вимога Windows 11 і анти-читів. Вмикається в BIOS - сценарій веде крок за кроком.' 'The firmware will start only signed boot loaders: protection from bootkits, required by Windows 11 and anti-cheats. It is turned on in BIOS — the scenario walks you through it.')
    Tabs        = @(
        @{ Id = 'enable'; Title = (T 'Увімкнути Secure Boot' 'Turn on Secure Boot')
           Description = (T 'Спершу дві перевірки, без яких Windows після зміни може не завантажитися; потім перезавантаження в BIOS. Прогрес зберігається.' 'First two checks without which Windows may not boot after the change; then a restart into BIOS. Progress is saved.')
           Steps = @(
               @{ Text = (T 'Перевірте, що Windows завантажується в режимі UEFI.' 'Check that Windows boots in UEFI mode.')
                  Run = 'Confirm-SecureBootUEFI'; Admin = $true; Expect = '^(True|False)'
                  Hint = (T 'False - UEFI є, Secure Boot вимкнено: можна продовжувати. Помилка «не підтримується на цій платформі» - ПК у режимі Legacy BIOS: зупиніться, спершу потрібна конвертація диска (див. «Аудит» → «Режим завантаження UEFI»).' 'False — UEFI is present and Secure Boot is off: you can continue. An error "not supported on this platform" means the PC is in Legacy BIOS mode: stop, the disk needs converting first (see "Audit" → "UEFI boot mode").') }
               @{ Text = (T 'Перевірте, що системний диск має розмітку GPT.' 'Check that the system disk uses GPT.')
                  Run = '$n = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber; "Disk ${n}: " + (Get-Disk -Number $n).PartitionStyle'
                  Admin = $true; Expect = 'GPT'
                  Hint = (T 'З MBR-диска Windows не завантажиться, коли в BIOS вимкнено CSM.' 'Windows will not boot from an MBR disk once CSM is off in BIOS.') }
               @{ If = 'fail'; Text = (T 'Диск у MBR - далі не йдіть. Конвертація (після резервної копії): mbr2gpt /validate /allowFullOS, потім mbr2gpt /convert /allowFullOS.' 'The disk is MBR — do not go further. Convert (after a backup): mbr2gpt /validate /allowFullOS, then mbr2gpt /convert /allowFullOS.') }
               (T 'Сфотографуйте або запишіть налаштування BIOS, які змінюватимете, - щоб за потреби повернути як було.' 'Photograph or write down the BIOS settings you change, so you can put them back if needed.')
               @{ Text = (T 'Перезавантажте ПК одразу в BIOS/UEFI.' 'Restart the PC straight into BIOS/UEFI.'); Reboot = 'firmware'
                  Confirm = (T 'ПК перезавантажиться в налаштування BIOS. Збережіть відкриті файли.' 'The PC will restart into BIOS setup. Save your open files.')
                  Hint = (T 'Кнопка виконує shutdown /r /fw. Якщо плата не підтримує вхід у UEFI з Windows - перезавантажте звичайно і тисніть Del або F2 під час старту.' 'The button runs shutdown /r /fw. If the board cannot enter UEFI from Windows, restart normally and press Del or F2 during boot.') }
               @{ Text = (T 'У BIOS вимкніть CSM (Compatibility Support Module / Legacy Boot), якщо він увімкнений.' 'In BIOS turn off CSM (Compatibility Support Module / Legacy Boot) if it is on.')
                  Hint = (T 'MSI: Settings → Advanced → Windows OS Configuration → BIOS UEFI/CSM Mode = UEFI. ASUS: Boot → CSM → Disabled. Gigabyte: Boot → CSM Support → Disabled.' 'MSI: Settings → Advanced → Windows OS Configuration → BIOS UEFI/CSM Mode = UEFI. ASUS: Boot → CSM → Disabled. Gigabyte: Boot → CSM Support → Disabled.') }
               @{ Text = (T 'Увімкніть Secure Boot (режим Standard), збережіть і вийдіть (зазвичай F10).' 'Turn on Secure Boot (Standard mode), save and exit (usually F10).')
                  Hint = (T 'MSI: Settings → Advanced → Windows OS Configuration → Secure Boot → Enabled. ASUS: Boot → Secure Boot → OS Type = Windows UEFI mode. Gigabyte: Boot → Secure Boot → Enabled. Якщо пункт неактивний або Secure Boot не вмикається - виберіть «Install/Restore Factory Default Keys».' 'MSI: Settings → Advanced → Windows OS Configuration → Secure Boot → Enabled. ASUS: Boot → Secure Boot → OS Type = Windows UEFI mode. Gigabyte: Boot → Secure Boot → Enabled. If the item is greyed out or Secure Boot will not turn on, choose "Install/Restore Factory Default Keys".') }
               @{ Text = (T 'Перевірте, що Secure Boot працює.' 'Check that Secure Boot is working.')
                  Run = 'Confirm-SecureBootUEFI'; Admin = $true; Expect = '^True'
                  Hint = (T 'True - готово. Якщо Windows не завантажилася - поверніться в BIOS і ввімкніть CSM назад: дані не постраждали.' 'True — done. If Windows did not boot, go back to BIOS and turn CSM back on: your data is unharmed.') }
           ) }
    )
}
