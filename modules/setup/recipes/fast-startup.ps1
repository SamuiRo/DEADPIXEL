# Швидкий запуск (гібридне вимкнення): "Завершення роботи" насправді гібернує ядро і драйвери.
@{
    Title       = (T 'Швидкий запуск вимкнено' 'Fast Startup off')
    Description = (T 'Після "Завершення роботи" Windows стартує з чистого стану, а не з гібернованого ядра.' 'After "Shut down", Windows starts from a clean state rather than a hibernated kernel.')
    Items       = @(
        @{ Kind = 'Registry'; Id = 'hiberboot'; Title = (T 'Швидкий запуск (HiberbootEnabled)' 'Fast Startup (HiberbootEnabled)')
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Desired = 0
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Зі швидким запуском драйвери не ініціалізуються заново після вимкнення: збій GPU чи диска "переживає" вимкнення ПК, а оновлення драйверів і BIOS інколи не застосовуються. Повноцінно перезапускається лише через "Перезавантаження". Вимкнення додає кілька секунд до старту.' 'With Fast Startup, drivers are not reinitialized after shutdown: a GPU or disk fault "survives" turning the PC off, and driver and BIOS updates sometimes do not apply. Only "Restart" fully restarts. Turning it off adds a few seconds to boot.') }
    )
    Steps       = @((T 'Зміна діє з наступного "Завершення роботи"; "Перезавантаження" і так ігнорує швидкий запуск.' 'The change applies from the next "Shut down"; "Restart" ignores Fast Startup anyway.'))
}
