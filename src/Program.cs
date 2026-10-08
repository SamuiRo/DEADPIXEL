// CrashDoctor Tray — легка трей-програма: пише "чорну скриньку" стану GPU/CPU, стежить за подіями
// Windows у реальному часі (TDR, WHEA, диски, USB), після перезавантаження показує, що було перед крашем.
// Збирається штатним компілятором .NET Framework 4.x (C# 5) — див. build.cmd.
using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace CrashDoctor
{
    static class Program
    {
        public static string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        public static string DataDir = Path.Combine(BaseDir, "data");

        // Дані поруч з exe; якщо туди писати не можна (напр. Program Files) — у %LOCALAPPDATA%\CrashDoctor
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
                DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CrashDoctor");
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

            bool created;
            var mutex = new Mutex(true, "CrashDoctorTray_SingleInstance", out created);
            if (!created) { MessageBox.Show("CrashDoctor вже запущено — іконка в треї.", "CrashDoctor"); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var app = new TrayApp();
            if (args.Contains("--show") || app.Settings.ShowOnStart) app.ShowDashboard(null);
            else if (args.Contains("--settings")) app.ShowDashboard("Налаштування");
            var page = args.FirstOrDefault(a => a.StartsWith("--page="));
            if (page != null) app.ShowDashboard(page.Substring(7));
            Application.Run(app);
            GC.KeepAlive(mutex);
        }
    }
}
