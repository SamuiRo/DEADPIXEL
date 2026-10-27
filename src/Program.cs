// DEADPIXEL Tray — легка трей-програма: пише "чорну скриньку" стану GPU/CPU, стежить за подіями
// Windows у реальному часі (TDR, WHEA, диски, USB), після перезавантаження показує, що було перед крашем.
// Збирається штатним компілятором .NET Framework 4.x (C# 5) — див. build.cmd.
using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace DeadPixel
{
    static class Program
    {
        public static string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        public static string DataDir = Path.Combine(BaseDir, "data");

        // Дані поруч з exe; якщо туди писати не можна (напр. Program Files) — у %LOCALAPPDATA%\DeadPixel
        static void ResolveDataDir()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                var probe = Path.Combine(DataDir, ".write-test");
                File.WriteAllText(probe, "");
                File.Delete(probe);
            }
            catch
            {
                DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeadPixel");
                Directory.CreateDirectory(DataDir);
            }
        }

        [STAThread]
        static void Main(string[] args)
        {
            ResolveDataDir();
            // Допоміжні режими, які запускаються з правами адміністратора (UAC)
            if (args.Length >= 2 && args[0] == "--analyze") { DumpAnalyzer.Run(args[1]); return; }
            if (args.Length >= 1 && args[0] == "--smart") { DiskMonitor.WriteSmartCache(); return; }
            if (args.Length >= 2 && args[0] == "--copydumps") { DiagPack.CopyMinidumps(args[1]); return; }
            if (args.Length >= 1 && args[0] == "--shortcuts") { Shortcuts.Set(Shortcuts.Desktop, true); Shortcuts.Set(Shortcuts.StartMenu, true); return; }

            bool created;
            var mutex = new Mutex(true, "DeadPixel_SingleInstance", out created);
            // Повторний запуск (ярлик, автозапуск) лише просить уже запущений екземпляр показати панель
            var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "DeadPixel_Show");
            if (!created) { showSignal.Set(); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var app = new TrayApp();
            app.ListenForShow(showSignal);
            if (args.Contains("--show") || app.Settings.ShowOnStart) app.ShowDashboard(null);
            else if (args.Contains("--settings")) app.ShowDashboard("Налаштування");
            var page = args.FirstOrDefault(a => a.StartsWith("--page="));
            if (page != null) app.ShowDashboard(page.Substring(7));
            Application.Run(app);
            GC.KeepAlive(mutex);
        }
    }
}
