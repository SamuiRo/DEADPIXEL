# SMBv1 - застарілий протокол спільних папок (WannaCry, NotPetya). Вимикається як компонент Windows.
@{
    Title       = 'SMBv1 вимкнено'
    Description = 'Прибирає застарілий протокол спільних папок з відомими критичними вразливостями. Сучасні NAS і Windows працюють через SMBv2/3.'
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Custom'; Id = 'smb1'; Title = 'Компонент «Підтримка SMB 1.0/CIFS»'; Desired = 'Disabled'
           # Стан компонента видно лише адміністратору; без прав - за службою клієнта mrxsmb10 (її немає, коли компонент вимкнено)
           Get = {
               if (Test-Admin) {
                   $s = [string](Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol).State
                   if ($s -match 'Disable') { 'Disabled' } else { 'Enabled' }
               } else {
                   $start = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -ErrorAction SilentlyContinue).Start
                   if ($null -eq $start -or $start -eq 4) { 'Disabled' } else { 'Enabled' }
               }
           }
           Set = {
               param($value)
               if ($value -eq 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart | Out-Null }
               else { Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -All -NoRestart | Out-Null }
           }
           Hint = 'Вимикає компонент Windows «Підтримка спільного доступу до файлів SMB 1.0/CIFS». Мінус: перестануть відкриватися спільні папки на дуже старих NAS і Windows XP - їм потрібне оновлення прошивки або SMBv2. Відкат вмикає компонент назад.' }
    )
}
