# Ігри й емулятори: те, що вони лишають у ядрі Windows. Античіти рівня ядра і драйвери віртуалізації емуляторів
# часто переживають видалення гри чи емулятора - драйвер з повними правами лишається без господаря й без оновлень.

# Античіти: шаблон імені служби/драйвера → назва і як прибрати штатно. Той самий перелік імен - у карантині
# (Quarantine.ps1, $DriverServiceAllowed): прибрати можна лише службу зі списку
$script:AntiCheats = @(
    @{ Match = '^(vgk|vgc)$'; Name = 'Riot Vanguard'; Games = 'Valorant, League of Legends'; Remove = (T 'видаліть «Riot Vanguard» у «Програмах»' 'uninstall "Riot Vanguard" in Apps') }
    @{ Match = '^EasyAntiCheat(_EOS|Sys)?$'; Name = 'Easy Anti-Cheat'; Games = 'Fortnite, Apex Legends, Elden Ring…'; Remove = (T 'у папці гри: EasyAntiCheat\EasyAntiCheat_Setup.exe → Uninstall' 'in the game folder: EasyAntiCheat\EasyAntiCheat_Setup.exe → Uninstall') }
    @{ Match = '^(BEService|BEDaisy)$'; Name = 'BattlEye'; Games = 'PUBG, Rainbow Six Siege, DayZ…'; Remove = (T 'у папці гри: BattlEye\Uninstall_BattlEye.bat' 'in the game folder: BattlEye\Uninstall_BattlEye.bat') }
    @{ Match = '^(ACE-[A-Z]+\d*|AntiCheatExpert Protection|SGuard(64|Svc64)?|TesSafe)$'; Name = 'Tencent Anti-Cheat Expert (ACE)'; Games = 'NIKKE, Delta Force, Wuthering Waves, Arena Breakout…'; Remove = (T 'видаліть «AntiCheatExpert» у «Програмах»' 'uninstall "AntiCheatExpert" in Apps') }
    @{ Match = '^(mhyprot[23]?|HoYoProtect|HoYoKProtect)$'; Name = 'HoYoverse (mhyprot / HoYoKProtect)'; Games = 'Genshin Impact, Honkai: Star Rail, Zenless Zone Zero'; Remove = (T 'видаляється разом із грою; якщо гри вже немає - «Прибрати…»' 'removed with the game; if the game is gone - "Clean up…"') }
    @{ Match = '^(FACEIT|faceit.*)$'; Name = 'FACEIT Anti-Cheat'; Games = 'CS2 (FACEIT)'; Remove = (T 'видаліть «FACEIT AC» у «Програмах»' 'uninstall "FACEIT AC" in Apps') }
    @{ Match = '^ESEADriver\d*$'; Name = 'ESEA Anti-Cheat'; Games = 'CS2 (ESEA)'; Remove = (T 'видаліть клієнт ESEA у «Програмах»' 'uninstall the ESEA client in Apps') }
    @{ Match = '^(npggsvc|GameMon|npptNT2)$'; Name = 'nProtect GameGuard'; Games = (T 'корейські MMO, Helldivers 2…' 'Korean MMOs, Helldivers 2…'); Remove = (T 'видаляється разом із грою; якщо гри вже немає - «Прибрати…»' 'removed with the game; if the game is gone - "Clean up…"') }
    @{ Match = '^(xhunter1|xigncode.*)$'; Name = 'XIGNCODE3 (Wellbia)'; Games = 'Black Desert, PSO2…'; Remove = (T 'видаляється разом із грою; якщо гри вже немає - «Прибрати…»' 'removed with the game; if the game is gone - "Clean up…"') }
    @{ Match = '^(EAAntiCheatService|eaanticheat)$'; Name = 'EA AntiCheat'; Games = 'EA FC, Battlefield…'; Remove = (T 'у папці EA: EAAntiCheat.Installer.exe → Uninstall' 'in the EA folder: EAAntiCheat.Installer.exe → Uninstall') }
    @{ Match = '^atvi-randgrid_sr$'; Name = 'Ricochet (Activision)'; Games = 'Call of Duty'; Remove = (T 'видаляється разом із грою' 'removed with the game') }
    @{ Match = '^EQU8_HELPER_\d+$'; Name = 'EQU8'; Games = 'Splitgate…'; Remove = (T 'видаляється разом із грою; якщо гри вже немає - «Прибрати…»' 'removed with the game; if the game is gone - "Clean up…"') }
    @{ Match = '^PnkBstr[AB]$'; Name = 'PunkBuster'; Games = (T 'старі Battlefield' 'older Battlefield titles'); Remove = (T 'pbsvc.exe → Uninstall або «Прибрати…»' 'pbsvc.exe → Uninstall, or "Clean up…"') }
    @{ Match = '^HtAntiCheatDriver$'; Name = (T 'античіт гри (HT)' 'game anti-cheat (HT)'); Games = 'Neverness To Everness…'; Remove = (T 'видаляється разом із грою; якщо гри вже немає - «Прибрати…»' 'removed with the game; if the game is gone - "Clean up…"') }
)

# Емулятори й засоби віртуалізації: чи встановлено (назва в «Програмах»), служби/драйвери, папки з даними (віртуальні диски)
$script:Emulators = @(
    @{ Name = 'BlueStacks'; Installed = '^BlueStacks'; Services = 'BlueStacksDrv_nxt', 'BlueStacksDrv', 'BstHdDrv', 'BstkDrv', 'BstHdLogRotatorSvc'; Traces = 'BlueStacks|Bstk'
       Folders = "$env:ProgramData\BlueStacks_nxt", "$env:ProgramData\BlueStacks", "$env:ProgramData\BlueStacksSetup", "$env:ProgramFiles\BlueStacks_nxt", "$env:LOCALAPPDATA\BlueStacks X", "$env:LOCALAPPDATA\BlueStacksSetup", "$env:LOCALAPPDATA\Programs\bluestacks-services" }
    @{ Name = 'NoxPlayer'; Installed = '^Nox(Player)?\b|Bignox'; Services = 'NoxVMSVC', 'XQHDrv', 'YSDrv'; Traces = 'Nox|Bignox'
       Folders = "$env:LOCALAPPDATA\Nox", "${env:ProgramFiles(x86)}\Bignox", "${env:ProgramFiles(x86)}\Nox", "$env:USERPROFILE\Nox_share" }
    @{ Name = 'LDPlayer'; Installed = 'LDPlayer'; Services = 'Ld9BoxSup', 'LdVBoxDrv', 'LdBoxDrv'; Traces = 'LDPlayer|XuanZhi|dnplayer'
       Folders = "$env:APPDATA\XuanZhi9", "$env:APPDATA\XuanZhi", "$env:LOCALAPPDATA\XuanZhi9", "$env:SystemDrive\LDPlayer" }
    @{ Name = 'MEmu'; Installed = '^MEmu'; Services = 'MEmuSVC', 'MEmuDrv'; Traces = 'MEmu|Microvirt'
       Folders = "$env:ProgramFiles\Microvirt", "$env:USERPROFILE\.MemuHyperv" }
    @{ Name = 'MuMu Player'; Installed = 'MuMu'; Services = 'NemuDrv', 'NemuVMMDrv', 'MuMuVMMDrv', 'MuMuVMMNetAdp'; Traces = 'MuMu|Nemu'
       Folders = "$env:ProgramFiles\Netease\MuMuPlayer-12.0", "$env:ProgramFiles\Netease\MuMuPlayerGlobal-12.0", "$env:APPDATA\Netease\MuMuPlayer-12.0", "$env:LOCALAPPDATA\MuMuPlayerGlobal-12.0" }
    @{ Name = 'GameLoop'; Installed = 'GameLoop|Gameloop|Tencent Gaming Buddy'; Services = 'aow_drv', 'QMEmulatorService'; Traces = 'GameLoop|TxGameAssistant|AndroidEmulatorEn'
       Folders = "$env:APPDATA\Tencent\TxGameAssistant", "$env:LOCALAPPDATA\Tencent\TxGameAssistant" }
    @{ Name = (T 'Емулятор Android Studio' 'Android Studio emulator'); Installed = '^Android Studio'; Services = 'aehd', 'gvm', 'IntelHaxm'; Traces = $null
       Folders = "$env:USERPROFILE\.android\avd", "$env:LOCALAPPDATA\Android\Sdk\system-images" }
    @{ Name = 'VirtualBox'; Installed = 'VirtualBox'; Services = 'VBoxSup', 'VBoxDrv', 'VBoxNetAdp', 'VBoxNetLwf', 'VBoxUSBMon', 'VBoxSDS'; Traces = 'VirtualBox'
       Folders = "$env:USERPROFILE\VirtualBox VMs", "$env:USERPROFILE\.VirtualBox" }
    @{ Name = 'Google Play Games'; Installed = 'Google Play Games'; Services = 'GooglePlayGamesServices'; Traces = 'Play Games'
       Folders = "$env:LOCALAPPDATA\Google\Play Games" }
)

# Служба або драйвер за іменем: стан, тип запуску, шлях до файлу. $null - не зареєстровано
$script:SvcIndex = $null
function Get-ServiceEntry([string]$Name) {
    if ($null -eq $script:SvcIndex) {
        $script:SvcIndex = @{}
        foreach ($d in Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue) { $script:SvcIndex[$d.Name.ToLowerInvariant()] = [pscustomobject]@{ Name = $d.Name; Kernel = $true; State = $d.State; Start = $d.StartMode; Path = (Resolve-DriverPath $d.PathName) } }
        foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) { $script:SvcIndex[$s.Name.ToLowerInvariant()] = [pscustomobject]@{ Name = $s.Name; Kernel = $false; State = $s.State; Start = $s.StartMode; Path = (Get-ExeFromCommand $s.PathName) } }
    }
    $script:SvcIndex[$Name.ToLowerInvariant()]
}
function Get-AllServiceEntries { $null = Get-ServiceEntry 'x'; $script:SvcIndex.Values }

function Format-ServiceState($e) {
    $start = switch ($e.Start) { 'Boot' { T 'зі стартом Windows' 'at Windows boot' } 'System' { T 'зі стартом Windows' 'at Windows boot' } 'Auto' { T 'автоматично' 'automatic' } 'Manual' { T 'на вимогу' 'on demand' } 'Disabled' { T 'вимкнено' 'disabled' } default { "$($e.Start)" } }
    $(if ($e.State -eq 'Running') { T 'ПРАЦЮЄ зараз' 'RUNNING now' } else { T 'зупинено' 'stopped' }) + (T ', запуск: ' ', start: ') + $start
}

# Пункт для карантину: файлу вже немає - звичайний «хвіст» (Service); файл є - лише служба зі списку (DriverService)
function New-ServiceCleanup($e, [string]$Label) {
    $kind = if ($e.Path -and (Test-Path -LiteralPath $e.Path)) { 'DriverService' } else { 'Service' }
    New-CleanupItem $kind $Label @{ Name = $e.Name } $false
}

@{
    Id = 'gaming'; Title = (T 'Ігри й емулятори' 'Games and emulators'); Order = 8.5
    Checks = @(
        @{
            Id = 'anticheat-drivers'; Title = (T 'Античіти рівня ядра' 'Kernel-level anti-cheats')
            Test = {
                $found = @(); $items = @()
                foreach ($e in Get-AllServiceEntries) {
                    $ac = $AntiCheats | Where-Object { $e.Name -match $_.Match } | Select-Object -First 1
                    if (-not $ac) { continue }
                    $found += [pscustomobject]@{ Ac = $ac; E = $e; Missing = -not ($e.Path -and (Test-Path -LiteralPath $e.Path)); Always = $e.Start -in 'Boot', 'System', 'Auto' }
                }
                if (-not $found) { return Ok (T 'не знайдено' 'none found') }
                $ev = @(); $running = 0; $always = 0
                foreach ($g in $found | Group-Object { $_.Ac.Name } | Sort-Object Name) {
                    $ac = $g.Group[0].Ac
                    $ev += "● $($ac.Name) - " + (T 'ігри: ' 'games: ') + "$($ac.Games). " + (T 'Прибрати: ' 'Remove: ') + $ac.Remove
                    foreach ($x in $g.Group | Sort-Object { $_.E.Name }) {
                        if ($x.E.State -eq 'Running') { $running++ }
                        if ($x.Always) { $always++ }
                        $mark = if ($x.E.State -eq 'Running' -or $x.Always -or $x.Missing) { '⚠' } else { ' ' }
                        $ev += "   $mark $($x.E.Name) " + $(if ($x.E.Kernel) { T '(драйвер ядра)' '(kernel driver)' } else { T '(служба)' '(service)' }) + " - $(Format-ServiceState $x.E)" + $(if ($x.Missing) { T ', файлу вже немає' ', the file is gone' } else { " - $($x.E.Path)" })
                        if ($x.E.State -ne 'Running') { $items += New-ServiceCleanup $x.E "$($ac.Name): $($x.E.Name)" }
                    }
                }
                $products = @($found | ForEach-Object { $_.Ac.Name } | Sort-Object -Unique).Count
                $value = T "$products античітів, служб і драйверів: $($found.Count)" "$products anti-cheats, services and drivers: $($found.Count)"
                $detail = T 'Античіт рівня ядра - це драйвер із найвищими правами в системі. Поки гра встановлена, це плата за чесну гру. Але після видалення гри драйвер часто лишається: без оновлень, з повним доступом до пам''яті, і будь-яка вразливість у ньому стає дірою в ядрі (так було з mhyprot2 від Genshin Impact, яким вимикали антивіруси). Залиште античіти ігор, у які граєте; решту приберіть.' 'A kernel-level anti-cheat is a driver with the highest rights in the system. While the game is installed, that is the price of fair play. But after the game is removed the driver often stays: without updates, with full memory access, and any vulnerability in it becomes a kernel hole (as happened with Genshin Impact''s mhyprot2, used to switch off antiviruses). Keep the anti-cheats of games you play; remove the rest.'
                $r = if ($running -or $always) { Issue low ($value + (T ", працює зараз: $running, зі стартом Windows: $always" ", running now: $running, at Windows boot: $always")) ((T 'Позначені ⚠ працюють просто зараз або вантажаться разом із Windows, навіть коли ви не граєте. ' 'Those marked ⚠ run right now or load with Windows even when you are not playing. ') + $detail) $ev }
                     else { Issue info $value $detail $ev }
                Add-Cleanup $r $items
            }
            Explain = (T 'Сучасні онлайн-ігри ставлять драйвер, який стежить за системою з рівня ядра, щоб ловити чити. Деінсталятори ігор його часто не видаляють, а кілька ігор можуть ділити один античіт. Аудит показує всі такі драйвери, їх стан і штатний спосіб видалення.' 'Modern online games install a driver that watches the system from kernel level to catch cheats. Game uninstallers often leave it behind, and several games may share one anti-cheat. The audit lists all such drivers, their state and the official way to remove them.')
            Pros = @((T 'Менше стороннього коду в ядрі Windows' 'Less third-party code in the Windows kernel'), (T 'Зникає драйвер, який ніхто більше не оновлює' 'A driver nobody updates anymore is gone'))
            Cons = @((T 'Гра, якій потрібен цей античіт, не запуститься, поки він не встановиться знову (зазвичай сам, під час запуску гри або перевірки файлів)' 'A game needing this anti-cheat will not start until it is installed again (usually by itself, on game launch or file verification)'), (T 'Один античіт (EAC, BattlEye, ACE) обслуговує багато ігор - перевірте, чи не лишилося інших' 'One anti-cheat (EAC, BattlEye, ACE) serves many games - check that no others remain'))
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @(
                (T 'Спершу штатний спосіб із рядка «Прибрати:» біля античіту - він видаляє і службу, і файли.' 'First use the official way from the "Remove:" line next to the anti-cheat - it deletes both the service and the files.'),
                (T 'Якщо гри вже немає і деінсталятора теж - «Прибрати…»: запис служби чи драйвера піде в карантин (з копією в .reg, можна відновити). Працюючий драйвер так прибрати не можна - закрийте гру й лаунчер або перезавантажте ПК.' 'If the game and its uninstaller are gone - "Clean up…": the service or driver entry goes to quarantine (with a .reg copy, restorable). A running driver cannot be removed this way - close the game and launcher or restart the PC.')
            ) }
        }
        @{
            Id = 'emulator-leftovers'; Title = (T 'Емулятори й віртуалізація' 'Emulators and virtualization')
            Test = {
                $ev = @(); $items = @(); $leftKernel = $false; $leftAny = $false; $alwaysOn = $false; $total = 0L
                $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
                $runKeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
                foreach ($em in $Emulators) {
                    $installed = [bool](Get-InstalledApps | Where-Object { $_.DisplayName -match $em.Installed } | Select-Object -First 1)
                    $svcs = @($em.Services | ForEach-Object { Get-ServiceEntry $_ } | Where-Object { $_ })
                    $dirs = @($em.Folders | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
                    $auto = @()
                    if ($em.Traces) {
                        $auto += @($tasks | Where-Object { $_.TaskName -match $em.Traces } | ForEach-Object { (T 'завдання ' 'task ') + "$($_.TaskPath)$($_.TaskName)" })
                        foreach ($k in $runKeys) { $p = Get-ItemProperty $k -ErrorAction SilentlyContinue; if ($p) { $auto += @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and "$($_.Name) $($_.Value)" -match $em.Traces } | ForEach-Object { (T 'автозапуск ' 'startup ') + $_.Name }) } }
                    }
                    if (-not $svcs -and -not $dirs -and -not $auto) { continue }
                    $ev += "● $($em.Name) - " + $(if ($installed) { T 'встановлено' 'installed' } else { T 'НЕ встановлено, але лишилися сліди' 'NOT installed, but traces remain' })
                    foreach ($s in $svcs) {
                        $on = $s.State -eq 'Running' -or $s.Start -in 'Boot', 'System', 'Auto'
                        if ($installed -and $on -and $s.Kernel) { $alwaysOn = $true }
                        if (-not $installed) { $leftAny = $true; if ($s.Kernel) { $leftKernel = $true }; if ($s.State -ne 'Running') { $items += New-ServiceCleanup $s "$($em.Name): $($s.Name)" } }
                        $ev += "   $(if ($on -or -not $installed) { '⚠' } else { ' ' }) $($s.Name) " + $(if ($s.Kernel) { T '(драйвер ядра)' '(kernel driver)' } else { T '(служба)' '(service)' }) + " - $(Format-ServiceState $s)"
                    }
                    foreach ($d in $dirs) {
                        $size = Get-DirSize $d; $total += $size
                        # Найбільші файли - віртуальні диски: саме вони займають місце
                        $disks = @(Find-FilesByExtension $d '.vhd;.vhdx;.vdi;.vmdk;.qcow2;.img' 200000).Count
                        $ev += "     $(Format-Size $size) - $d" + $(if ($disks) { T " (віртуальних дисків: $disks)" " (virtual disks: $disks)" })
                        if (-not $installed) {
                            $leftAny = $true
                            # Карантин бере лише папки верхнього рівня в Program Files / ProgramData / AppData; решту - вручну
                            $top = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:APPDATA) | Where-Object { $_ }
                            if ($top -contains (Split-Path $d)) { $items += New-CleanupItem 'Path' "$(Format-Size $size) - $d" @{ Target = $d } $false $size }
                        }
                    }
                    foreach ($a in $auto) { $ev += "     $a"; if (-not $installed) { $leftAny = $true } }
                }
                if (-not $ev) { return Ok (T 'не знайдено' 'none found') }
                $value = T "займають $(Format-Size $total)" "using $(Format-Size $total)"
                $hint = T ' Окремо перевірте «Увімкнення або вимкнення компонентів Windows»: емулятори вмикають «Платформу віртуальної машини» і «Платформу гіпервізора Windows» та не вимикають їх після видалення.' ' Separately check "Turn Windows features on or off": emulators enable "Virtual Machine Platform" and "Windows Hypervisor Platform" and do not turn them off when removed.'
                if ($leftKernel) { return Add-Cleanup (Issue medium ((T 'хвости з драйвером ядра, ' 'leftovers with a kernel driver, ') + $value) ((T 'Емулятор видалено, а його драйвер віртуалізації лишився в ядрі Windows: він має повний доступ до пам''яті, більше не оновлюється і може конфліктувати з Hyper-V, WSL та античітами.' 'The emulator was removed, but its virtualization driver stayed in the Windows kernel: it has full memory access, is no longer updated and may conflict with Hyper-V, WSL and anti-cheats.') + $hint) $ev) $items }
                if ($leftAny) { return Add-Cleanup (Issue low ((T 'хвости, ' 'leftovers, ') + $value) ((T 'Після видаленого емулятора лишилися папки з віртуальними дисками, служби або автозапуск.' 'Folders with virtual disks, services or startup entries remain after a removed emulator.') + $hint) $ev) $items }
                if ($alwaysOn) { return Issue info ((T 'драйвер завжди завантажений, ' 'driver always loaded, ') + $value) ((T 'Драйвер віртуалізації емулятора (⚠) вантажиться разом із Windows, навіть коли емулятор закритий. Якщо користуєтеся емулятором рідко - видаліть його і ставте за потреби.' 'The emulator''s virtualization driver (⚠) loads with Windows even when the emulator is closed. If you use the emulator rarely, uninstall it and install when needed.') + $hint) $ev }
                Issue info $value ((T 'Встановлені емулятори і місце, яке займають їхні віртуальні диски.' 'Installed emulators and the space their virtual disks take.') + $hint) $ev
            }
            Explain = (T 'Емулятор Android - це віртуальна машина: драйвер гіпервізора в ядрі, служби, віртуальні диски на десятки гігабайт і, часто, увімкнені компоненти віртуалізації Windows. Деінсталятори прибирають це не повністю. Аудит шукає драйвери, служби, автозапуск і папки з дисками для BlueStacks, Nox, LDPlayer, MEmu, MuMu, GameLoop, емулятора Android Studio, VirtualBox і Google Play Games.' 'An Android emulator is a virtual machine: a hypervisor driver in the kernel, services, tens of gigabytes of virtual disks and, often, Windows virtualization features switched on. Uninstallers do not remove all of it. The audit looks for drivers, services, startup entries and disk folders of BlueStacks, Nox, LDPlayer, MEmu, MuMu, GameLoop, the Android Studio emulator, VirtualBox and Google Play Games.')
            Pros = @((T 'Звільняє гігабайти від віртуальних дисків' 'Frees gigabytes taken by virtual disks'), (T 'Прибирає з ядра драйвер, який ніхто не оновлює' 'Removes a driver nobody updates from the kernel'))
            Cons = @((T 'Разом із віртуальним диском зникають дані емулятора: встановлені ігри, збереження, акаунти' 'Emulator data goes with the virtual disk: installed games, saves, accounts'), (T 'Вимкнення компонентів віртуалізації Windows зупинить WSL, Docker Desktop і Пісочницю Windows' 'Turning off Windows virtualization features stops WSL, Docker Desktop and Windows Sandbox'))
            Fix = @{ Open = 'optionalfeatures.exe'; Steps = @(
                (T 'Встановлений емулятор видаляйте через «Програми»; для BlueStacks є офіційний BSTCleaner, який прибирає і драйвер.' 'Uninstall an installed emulator through Apps; BlueStacks has the official BSTCleaner, which removes the driver too.'),
                (T '«Прибрати…» для хвостів: папки з дисками і записи служб/драйверів ідуть у карантин (можна відновити 30 днів). Папки в профілі користувача (.android\avd, VirtualBox VMs) видаляйте вручну.' '"Clean up…" for leftovers: disk folders and service/driver entries go to quarantine (restorable for 30 days). Delete folders in the user profile (.android\avd, VirtualBox VMs) by hand.'),
                (T 'Якщо не користуєтеся WSL, Docker і Пісочницею: зніміть «Платформа віртуальної машини» і «Платформа гіпервізора Windows» у компонентах Windows і перезавантажте ПК.' 'If you do not use WSL, Docker or Sandbox: clear "Virtual Machine Platform" and "Windows Hypervisor Platform" in Windows features and restart the PC.')
            ) }
        }
    )
}
