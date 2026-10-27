using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
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
        public string PatternText = L.T("Аналізую…", "Analyzing…");

        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly SynchronizationContext ui;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 5000 };
        readonly Dictionary<string, DateTime> lastNotify = new Dictionary<string, DateTime>();
        readonly Icon icoOk, icoWarn, icoAlert, icoApp;
        readonly string stateFile = Path.Combine(Program.DataDir, "last-seen-crash.txt");
        // Підсумок аудиту пише Audit.ps1; notified.txt — час звіту, про який уже повідомлено або який бачили у вікні аудиту
        readonly string auditSummary = Path.Combine(Program.DataDir, "audit", "summary.ini");
        readonly string auditNotified = Path.Combine(Program.DataDir, "audit", "notified.txt");
        DateTime auditStamp;
        int auditTick;
        Action balloonClick;    // що відкрити на клік по поточному сповіщенню; null — панель «Краші»
        Dashboard dash;
        bool unseenCrash;

        public Theme Theme { get { return Settings.IsDark ? Theme.DarkTheme : Theme.Light; } }

        public TrayApp()
        {
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            Sampler = new Sampler(Settings);
            int traySize = SystemInformation.SmallIconSize.Width;
            icoOk = LoadIcon("DeadPixel.Icon", traySize);
            icoWarn = LoadIcon("DeadPixel.Icon.Warning", traySize);
            icoAlert = LoadIcon("DeadPixel.Icon.Alert", traySize);
            icoApp = LoadIcon("DeadPixel.Icon", 0);

            BuildMenu();
            tray.ContextMenuStrip = menu;
            tray.Icon = icoOk;
            tray.Text = "DEADPIXEL";
            tray.Visible = true;
            tray.DoubleClick += (s, e) => ShowDashboard(null);
            tray.BalloonTipClicked += (s, e) =>
            {
                var a = balloonClick;
                balloonClick = null;
                if (a != null) a(); else ShowDashboard("Краші");
            };

            Settings.Changed += OnSettingsChanged;
            Sampler.Start();
            Events.NewEvent += it => ui.Post(_ => OnLiveEvent(it), null);
            Sampler.Stalls.StallDetected += st => ui.Post(_ =>
            {
                Events.AddExternal(new EvItem { Time = st.Time, Category = "Диск", Source = "DEADPIXEL", Id = 0, Level = 3, Text = st.Text });
                if (Settings.NotifyDisk && st.Seconds >= 10)
                    Notify("stall:" + st.Disk, TimeSpan.FromMinutes(10), string.Format(L.T("Диск не відповідав {0:0} с", "Disk did not respond for {0:0} s"), st.Seconds), st.Text, ToolTipIcon.Warning);
            }, null);

            // Початкове сканування у фоні, щоб трей з'явився одразу
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Events.LoadInitial(7);
                Events.StartWatching();
                var crashes = LoadCrashes();
                ui.Post(__ => OnCrashesLoaded(crashes), null);
            });

            timer.Tick += (s, e) => { UpdateTray(); CheckTemps(); CheckAudit(); };
            timer.Start();
        }

        void BuildMenu()
        {
            menu.Items.Clear();
            var open = menu.Items.Add(L.T("Відкрити панель", "Open dashboard"), null, (s, e) => ShowDashboard(null));
            open.Font = new Font(menu.Font, FontStyle.Bold);
            menu.Items.Add(L.T("Повний звіт (HTML)", "Full report (HTML)"), null, (s, e) => RunFullReport());
            menu.Items.Add(L.T("Папка чорної скриньки", "Black box folder"), null, (s, e) => Open(Program.DataDir));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L.T("Аудит системи…", "System audit…"), null, (s, e) => RunModule(@"audit\AuditGui.exe"));
            menu.Items.Add(L.T("Сетап ПК (рецепти)…", "PC setup (recipes)…"), null, (s, e) => RunModule(@"setup\SetupGui.exe"));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L.T("Налаштування…", "Settings…"), null, (s, e) => ShowDashboard("Налаштування"));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L.T("Вихід", "Exit"), null, (s, e) => ExitThread());
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
            try { pattern = PatternAnalyzer.Build(crashes, changes); } catch (Exception ex) { pattern = L.T("Помилка аналізу: ", "Analysis error: ") + ex.Message; }
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
                        if (c.LastFg != "") txt += L.T("\nОстання активна програма: ", "\nLast active app: ") + c.LastFg;
                        if (fresh.Count > 1) txt += string.Format(L.T("\nНових крашів: {0}", "\nNew crashes: {0}"), fresh.Count);
                        balloonClick = null;
                        tray.ShowBalloonTip(15000, L.T("Комп'ютер перезавантажився через збій", "The PC restarted after a crash"), txt + L.T("\nНатисніть, щоб подивитися деталі.", "\nClick to see the details."), ToolTipIcon.Error);
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
            balloonClick = null;
            tray.ShowBalloonTip(10000, title, text.Length > 200 ? text.Substring(0, 200) + "…" : text, icon);
        }

        // Аудит за розкладом працює окремим процесом; трей раз на хвилину дивиться лише дату summary.ini
        // і повідомляє про нові серйозні проблеми (критичні й високі), яких ще не бачили
        void CheckAudit()
        {
            if (++auditTick < 12) return;
            auditTick = 0;
            DateTime stamp;
            try
            {
                if (!File.Exists(auditSummary)) return;
                stamp = File.GetLastWriteTimeUtc(auditSummary);
            }
            catch { return; }
            if (stamp == auditStamp) return;
            auditStamp = stamp;
            if (!Settings.NotifyAudit) return;

            var kv = new Dictionary<string, string>();
            try
            {
                foreach (var line in File.ReadAllLines(auditSummary))
                {
                    int i = line.IndexOf('=');
                    if (i > 0) kv[line.Substring(0, i)] = line.Substring(i + 1).Trim();
                }
            }
            catch { return; }
            string time, id, title, value, count;
            int alerts;
            kv.TryGetValue("Time", out time);
            kv.TryGetValue("AlertId", out id);
            kv.TryGetValue("AlertTitle", out title);
            kv.TryGetValue("AlertValue", out value);
            kv.TryGetValue("Alerts", out count);
            if (!int.TryParse(count, out alerts) || alerts == 0 || string.IsNullOrEmpty(time)) return;
            string seen = "";
            try { if (File.Exists(auditNotified)) seen = File.ReadAllText(auditNotified).Trim(); } catch { }
            if (seen == time) return;
            try { File.WriteAllText(auditNotified, time); } catch { }

            balloonClick = () => RunModule(@"audit\AuditGui.exe", "--check \"" + id + "\"");
            var text = (title ?? "") + (string.IsNullOrEmpty(value) ? "" : ": " + value);
            if (alerts > 1) text += L.T("\nІ ще: ", "\nAnd more: ") + (alerts - 1);
            tray.ShowBalloonTip(15000, alerts == 1 ? L.T("Аудит системи: нова серйозна проблема", "System audit: new serious finding") : L.T("Аудит системи: нових серйозних проблем — ", "System audit: new serious findings — ") + alerts,
                text + L.T("\nНатисніть, щоб побачити пояснення і що зробити.", "\nClick to see the explanation and what to do."), ToolTipIcon.Warning);
        }

        void OnLiveEvent(EvItem it)
        {
            UpdateTray();
            if (!Allowed(it.Category)) return;
            var cooldown = it.Category == "GPU" || it.Category == "WHEA" ? TimeSpan.FromMinutes(1) : TimeSpan.FromMinutes(30);
            string title = it.Category == "GPU" ? L.T("Проблема з відеодрайвером", "Graphics driver problem") : it.Category == "WHEA" ? L.T("Апаратна помилка (WHEA)", "Hardware error (WHEA)") :
                           it.Category == "USB" ? L.T("Збій USB", "USB failure") : it.Category == "Програма" ? L.T("Програма впала", "An application crashed") :
                           it.Category == "CPU" ? L.T("Процесор обмежено", "CPU throttled") : L.T("Помилка диска", "Disk error");
            Notify("ev:" + it.Category, cooldown, title, it.Text, it.Category == "Диск" || it.Category == "Програма" ? ToolTipIcon.Warning : ToolTipIcon.Error);
        }

        void CheckTemps()
        {
            var s = Sampler.Last;
            if (s == null || !Settings.NotifyTemp) return;
            if (!double.IsNaN(s.GpuTemp) && s.GpuTemp >= Settings.GpuTempWarn)
                Notify("temp:gpu", TimeSpan.FromMinutes(10), L.T("Висока температура GPU", "High GPU temperature"), string.Format(L.T("{0:0} °C (поріг {1} °C)", "{0:0} °C (threshold {1} °C)"), s.GpuTemp, Settings.GpuTempWarn), ToolTipIcon.Warning);
            if (!double.IsNaN(s.CpuTemp) && s.CpuTemp >= Settings.CpuTempWarn)
                Notify("temp:cpu", TimeSpan.FromMinutes(10), L.T("Висока температура CPU", "High CPU temperature"), string.Format(L.T("{0:0} °C (поріг {1} °C)", "{0:0} °C (threshold {1} °C)"), s.CpuTemp, Settings.CpuTempWarn), ToolTipIcon.Warning);
            if (Sampler.ReasonsCritical(s.Reasons))
                Notify("gpu:slowdown", TimeSpan.FromMinutes(10), L.T("GPU примусово сповільнено", "GPU forcibly slowed down"), Sampler.DecodeReasons(s.Reasons) + L.T(" — можлива проблема з живленням або перегрів.", " — possible power delivery problem or overheating."), ToolTipIcon.Warning);
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
            if (unseenCrash) tip += L.T("\nНовий краш!", "\nNew crash!");
            else if (recent) tip += L.T("\nЗбої GPU за 24 год", "\nGPU failures in 24 h");
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip; // .NET Framework обмежує підказку 63 символами
        }

        public void MarkCrashesSeen()
        {
            if (Crashes.Count > 0) WriteSeen(Crashes.Max(c => c.Boot));
            unseenCrash = false;
            UpdateTray();
        }

        // Без окремого потоку: очікування бере на себе пул потоків
        public void ListenForShow(EventWaitHandle signal)
        {
            ThreadPool.RegisterWaitForSingleObject(signal, (st, timedOut) => ui.Post(_ => ShowDashboard(null), null), null, Timeout.Infinite, false);
        }

        public void ShowDashboard(string page)
        {
            if (dash == null || dash.IsDisposed)
            {
                dash = new Dashboard(this);
                dash.FormClosed += (s, e) => ui.Post(_ => TrimMemory(), null);
            }
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
            else MessageBox.Show(L.T("Не знайдено ", "Not found: ") + cmd, "DEADPIXEL");
        }

        // Модулі (modules\) — окремі процеси на вимогу: трей їх лише запускає і нічого не тримає в пам'яті
        public static void RunModule(string relPath) { RunModule(relPath, ""); }

        public static void RunModule(string relPath, string args)
        {
            var path = Path.Combine(Program.BaseDir, "modules", relPath);
            if (!File.Exists(path)) { MessageBox.Show(L.T("Не знайдено модуль ", "Module not found: ") + path, "DEADPIXEL"); return; }
            try { Process.Start(new ProcessStartInfo(path, args) { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "DEADPIXEL"); }
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

        // Після закриття панелі повертаємо пам'ять системі: у фоні трей живе лише зі збором даних
        static void TrimMemory()
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            using (var self = Process.GetCurrentProcess()) Native.EmptyWorkingSet(self.Handle);
        }

        // size = 0 — усі кадри: вікно саме бере 16/20/24 для заголовка і 32/48 для панелі задач
        static Icon LoadIcon(string resource, int size)
        {
            using (var stream = typeof(TrayApp).Assembly.GetManifestResourceStream(resource))
            using (var icon = size > 0 ? new Icon(stream, size, size) : new Icon(stream))
            {
                return (Icon)icon.Clone();
            }
        }

        public Icon AppIcon { get { return icoApp; } }

        // Перезапуск (зміна мови): нова копія чекає, доки ця завершиться й звільнить mutex
        public void Restart()
        {
            try { Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--wait-pid " + Process.GetCurrentProcess().Id + " --show")); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "DEADPIXEL"); return; }
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            tray.Visible = false;
            Sampler.Stop();
            if (dash != null && !dash.IsDisposed) dash.Close();
            tray.Dispose();
            icoOk.Dispose();
            icoWarn.Dispose();
            icoAlert.Dispose();
            icoApp.Dispose();
            base.ExitThreadCore();
        }
    }
}
