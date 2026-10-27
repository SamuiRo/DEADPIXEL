# Профіль - набір рецептів під задачу + кроки, які не автоматизуються.
@{
    Title       = (T 'Безпека: захист ядра і Windows' 'Security: kernel and Windows protection')
    Description = (T 'Рекомендовані налаштування захисту з «Аудиту системи». Кожне можна відкотити; перед застосуванням прочитайте мінуси в підказках.' 'Recommended protection settings from the "System audit". Each can be reverted; read the cons in the hints before applying.')
    Recipes     = @('hvci', 'lsa-protection', 'driver-blocklist', 'uac-default', 'defender-pua', 'smb1-off', 'rdp-hardening', 'remote-registry-off')
    Steps       = @(
        (T 'Secure Boot і TPM вмикаються в BIOS - для Secure Boot є покроковий сценарій (рецепт «Secure Boot»).' 'Secure Boot and TPM are turned on in BIOS — there is a step-by-step scenario for Secure Boot (the "Secure Boot" recipe).')
        (T 'Шифрування диска (BitLocker) вмикайте окремо і лише після того, як збережете ключ відновлення.' 'Turn on disk encryption (BitLocker) separately and only after saving the recovery key.')
    )
}
