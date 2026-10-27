# Профіль - набір рецептів під задачу + кроки, які не автоматизуються.
@{
    Title       = 'Безпека: захист ядра і Windows'
    Description = 'Рекомендовані налаштування захисту з «Аудиту системи». Кожне можна відкотити; перед застосуванням прочитайте мінуси в підказках.'
    Recipes     = @('hvci', 'lsa-protection', 'driver-blocklist', 'uac-default', 'defender-pua', 'smb1-off', 'rdp-hardening', 'remote-registry-off')
    Steps       = @(
        'Secure Boot і TPM вмикаються в BIOS - для Secure Boot є покроковий сценарій (рецепт «Secure Boot»).'
        'Шифрування диска (BitLocker) вмикайте окремо і лише після того, як збережете ключ відновлення.'
    )
}
