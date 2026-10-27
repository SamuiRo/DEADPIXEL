# Служба «Віддалений реєстр»: зміна реєстру ПК по мережі. Вдома не потрібна.
@{
    Title       = (T 'Віддалений реєстр вимкнено' 'Remote Registry off')
    Description = (T 'Служба, що дозволяє змінювати реєстр цього ПК по мережі, вимкнена і не запускається.' 'The service that lets the network change this PC''s registry is disabled and does not start.')
    Items       = @(
        @{ Kind = 'Custom'; Id = 'remote-registry'; Title = (T 'Служба RemoteRegistry: тип запуску' 'RemoteRegistry service: startup type'); Desired = 'Disabled'
           Get = { [string](Get-Service RemoteRegistry -ErrorAction Stop).StartType }
           Set = {
               param($value)
               if ($value -eq 'Disabled') { Stop-Service RemoteRegistry -Force -ErrorAction SilentlyContinue }
               Set-Service RemoteRegistry -StartupType $value
           }
           Hint = (T 'Мінус: корпоративні інструменти адміністрування не зможуть читати реєстр цього ПК. Відкат повертає попередній тип запуску (служба запуститься за потреби).' 'Con: corporate management tools cannot read this PC''s registry. Revert restores the previous startup type (the service starts when needed).') }
    )
}
