# Служба «Віддалений реєстр»: зміна реєстру ПК по мережі. Вдома не потрібна.
@{
    Title       = 'Віддалений реєстр вимкнено'
    Description = 'Служба, що дозволяє змінювати реєстр цього ПК по мережі, вимкнена і не запускається.'
    Items       = @(
        @{ Kind = 'Custom'; Id = 'remote-registry'; Title = 'Служба RemoteRegistry: тип запуску'; Desired = 'Disabled'
           Get = { [string](Get-Service RemoteRegistry -ErrorAction Stop).StartType }
           Set = {
               param($value)
               if ($value -eq 'Disabled') { Stop-Service RemoteRegistry -Force -ErrorAction SilentlyContinue }
               Set-Service RemoteRegistry -StartupType $value
           }
           Hint = 'Мінус: корпоративні інструменти адміністрування не зможуть читати реєстр цього ПК. Відкат повертає попередній тип запуску (служба запуститься за потреби).' }
    )
}
