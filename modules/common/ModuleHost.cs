// Спільне для GUI модулів (Setup, Audit): запуск PowerShell-рушія з -OutFile, папка даних, тема, прості контроли.
// Компілюється в кожен модуль разом із src\Theme.cs (див. build.cmd); трей цього файлу не містить.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadPixel
{
    static class ModuleHost
    {
        // Папка exe модуля: modules\<назва>\
        public static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory;

        public static bool IsAdmin
        {
            get { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        }

        // data\<sub> поруч із програмою (як у трея й PowerShell-рушіїв), інакше %LOCALAPPDATA%\DeadPixel\<sub>
        public static string DataDir(string sub)
        {
            var d = Path.GetFullPath(Path.Combine(Dir, @"..\..\data", sub));
            try
            {
                Directory.CreateDirectory(d);
                var probe = Path.Combine(d, ".write-test");
                File.WriteAllText(probe, "");
                File.Delete(probe);
            }
            catch
            {
                d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeadPixel", sub);
                Directory.CreateDirectory(d);
            }
            return d;
        }

        // Запускає скрипт модуля і читає JSON, який він записав у тимчасовий файл (stdout з підвищеного процесу не перехопити)
        public static T RunScript<T>(string script, string args, bool elevate)
        {
            var tmp = Path.Combine(Path.GetTempPath(), "deadpixel-" + Path.GetFileNameWithoutExtension(script).ToLowerInvariant() + "-" + Guid.NewGuid().ToString("N") + ".json");
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(Dir, script) + "\" " + args + " -OutFile \"" + tmp + "\"");
            if (elevate && !IsAdmin) { psi.UseShellExecute = true; psi.Verb = "runas"; psi.WindowStyle = ProcessWindowStyle.Hidden; }
            else { psi.UseShellExecute = false; psi.CreateNoWindow = true; }
            try
            {
                using (var p = Process.Start(psi)) p.WaitForExit();
                if (!File.Exists(tmp)) throw new Exception(script + " не повернув результат.");
                return Deserialize<T>(File.ReadAllText(tmp, Encoding.UTF8));
            }
            finally { try { File.Delete(tmp); } catch { } }
        }

        public static T Deserialize<T>(string json)
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.Deserialize<T>(json);
        }

        // "control.exe /name X" → файл + аргументи; ms-settings:..., windowsdefender://... і *.msc відкриваються як є
        public static void Open(string run)
        {
            int sp = run.IndexOf(' ');
            var psi = sp > 0 && run.Substring(0, sp).EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? new ProcessStartInfo(run.Substring(0, sp), run.Substring(sp + 1))
                : new ProcessStartInfo(run);
            psi.UseShellExecute = true;
            Process.Start(psi);
        }

        // Тема як у трей-програми: data\settings.ini (Theme=system|light|dark), інакше — системна
        public static Theme LoadTheme()
        {
            var mode = "system";
            var inis = new[]
            {
                Path.GetFullPath(Path.Combine(Dir, @"..\..\data\settings.ini")),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DeadPixel\settings.ini"),
            };
            foreach (var ini in inis)
            {
                try
                {
                    if (!File.Exists(ini)) continue;
                    var line = File.ReadAllLines(ini).FirstOrDefault(l => l.StartsWith("Theme="));
                    if (line != null) mode = line.Substring(6).Trim();
                    break;
                }
                catch { }
            }
            if (mode == "dark") return Theme.DarkTheme;
            if (mode == "light") return Theme.Light;
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    return k != null && Convert.ToInt32(k.GetValue("AppsUseLightTheme", 1)) == 0 ? Theme.DarkTheme : Theme.Light;
            }
            catch { return Theme.Light; }
        }

        // Зелений «усе гаразд» — у Theme його немає, а модулям він потрібен однаковий
        public static Color Ok(Theme t) { return t.Dark ? Color.FromArgb(74, 222, 128) : Color.FromArgb(22, 135, 60); }
    }

    // Контроли в стилі DEADPIXEL (кольори ставить Theme.Apply)
    static class Ui
    {
        public static Button Btn(string text, EventHandler h)
        {
            var b = new Button { Text = text, AutoSize = true, Height = 30, Padding = new Padding(10, 2, 10, 2), Margin = new Padding(0, 0, 8, 0) };
            b.Click += h;
            return b;
        }

        public static Control Card(Control inner) { return Card(inner, Padding.Empty); }

        public static Control Card(Control inner, Padding pad)
        {
            var p = new Panel { Dock = DockStyle.Fill, Padding = pad, Tag = "surface", Margin = new Padding(0, 0, 0, 6) };
            inner.Dock = DockStyle.Fill;
            p.Controls.Add(inner);
            return p;
        }

        // Таблиця: колонка fill забирає вільну ширину, решта фіксовані
        public static ListView List(Func<Theme> theme, int fill, params object[] cols)
        {
            var lv = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, BorderStyle = BorderStyle.None, ShowItemToolTips = true };
            for (int i = 0; i < cols.Length; i += 2) lv.Columns.Add((string)cols[i], (int)cols[i + 1]);
            Theme.OwnerDrawHeaders(lv, theme);
            lv.Resize += (s, e) =>
            {
                int fixedW = 0;
                for (int i = 0; i < lv.Columns.Count; i++) if (i != fill) fixedW += lv.Columns[i].Width;
                lv.Columns[fill].Width = Math.Max(200, lv.ClientSize.Width - fixedW - 4);
            };
            return lv;
        }
    }
}
