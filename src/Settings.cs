using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadPixel
{
    // Прості налаштування у data\settings.ini (ключ=значення). Кожне публічне поле — один параметр.
    class Settings
    {
        public string Theme = "system";      // system | light | dark
        public bool ShowOnStart = false;
        public int IntervalSec = 2;
        public int RetentionDays = 14;
        public bool NotifyCrash = true;
        public bool NotifyGpu = true;
        public bool NotifyWhea = true;
        public bool NotifyDisk = true;
        public bool NotifyUsb = true;
        public bool NotifyApp = false;
        public bool NotifyTemp = true;
        public bool NotifyAudit = true;      // нові серйозні проблеми з аудиту за розкладом
        public int GpuTempWarn = 85;
        public int CpuTempWarn = 90;

        public event Action Changed;
        readonly string path = Path.Combine(Program.DataDir, "settings.ini");
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (File.Exists(s.path))
                    foreach (var line in File.ReadAllLines(s.path))
                    {
                        int i = line.IndexOf('=');
                        if (i < 1) continue;
                        var f = typeof(Settings).GetField(line.Substring(0, i).Trim());
                        if (f == null) continue;
                        try { f.SetValue(s, Convert.ChangeType(line.Substring(i + 1).Trim(), f.FieldType, CultureInfo.InvariantCulture)); } catch { }
                    }
            }
            catch { }
            s.IntervalSec = Math.Max(1, Math.Min(10, s.IntervalSec));
            s.RetentionDays = Math.Max(1, Math.Min(90, s.RetentionDays));
            return s;
        }

        public void Save()
        {
            try
            {
                File.WriteAllLines(path, typeof(Settings).GetFields().Where(f => !f.IsStatic)
                    .Select(f => f.Name + "=" + Convert.ToString(f.GetValue(this), CultureInfo.InvariantCulture)));
            }
            catch { }
            var h = Changed;
            if (h != null) h();
        }

        // Автозапуск зберігається не в ini, а в реєстрі користувача (HKCU\...\Run)
        public bool Autostart
        {
            get
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue("DeadPixel") != null;
            }
            set
            {
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (value) k.SetValue("DeadPixel", "\"" + Application.ExecutablePath + "\"");
                    else k.DeleteValue("DeadPixel", false);
                }
            }
        }

        public bool IsDark
        {
            get
            {
                if (Theme == "dark") return true;
                if (Theme == "light") return false;
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                        return k != null && Convert.ToInt32(k.GetValue("AppsUseLightTheme", 1)) == 0;
                }
                catch { return false; }
            }
        }
    }
}
