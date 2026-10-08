using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace DeadPixel
{
    class TrayApp : ApplicationContext
    {
        public readonly Settings Settings = Settings.Load();
        public readonly Sampler Sampler;
        public readonly EventMonitor Events = new EventMonitor();
        public List<CrashInfo> Crashes = new List<CrashInfo>();
        public List<ChangeItem> Changes = new List<ChangeItem>();
        public string PatternText = "Аналізую…";

        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly SynchronizationContext ui;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 5000 };
        readonly Dictionary<string, DateTime> lastNotify = new Dictionary<string, DateTime>();
        readonly Icon icoOk, icoWarn, icoAlert;
        readonly string stateFile = Path.Combine(Program.DataDir, "last-seen-crash.txt");
        Dashboard dash;
        bool unseenCrash;

        public Theme Theme { get { return Settings.IsDark ? Theme.DarkTheme : Theme.Light; } }

        public TrayApp()
        {
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            Sampler = new Sampler(Settings);
            icoOk = MakeIcon(Color.FromArgb(46, 160, 67));
            icoWarn = MakeIcon(Color.FromArgb(230, 160, 0));
            icoAlert = MakeIcon(Color.FromArgb(215, 45, 45));

            BuildMenu();
            tray.ContextMenuStrip = menu;
            tray.Icon = icoOk;
            tray.Text = "DEADPIXEL";
            tray.Visible = true;
            tray.DoubleClick += (s, e) => ShowDashboard(null);
            tray.BalloonTipClicked += (s, e) => ShowDashboard("Краші");

            Settings.Changed += OnSettingsChanged;
            Sampler.Start();
            Events.NewEvent += it => ui.Post(_ => OnLiveEvent(it), null);
            Sampler.Stalls.StallDetected += st => ui.Post(_ =>
            {
                Events.AddExternal(new EvItem { Time = st.Time, Category = "Диск", Source = "DEADPIXEL", Id = 0, Level = 3, Text = st.Text });
                if (Settings.NotifyDisk && st.Seconds >= 10)
                    Notify("stall:" + st.Disk, TimeSpan.FromMinutes(10), "Диск не відповідав " + st.Seconds.ToString("0") + " с", st.Text, ToolTipIcon.Warning);
            }, null);

            // Початкове сканування у фоні, щоб трей з'явився одразу
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Events.LoadInitial(7);
                Events.StartWatching();
                var crashes = LoadCrashes();
                ui.Post(__ => OnCrashesLoaded(crashes), null);
            });

            timer.Tick += (s, e) => { UpdateTray(); CheckTemps(); };
            timer.Start();
        }

        void BuildMenu()
        {
            menu.Items.Clear();
            var open = menu.Items.Add("Відкрити панель", null, (s, e) => ShowDashboard(null));
            open.Font = new Font(menu.Font, FontStyle.Bold);
            menu.Items.Add("Повний звіт (HTML)", null, (s, e) => RunFullReport());
            menu.Items.Add("Папка чорної скриньки", null, (s, e) => Open(Program.DataDir));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Налаштування…", null, (s, e) => ShowDashboard("Налаштування"));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Вихід", null, (s, e) => ExitThread());
            ApplyMenuTheme();
        }

        void ApplyMenuTheme()
        {
            var t = Theme;
            menu.Renderer = new ToolStripProfessionalRenderer(new MenuColors(t));
            menu.BackColor = t.Surface;
            foreach (ToolStripItem i in menu.Items) i.ForeColor = t.Fg;
        }

        void OnSettingsChanged()
        {
            ApplyMenuTheme();
            if (dash != null && !dash.IsDisposed) dash.ApplyTheme();
        }

        // Повне сканування: краші + історія змін + контекст кожного краша + закономірності (у фоні)
        public List<CrashInfo> LoadCrashes()
        {
            var crashes = EventMonitor.ScanCrashes(90);
            List<ChangeItem> changes;
            try { changes = ChangeHistory.Load(120); } catch { changes = new List<ChangeItem>(); }
            var wmiDriver = "?";
            try
            {
                foreach (System.Management.ManagementObject o in new System.Management.ManagementObjectSearcher("SELECT Name,DriverVersion FROM Win32_VideoController").Get())
                    if (((string)o["Name"]).Contains("NVIDIA")) wmiDriver = CrashAnalyzer.NvVersion((string)o["DriverVersion"]);
            }
            catch { }
            try { CrashAnalyzer.Enrich(crashes, changes, wmiDriver); } catch { }
            string pattern;
            try { pattern = PatternAnalyzer.Build(crashes, changes); } catch (Exception ex) { pattern = "Помилка аналізу: " + ex.Message; }
            Changes = changes;
            PatternText = pattern;
            return crashes;
        }

        void OnCrashesLoaded(List<CrashInfo> crashes)
        {
            Crashes = crashes;
            DateTime seen = ReadSeen();
            var newest = crashes.Count > 0 ? crashes.Max(c => c.Boot) : DateTime.MinValue;
            if (seen == DateTime.MinValue) WriteSeen(newest > DateTime.MinValue ? newest : DateTime.Now); // перший запуск — без тривоги
            else
            {
                var fresh = crashes.Where(c => c.Boot > seen).OrderByDescending(c => c.Boot).ToList();
                if (fresh.Count > 0 && (dash == null || dash.IsDisposed || !dash.Visible))
                {
                    unseenCrash = true;
                    if (Settings.NotifyCrash)
                    {
                        var c = fresh[0];
                        var txt = string.Format("{0:dd.MM HH:mm} — {1}{2}", c.Boot, BugChecks.Get(c.Code)[0], c.Driver != "" ? " (" + c.Driver + ")" : "");
                        if (c.LastFg != "") txt += "\nОстання активна програма: " + c.LastFg;
                        if (fresh.Count > 1) txt += string.Format("\nНових крашів: {0}", fresh.Count);
                        tray.ShowBalloonTip(15000, "Комп'ютер перезавантажився через збій", txt + "\nНатисніть, щоб подивитися деталі.", ToolTipIcon.Error);
                    }
                }
                else if (fresh.Count > 0) MarkCrashesSeen();
            }
            UpdateTray();
            if (dash != null && !dash.IsDisposed) dash.ReloadCrashes();
        }

        bool Allowed(string category)
        {
            switch (category)
            {
                case "GPU": return Settings.NotifyGpu;
                case "WHEA": return Settings.NotifyWhea;
                case "Диск": return Settings.NotifyDisk;
                case "USB": return Settings.NotifyUsb;
                case "Програма": return Settings.NotifyApp;
                case "CPU": return Settings.NotifyWhea;
                default: return true;
            }
        }

        void Notify(string key, TimeSpan cooldown, string title, string text, ToolTipIcon icon)
        {
            DateTime last;
            if (lastNotify.TryGetValue(key, out last) && DateTime.Now - last < cooldown) return;
            lastNotify[key] = DateTime.Now;
            tray.ShowBalloonTip(10000, title, text.Length > 200 ? text.Substring(0, 200) + "…" : text, icon);
        }

        void OnLiveEvent(EvItem it)
        {
            UpdateTray();
            if (!Allowed(it.Category)) return;
            var cooldown = it.Category == "GPU" || it.Category == "WHEA" ? TimeSpan.FromMinutes(1) : TimeSpan.FromMinutes(30);
            string title = it.Category == "GPU" ? "Проблема з відеодрайвером" : it.Category == "WHEA" ? "Апаратна помилка (WHEA)" :
                           it.Category == "USB" ? "Збій USB" : it.Category == "Програма" ? "Програма впала" :
                           it.Category == "CPU" ? "Процесор обмежено" : "Помилка диска";
            Notify("ev:" + it.Category, cooldown, title, it.Text, it.Category == "Диск" || it.Category == "Програма" ? ToolTipIcon.Warning : ToolTipIcon.Error);
        }

        void CheckTemps()
        {
            var s = Sampler.Last;
            if (s == null || !Settings.NotifyTemp) return;
            if (!double.IsNaN(s.GpuTemp) && s.GpuTemp >= Settings.GpuTempWarn)
                Notify("temp:gpu", TimeSpan.FromMinutes(10), "Висока температура GPU", string.Format("{0:0} °C (поріг {1} °C)", s.GpuTemp, Settings.GpuTempWarn), ToolTipIcon.Warning);
            if (!double.IsNaN(s.CpuTemp) && s.CpuTemp >= Settings.CpuTempWarn)
                Notify("temp:cpu", TimeSpan.FromMinutes(10), "Висока температура CPU", string.Format("{0:0} °C (поріг {1} °C)", s.CpuTemp, Settings.CpuTempWarn), ToolTipIcon.Warning);
            if (Sampler.ReasonsCritical(s.Reasons))
                Notify("gpu:slowdown", TimeSpan.FromMinutes(10), "GPU примусово сповільнено", Sampler.DecodeReasons(s.Reasons) + " — можлива проблема з живленням або перегрів.", ToolTipIcon.Warning);
        }

        void UpdateTray()
        {
            bool recent;
            lock (Events.Lock)
                recent = Events.Items.Any(e => (e.Category == "GPU" || e.Category == "WHEA") && e.Time > DateTime.Now.AddHours(-24));
            tray.Icon = unseenCrash ? icoAlert : recent ? icoWarn : icoOk;
            var s = Sampler.Last;
            string tip = "DEADPIXEL";
            if (s != null)
            {
                if (!double.IsNaN(s.GpuTemp)) tip += string.Format("\nGPU {0:0}°C {1:0}W {2}", s.GpuTemp, s.GpuPower, s.PState);
                if (!double.IsNaN(s.CpuPct)) tip += string.Format("\nCPU {0:0}%{1}", s.CpuPct, double.IsNaN(s.CpuTemp) ? "" : string.Format(" {0:0}°C", s.CpuTemp));
            }
            if (unseenCrash) tip += "\nНовий краш!";
            else if (recent) tip += "\nЗбої GPU за 24 год";
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip; // .NET Framework обмежує підказку 63 символами
        }

        public void MarkCrashesSeen()
        {
            if (Crashes.Count > 0) WriteSeen(Crashes.Max(c => c.Boot));
            unseenCrash = false;
            UpdateTray();
        }

        public void ShowDashboard(string page)
        {
            if (dash == null || dash.IsDisposed) dash = new Dashboard(this);
            dash.Show();
            if (dash.WindowState == FormWindowState.Minimized) dash.WindowState = FormWindowState.Normal;
            if (page != null) dash.SelectPage(page);
            dash.Activate();
            MarkCrashesSeen();
        }

        public void RunFullReport()
        {
            var cmd = Path.Combine(Program.BaseDir, "DeadPixel.cmd");
            if (File.Exists(cmd)) Open(cmd);
            else MessageBox.Show("Не знайдено " + cmd, "DEADPIXEL");
        }

        public static void Open(string path)
        {
            try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "DEADPIXEL"); }
        }

        DateTime ReadSeen()
        {
            try { return new DateTime(long.Parse(File.ReadAllText(stateFile).Trim())); } catch { return DateTime.MinValue; }
        }

        void WriteSeen(DateTime t)
        {
            try { File.WriteAllText(stateFile, t.Ticks.ToString()); } catch { }
        }

        static Icon MakeIcon(Color c)
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var b = new SolidBrush(c)) g.FillEllipse(b, 2, 2, 28, 28);
                    using (var pen = new Pen(Color.White, 3f) { LineJoin = LineJoin.Round })
                        g.DrawLines(pen, new[] { new Point(6, 17), new Point(11, 17), new Point(14, 9), new Point(18, 24), new Point(21, 15), new Point(26, 15) });
                }
                var h = bmp.GetHicon();
                var ico = (Icon)Icon.FromHandle(h).Clone();
                Native.DestroyIcon(h);
                return ico;
            }
        }

        public Icon AppIcon { get { return icoOk; } }

        protected override void ExitThreadCore()
        {
            tray.Visible = false;
            Sampler.Stop();
            if (dash != null && !dash.IsDisposed) dash.Close();
            base.ExitThreadCore();
        }
    }
}
