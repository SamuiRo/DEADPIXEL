using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace DeadPixel
{
    class Dashboard : Form
    {
        readonly TrayApp app;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Dictionary<string, Label> tiles = new Dictionary<string, Label>();
        readonly Label header = new Label { Dock = DockStyle.Top, Height = 28, Padding = new Padding(12, 8, 12, 0), Tag = "muted" };
        readonly Chart gpuChart, cpuChart;
        readonly Panel content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10, 0, 10, 0) };
        readonly FlowLayoutPanel tabBar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 36, Padding = new Padding(10, 4, 10, 0), WrapContents = false };
        readonly Dictionary<string, Control> pages = new Dictionary<string, Control>();
        readonly Dictionary<string, Button> tabButtons = new Dictionary<string, Button>();
        string currentPage;

        readonly ListView crashList, eventList, procList;
        readonly TextBox crashDetail = MakeText(false);
        readonly TextBox patternText = MakeText(true);
        readonly ListView changeList;
        readonly TimelineChart timeline;
        readonly Button btnAnalyzeMini = Btn("Аналізувати дамп BSOD", null), btnAnalyzeLkr = Btn("Аналізувати дамп TDR", null),
                        btnFullOutput = Btn("Повний вивід аналізу", null), btnInstallDbg = Btn("Встановити WinDbg…", null);
        readonly Label analyzeStatus = new Label { AutoSize = true, Padding = new Padding(4, 6, 0, 0), Tag = "warn" };
        bool waitCdb;
        readonly TextBox sysInfo = MakeText(true);
        readonly ComboBox eventFilter = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
        readonly ProcSampler procSampler = new ProcSampler();
        ListView diskList;
        DiskChart diskChart;
        readonly TextBox diskSummary = MakeText(true);
        readonly ComboBox diskRange = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 110 };
        readonly Label diskStatus = new Label { AutoSize = true, Padding = new Padding(6, 6, 0, 0), Tag = "warn" };
        bool diskLoading;
        DateTime diskLoaded = DateTime.MinValue;
        int shownVersion = -1, procSort = 2, tickCount;
        bool loadingSettings;

        public Dashboard(TrayApp app)
        {
            this.app = app;
            Text = "DEADPIXEL";
            Font = new Font("Segoe UI", 9f);
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            Size = new Size(1240, Math.Min(960, Screen.PrimaryScreen.WorkingArea.Height - 40));
            MinimumSize = new Size(900, 600);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = app.AppIcon;

            crashList = MakeList("Момент збою", 125, "Код", 60, "Що сталося", 200, "Драйвер", 100, "Стан GPU", 95, "Закрито перед збоєм", 190, "Активна програма", 150);
            eventList = MakeList("Час", 130, "Категорія", 75, "Джерело", 170, "ID", 45, "Опис", 760);
            procList = MakeList("Процес", 260, "PID", 70, "CPU %", 80, "RAM, МБ", 100);
            changeList = MakeList("Час", 130, "Тип", 150, "Що змінилося", 800);
            timeline = new TimelineChart(() => app.Theme) { Dock = DockStyle.Top, Height = 175 };

            // ---- плитки
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(8, 2, 8, 4), WrapContents = true };
            flow.Controls.Add(GroupLabel("GPU"));
            Control last = null;
            foreach (var n in new[] { "Температура GPU", "Споживання", "Частота GPU", "Частота VRAM", "P-state", "PCIe", "Завант. GPU", "VRAM", "Вентилятор", "Обмеження GPU" })
                flow.Controls.Add(last = MakeTile(n, n == "Обмеження GPU" ? 150 : 104));
            flow.SetFlowBreak(last, true);
            flow.Controls.Add(GroupLabel("CPU"));
            foreach (var n in new[] { "Завант. CPU", "Макс. ядро", "Частота CPU", "Температура CPU", "RAM", "Активна програма" })
                flow.Controls.Add(MakeTile(n, n == "Активна програма" ? 200 : n == "RAM" ? 140 : 104));

            // ---- графіки
            gpuChart = new Chart("GPU", () => app.Theme, app.Sampler.Snapshot, new[]
            {
                new ChartSeries("Темп.", Color.FromArgb(245, 124, 40), s => s.GpuTemp, 100, "°C"),
                new ChartSeries("Потужн.", Color.FromArgb(59, 130, 246), s => s.GpuPower, 350, "W"),
                new ChartSeries("Частота", Color.FromArgb(34, 170, 90), s => s.GpuClock, 3300, "MHz"),
                new ChartSeries("Завант.", Color.FromArgb(150, 150, 160), s => s.GpuUtil, 100, "%"),
            }) { Dock = DockStyle.Fill };
            cpuChart = new Chart("CPU", () => app.Theme, app.Sampler.Snapshot, new[]
            {
                new ChartSeries("Завант.", Color.FromArgb(168, 85, 247), s => s.CpuPct, 100, "%"),
                new ChartSeries("Ядро max", Color.FromArgb(236, 72, 153), s => s.CpuMaxCore, 100, "%"),
                new ChartSeries("Частота", Color.FromArgb(20, 184, 166), s => s.CpuMhz, 6000, "MHz"),
                new ChartSeries("Темп.", Color.FromArgb(245, 124, 40), s => s.CpuTemp, 100, "°C"),
                new ChartSeries("RAM", Color.FromArgb(150, 150, 160), s => s.RamPct, 100, "%"),
            }) { Dock = DockStyle.Fill };
            var charts = new TableLayoutPanel { Dock = DockStyle.Top, Height = 150, ColumnCount = 2, Padding = new Padding(10, 0, 10, 4) };
            charts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            charts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            gpuChart.Margin = new Padding(0, 0, 4, 0);
            cpuChart.Margin = new Padding(4, 0, 0, 0);
            charts.Controls.Add(gpuChart, 0, 0);
            charts.Controls.Add(cpuChart, 1, 0);

            // ---- сторінки
            AddPage("Краші", BuildCrashPage());
            AddPage("Аналіз", patternText);
            AddPage("Зміни", changeList);
            AddPage("Події", BuildEventPage());
            AddPage("Диски", BuildDiskPage());
            AddPage("Процеси", procList);
            AddPage("Система", sysInfo);
            AddPage("Налаштування", BuildSettingsPage());

            // ---- кнопки
            var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(10, 6, 10, 6) };
            bottom.Controls.Add(Btn("Повний звіт (HTML)", (s, e) => app.RunFullReport()));
            bottom.Controls.Add(Btn("Чорна скринька (CSV)", (s, e) => TrayApp.Open(Program.DataDir)));
            bottom.Controls.Add(Btn("Папка дампів", (s, e) => TrayApp.Open(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Minidump"))));
            bottom.Controls.Add(Btn("Оновити краші", (s, e) => ReloadCrashesFromDisk()));
            Button pack = null;
            pack = Btn("Зібрати пакет для діагностики", (s, e) => BuildPack(pack));
            bottom.Controls.Add(pack);

            Controls.Add(content);
            Controls.Add(tabBar);
            Controls.Add(charts);
            Controls.Add(flow);
            Controls.Add(header);
            Controls.Add(bottom);

            SelectPage("Краші");
            timer.Interval = 1000;
            timer.Tick += (s, e) => Tick();
            timer.Start();
            FormClosed += (s, e) => { timer.Stop(); timer.Dispose(); };
            Load += (s, e) => { ApplyTheme(); ReloadCrashes(); Tick(); };

            sysInfo.Text = "Збираю інформацію…";
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var text = SystemInfo.Build(app);
                try { BeginInvoke(new Action(() => sysInfo.Text = text)); } catch { }
            });
        }

        // ================================================================ побудова
        static TextBox MakeText(bool wrap)
        {
            return new TextBox { Multiline = true, ReadOnly = true, ScrollBars = wrap ? ScrollBars.Vertical : ScrollBars.Both, WordWrap = wrap, Dock = DockStyle.Fill, Font = new Font("Consolas", 9.5f), BorderStyle = BorderStyle.None };
        }

        ListView MakeList(params object[] cols)
        {
            var lv = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, BorderStyle = BorderStyle.None };
            for (int i = 0; i < cols.Length; i += 2) lv.Columns.Add((string)cols[i], (int)cols[i + 1]);
            Theme.OwnerDrawHeaders(lv, () => app.Theme);
            // остання колонка розтягується на всю ширину — інакше справа лишається світла смуга заголовка
            lv.Resize += (s, e) =>
            {
                if (lv.Columns.Count == 0) return;
                int used = 0;
                for (int i = 0; i < lv.Columns.Count - 1; i++) used += lv.Columns[i].Width;
                var lastCol = lv.Columns[lv.Columns.Count - 1];
                int w = Math.Max(lastCol.Tag is int ? (int)lastCol.Tag : lastCol.Width, lv.ClientSize.Width - used);
                if (lastCol.Tag == null) lastCol.Tag = lastCol.Width;
                if (lastCol.Width != w) lastCol.Width = w;
            };
            return lv;
        }

        static Label GroupLabel(string text)
        {
            return new Label { Text = text, Width = 40, Height = 52, TextAlign = ContentAlignment.MiddleLeft, Font = new Font("Segoe UI Semibold", 10f), Tag = "accent", Margin = new Padding(3, 4, 0, 4) };
        }

        Control MakeTile(string name, int width)
        {
            var p = new Panel { Width = width, Height = 52, Margin = new Padding(3, 4, 3, 4), Tag = "surface" };
            p.Controls.Add(new Label { Text = name, Left = 8, Top = 5, AutoSize = true, Font = new Font("Segoe UI", 8f), Tag = "muted" });
            var v = new Label { Text = "—", Left = 7, Top = 21, Width = width - 12, Height = 26, Font = new Font("Segoe UI Semibold", 12.5f), AutoEllipsis = true };
            p.Controls.Add(v);
            tiles[name] = v;
            return p;
        }

        static Button Btn(string text, EventHandler h)
        {
            var b = new Button { Text = text, AutoSize = true, Padding = new Padding(8, 2, 8, 2), Margin = new Padding(0, 0, 8, 0) };
            b.Click += h;
            return b;
        }

        void AddPage(string name, Control page)
        {
            page.Dock = DockStyle.Fill;
            page.Visible = false;
            pages[name] = page;
            content.Controls.Add(page);
            var b = new Button { Text = name, AutoSize = true, Height = 30, Padding = new Padding(10, 0, 10, 0), Margin = new Padding(0, 0, 2, 0), Tag = "tab" };
            b.Click += (s, e) => SelectPage(name);
            tabButtons[name] = b;
            tabBar.Controls.Add(b);
        }

        public void SelectPage(string name)
        {
            if (!pages.ContainsKey(name)) return;
            currentPage = name;
            foreach (var kv in pages) kv.Value.Visible = kv.Key == name;
            foreach (var kv in tabButtons) kv.Value.Tag = kv.Key == name ? "tab-selected" : "tab";
            if (IsHandleCreated) { foreach (var b in tabButtons.Values) app.Theme.Apply(b); app.Theme.Apply(pages[name]); }
            if (name == "Процеси") RefreshProcesses();
            if (name == "Диски") RefreshDisks();
        }

        Control BuildCrashPage()
        {
            var split = new SplitContainer { Orientation = Orientation.Horizontal, FixedPanel = FixedPanel.Panel1, SplitterWidth = 6 };
            split.Panel1.Controls.Add(crashList);
            var actions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 4, 0, 4) };
            btnAnalyzeMini.Click += (s, e) => StartAnalysis(btnAnalyzeMini);
            btnAnalyzeLkr.Click += (s, e) => StartAnalysis(btnAnalyzeLkr);
            btnFullOutput.Click += (s, e) => OpenFullOutput();
            btnInstallDbg.Click += (s, e) => { DumpAnalyzer.InstallWinDbg(); waitCdb = true; };
            actions.Controls.AddRange(new Control[] { btnAnalyzeMini, btnAnalyzeLkr, btnFullOutput, btnInstallDbg, analyzeStatus });
            split.Panel2.Controls.Add(crashDetail);
            split.Panel2.Controls.Add(actions);
            split.Panel2.Controls.Add(timeline);
            crashDetail.Font = new Font("Consolas", 9f);
            Load += (s, e) => { try { split.SplitterDistance = Math.Min(122, split.Height / 3); } catch { } };
            crashList.SelectedIndexChanged += (s, e) => ShowCrashDetail();
            return split;
        }

        Control BuildEventPage()
        {
            var panel = new Panel();
            var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 34, Padding = new Padding(0, 4, 0, 0) };
            top.Controls.Add(new Label { Text = "Показати:", AutoSize = true, Padding = new Padding(0, 5, 4, 0) });
            eventFilter.Items.AddRange(new object[] { "Усі", "GPU", "CPU", "WHEA", "Диск", "USB", "Програма" });
            eventFilter.SelectedIndex = 0;
            eventFilter.SelectedIndexChanged += (s, e) => { shownVersion = -1; RefreshEvents(); };
            top.Controls.Add(eventFilter);
            panel.Controls.Add(eventList);
            panel.Controls.Add(top);
            procList.ColumnClick += (s, e) => { procSort = e.Column; RefreshProcesses(); };
            return panel;
        }

        // ================================================================ налаштування
        Control BuildSettingsPage()
        {
            var scroll = new Panel { AutoScroll = true };
            var t = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(4, 8, 4, 8), Location = new Point(0, 0) };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 300));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var s = app.Settings;
            loadingSettings = true;

            Heading(t, "Загальні");
            var autostart = Check(t, "Запускати разом із Windows", s.Autostart, v => { s.Autostart = v; });
            Check(t, "Відкривати панель під час запуску", s.ShowOnStart, v => { s.ShowOnStart = v; s.Save(); });
            Combo(t, "Тема", new[] { "Системна", "Світла", "Темна" }, new[] { "system", "light", "dark" }, s.Theme, v => { s.Theme = v; s.Save(); });

            Heading(t, "Запис чорної скриньки");
            Combo(t, "Інтервал запису", new[] { "1 с", "2 с", "5 с", "10 с" }, new[] { "1", "2", "5", "10" }, s.IntervalSec.ToString(),
                  v => { s.IntervalSec = int.Parse(v); s.Save(); app.Sampler.IntervalChanged(); });
            Number(t, "Зберігати файли, днів", s.RetentionDays, 1, 90, v => { s.RetentionDays = v; s.Save(); app.Sampler.Cleanup(); });

            Heading(t, "Сповіщення");
            Check(t, "Краш / аварійне перезавантаження", s.NotifyCrash, v => { s.NotifyCrash = v; s.Save(); });
            Check(t, "Збої відеодрайвера (TDR)", s.NotifyGpu, v => { s.NotifyGpu = v; s.Save(); });
            Check(t, "Апаратні помилки WHEA / обмеження CPU", s.NotifyWhea, v => { s.NotifyWhea = v; s.Save(); });
            Check(t, "Помилки дисків", s.NotifyDisk, v => { s.NotifyDisk = v; s.Save(); });
            Check(t, "Збої USB", s.NotifyUsb, v => { s.NotifyUsb = v; s.Save(); });
            Check(t, "Падіння програм", s.NotifyApp, v => { s.NotifyApp = v; s.Save(); });
            Check(t, "Висока температура / сповільнення GPU", s.NotifyTemp, v => { s.NotifyTemp = v; s.Save(); });
            Number(t, "Поріг температури GPU, °C", s.GpuTempWarn, 50, 110, v => { s.GpuTempWarn = v; s.Save(); });
            Number(t, "Поріг температури CPU, °C", s.CpuTempWarn, 50, 110, v => { s.CpuTempWarn = v; s.Save(); });

            Heading(t, "Температура CPU");
            var info = new Label { AutoSize = true, MaximumSize = new Size(700, 0), Tag = "muted", Margin = new Padding(3, 4, 3, 4),
                Text = "Windows не надає температуру процесора Ryzen без спеціального драйвера. DEADPIXEL автоматично підхоплює її з LibreHardwareMonitor, якщо той запущений (від адміністратора, можна згорнути в трей)." };
            t.Controls.Add(info);
            t.SetColumnSpan(info, 2);
            var status = new Label { AutoSize = true, Margin = new Padding(3, 4, 3, 4), Tag = "warn" };
            t.Controls.Add(status);
            t.SetColumnSpan(status, 2);
            var link = new LinkLabel { Text = "Завантажити LibreHardwareMonitor (GitHub)", AutoSize = true, Margin = new Padding(3, 2, 3, 8) };
            link.LinkClicked += (o, e) => TrayApp.Open("https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases");
            t.Controls.Add(link);
            t.SetColumnSpan(link, 2);
            timer.Tick += (o, e) =>
            {
                var st = "Стан: " + app.Sampler.CpuTemp.Status;
                if (status.Text != st) status.Text = st;
                if (autostart.Checked != s.Autostart) { loadingSettings = true; autostart.Checked = s.Autostart; loadingSettings = false; }
            };

            Heading(t, "Дані");
            var dataBtn = Btn("Відкрити папку даних", (o, e) => TrayApp.Open(Program.DataDir));
            t.Controls.Add(dataBtn);
            t.SetColumnSpan(dataBtn, 2);

            loadingSettings = false;
            scroll.Controls.Add(t);
            return scroll;
        }

        static void Heading(TableLayoutPanel t, string text)
        {
            var l = new Label { Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 11f), Tag = "accent", Margin = new Padding(3, 14, 3, 4) };
            t.Controls.Add(l);
            t.SetColumnSpan(l, 2);
        }

        CheckBox Check(TableLayoutPanel t, string text, bool value, Action<bool> set)
        {
            var c = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(3, 3, 3, 3) };
            c.CheckedChanged += (s, e) => { if (!loadingSettings) set(c.Checked); };
            t.Controls.Add(c);
            t.SetColumnSpan(c, 2);
            return c;
        }

        void Combo(TableLayoutPanel t, string label, string[] items, string[] values, string current, Action<string> set)
        {
            t.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new Padding(3, 7, 3, 3) });
            var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
            c.Items.AddRange(items);
            c.SelectedIndex = Math.Max(0, Array.IndexOf(values, current));
            c.SelectedIndexChanged += (s, e) => { if (!loadingSettings) set(values[c.SelectedIndex]); };
            t.Controls.Add(c);
        }

        void Number(TableLayoutPanel t, string label, int value, int min, int max, Action<int> set)
        {
            t.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new Padding(3, 7, 3, 3) });
            var n = new NumericUpDown { Minimum = min, Maximum = max, Value = Math.Max(min, Math.Min(max, value)), Width = 80, BorderStyle = BorderStyle.FixedSingle };
            n.ValueChanged += (s, e) => { if (!loadingSettings) set((int)n.Value); };
            t.Controls.Add(n);
        }

        // ================================================================ тема
        public void ApplyTheme()
        {
            var t = app.Theme;
            t.Apply(this);
            t.ApplyTitleBar(this);
            shownVersion = -1;
            RefreshEvents();
            ReloadCrashes();
            Invalidate(true);
        }

        // ================================================================ оновлення
        static string F(double v, string fmt) { return double.IsNaN(v) ? "—" : v.ToString(fmt, CultureInfo.InvariantCulture); }

        void Tick()
        {
            tickCount++;
            var t = app.Theme;
            var sm = app.Sampler;
            var s = sm.Last;
            var up = TimeSpan.FromMilliseconds(Native.GetTickCount64());
            header.Text = string.Format("{0} · драйвер {1} · аптайм {2} год {3} хв · чорна скринька: {4}", sm.GpuName, sm.Driver, (int)up.TotalHours, up.Minutes, sm.Status);
            if (s != null)
            {
                SetTile("Температура GPU", F(s.GpuTemp, "0") + " °C", s.GpuTemp >= app.Settings.GpuTempWarn ? t.Danger : t.Fg);
                SetTile("Споживання", F(s.GpuPower, "0") + " W", t.Fg);
                SetTile("Частота GPU", F(s.GpuClock, "0") + " MHz", t.Fg);
                SetTile("Частота VRAM", F(s.MemClock, "0") + " MHz", t.Fg);
                SetTile("P-state", s.PState == "" ? "—" : s.PState, t.Fg);
                SetTile("PCIe", s.PcieGen == "" ? "—" : "Gen " + s.PcieGen, t.Fg);
                SetTile("Завант. GPU", F(s.GpuUtil, "0") + " %", t.Fg);
                SetTile("VRAM", F(s.VramMb / 1024, "0.0") + " GB", t.Fg);
                SetTile("Вентилятор", F(s.Fan, "0") + " %", t.Fg);
                SetTile("Обмеження GPU", Sampler.DecodeReasons(s.Reasons), Sampler.ReasonsCritical(s.Reasons) ? t.Danger : t.Fg);
                SetTile("Завант. CPU", F(s.CpuPct, "0") + " %", t.Fg);
                SetTile("Макс. ядро", F(s.CpuMaxCore, "0") + " %", t.Fg);
                SetTile("Частота CPU", F(s.CpuMhz, "0") + " MHz", t.Fg);
                SetTile("Температура CPU", double.IsNaN(s.CpuTemp) ? "н/д" : F(s.CpuTemp, "0") + " °C", s.CpuTemp >= app.Settings.CpuTempWarn ? t.Danger : t.Fg);
                SetTile("RAM", F(s.RamUsedGb, "0.0") + " / " + F(s.RamTotalGb, "0") + " GB", s.RamPct >= 90 ? t.Danger : t.Fg);
                SetTile("Активна програма", s.Fg == "" ? "—" : s.Fg, t.Fg);
            }
            gpuChart.Invalidate();
            cpuChart.Invalidate();
            RefreshEvents();
            if (currentPage == "Процеси" && tickCount % 3 == 0) RefreshProcesses();
            if (currentPage == "Диски")
            {
                var live = app.Sampler.Stalls.Live;
                diskStatus.Text = live != "" ? "ЗАРАЗ: " + live : DiskStatusText();
                if ((DateTime.Now - diskLoaded).TotalSeconds > 30) RefreshDisks();
            }
            if (tickCount % 3 == 0) CheckPending();
            if (waitCdb && tickCount % 10 == 0)
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    if (DumpAnalyzer.FindCdb(true) == null) return;
                    waitCdb = false;
                    try { BeginInvoke(new Action(UpdateAnalyzeButtons)); } catch { }
                });
        }

        void SetTile(string name, string text, Color c)
        {
            var l = tiles[name];
            if (l.Text != text) l.Text = text;
            if (l.ForeColor != c) l.ForeColor = c;
        }

        void RefreshEvents()
        {
            if (app.Events.Version == shownVersion) return;
            shownVersion = app.Events.Version;
            var t = app.Theme;
            var f = (string)eventFilter.SelectedItem ?? "Усі";
            List<EvItem> items;
            lock (app.Events.Lock) items = app.Events.Items.Where(e => f == "Усі" || e.Category == f).Take(400).ToList();
            eventList.BeginUpdate();
            eventList.Items.Clear();
            foreach (var e in items)
            {
                var li = new ListViewItem(new[] { e.Time.ToString("yyyy-MM-dd HH:mm:ss"), e.Category, e.Source, e.Id.ToString(), e.Text });
                li.ForeColor = e.Category == "GPU" || e.Category == "WHEA" ? t.Danger : e.Level <= 2 ? t.Warn : t.Fg;
                eventList.Items.Add(li);
            }
            eventList.EndUpdate();
        }

        void RefreshProcesses()
        {
            var rows = procSampler.Sample();
            IEnumerable<ProcSampler.Row> sorted;
            switch (procSort)
            {
                case 0: sorted = rows.OrderBy(r => r.Name); break;
                case 1: sorted = rows.OrderBy(r => r.Pid); break;
                case 3: sorted = rows.OrderByDescending(r => r.RamMb); break;
                default: sorted = rows.OrderByDescending(r => double.IsNaN(r.Cpu) ? -1 : r.Cpu).ThenByDescending(r => r.RamMb); break;
            }
            var t = app.Theme;
            int top = procList.TopItem != null ? procList.TopItem.Index : 0;
            procList.BeginUpdate();
            procList.Items.Clear();
            foreach (var r in sorted.Take(60))
            {
                var li = new ListViewItem(new[] { r.Name, r.Pid.ToString(), double.IsNaN(r.Cpu) ? "—" : r.Cpu.ToString("0.0"), r.RamMb.ToString("0") });
                li.ForeColor = r.Cpu >= 25 ? t.Warn : t.Fg;
                procList.Items.Add(li);
            }
            procList.EndUpdate();
            try { if (top > 0 && top < procList.Items.Count) procList.TopItem = procList.Items[top]; } catch { }
        }

        void ReloadCrashesFromDisk()
        {
            crashDetail.Text = "Сканую краші, історію змін і чорну скриньку…";
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var c = app.LoadCrashes();
                try { BeginInvoke(new Action(() => { app.Crashes = c; ReloadCrashes(); RefreshAnalysisPages(); })); } catch { }
            });
        }

        public void ReloadCrashes()
        {
            var t = app.Theme;
            int sel = crashList.SelectedIndices.Count > 0 ? crashList.SelectedIndices[0] : 0;
            crashList.BeginUpdate();
            crashList.Items.Clear();
            foreach (var c in app.Crashes.OrderByDescending(x => x.Boot))
            {
                var bc = BugChecks.Get(c.Code);
                var idle = CrashAnalyzer.WasIdle(c);
                var li = new ListViewItem(new[]
                {
                    c.Moment.ToString("yyyy-MM-dd HH:mm"), c.Code == 0 ? "—" : "0x" + c.Code.ToString("X"), bc[0], c.Driver,
                    idle == true ? "простій" : idle == false ? "навантаження" : "—",
                    c.LastExit != null ? c.LastExit.Name + " (" + CrashAnalyzer.Ago(c.Moment - c.LastExit.Time) + " до)" : "",
                    c.LastFg
                }) { Tag = c };
                li.ForeColor = CrashAnalyzer.IsGpuCrash(c) ? t.Danger : t.Fg;
                crashList.Items.Add(li);
            }
            crashList.EndUpdate();
            if (crashList.Items.Count > 0) crashList.Items[Math.Min(sel, crashList.Items.Count - 1)].Selected = true;
            else crashDetail.Text = "За останні 90 днів аварійних перезавантажень не знайдено.";
            RefreshAnalysisPages();
        }

        CrashInfo SelectedCrash { get { return crashList.SelectedItems.Count == 0 ? null : (CrashInfo)crashList.SelectedItems[0].Tag; } }

        void ShowCrashDetail()
        {
            var c = SelectedCrash;
            if (c == null) return;
            timeline.SetCrash(c);
            crashDetail.Text = CrashAnalyzer.Describe(c);
            UpdateAnalyzeButtons();
        }

        // ---- аналіз дампу
        void UpdateAnalyzeButtons()
        {
            var c = SelectedCrash;
            bool hasCdb = DumpAnalyzer.FindCdb(false) != null;
            SetupAnalyzeButton(btnAnalyzeMini, c == null ? "" : c.Dump, "Аналізувати дамп BSOD", hasCdb);
            SetupAnalyzeButton(btnAnalyzeLkr, c == null ? "" : c.LkrDump, "Аналізувати дамп TDR", hasCdb);
            string status = "";
            if (!hasCdb) status = "Для аналізу дампів потрібен WinDbg від Microsoft (безкоштовно, ~100 МБ).";
            else if (c != null && (DumpAnalyzer.IsPending(c.Dump) || DumpAnalyzer.IsPending(c.LkrDump)))
                status = "Аналіз триває… Перший раз може зайняти кілька хвилин (завантажуються символи Microsoft).";
            else if (c != null && c.Dump != "" && !DumpAnalyzer.CanRead(c.Dump)) status = "Дамп BSOD доступний лише адміністратору — Windows попросить дозвіл (UAC).";
            analyzeStatus.Text = status;
            btnInstallDbg.Visible = !hasCdb;
            btnFullOutput.Enabled = c != null && (DumpAnalyzer.Load(c.Dump) != null || DumpAnalyzer.Load(c.LkrDump) != null);
        }

        static void SetupAnalyzeButton(Button b, string dump, string text, bool hasCdb)
        {
            b.Tag = dump;
            bool done = dump != "" && File.Exists(DumpAnalyzer.ResultPath(dump));
            b.Text = done ? text.Replace("Аналізувати", "Повторити аналіз:").Replace(": дамп", ":") : text;
            b.Enabled = hasCdb && dump != "" && !DumpAnalyzer.IsPending(dump);
        }

        void StartAnalysis(Button b)
        {
            var dump = b.Tag as string;
            if (string.IsNullOrEmpty(dump)) return;
            try { File.Delete(DumpAnalyzer.ResultPath(dump)); } catch { }
            var err = DumpAnalyzer.Start(dump);
            if (err != null) analyzeStatus.Text = "Не вдалося запустити аналіз: " + err;
            else UpdateAnalyzeButtons();
            pendingCheck = true;
        }

        bool pendingCheck;
        void CheckPending()
        {
            if (!pendingCheck) return;
            var c = SelectedCrash;
            bool any = app.Crashes.Any(x => DumpAnalyzer.IsPending(x.Dump) || DumpAnalyzer.IsPending(x.LkrDump));
            if (!any) { pendingCheck = false; ShowCrashDetail(); }
        }

        void OpenFullOutput()
        {
            var c = SelectedCrash;
            if (c == null) return;
            foreach (var d in new[] { c.Dump, c.LkrDump })
                if (d != "" && File.Exists(DumpAnalyzer.ResultPath(d))) TrayApp.Open(DumpAnalyzer.ResultPath(d));
        }

        // ---- диски
        Control BuildDiskPage()
        {
            diskList = MakeList("Диск", 115, "Модель", 175, "Тип", 85, "Розмір", 70, "Стан", 70, "°C", 40, "Наробіток", 75,
                                "Перепризн.", 75, "Нестаб.", 60, "CRC", 45, "Зупинок", 65, "Паркувань", 80, "Знос", 50, "Серійний", 150);
            diskList.Dock = DockStyle.Top;
            diskList.Height = 120;
            diskChart = new DiskChart(() => app.Theme) { Dock = DockStyle.Top, Height = 230 };
            var bar = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 4, 0, 4) };
            var smartBtn = Btn("Оновити SMART (потрібен дозвіл адміністратора)", null);
            smartBtn.Click += (s, e) =>
            {
                smartBtn.Enabled = false;
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    var err = DiskMonitor.RefreshSmartElevated();
                    try { BeginInvoke(new Action(() => { smartBtn.Enabled = true; if (err != null) diskStatus.Text = "SMART не оновлено: " + err; diskLoaded = DateTime.MinValue; RefreshDisks(); })); } catch { }
                });
            };
            bar.Controls.Add(smartBtn);
            bar.Controls.Add(new Label { Text = "Період:", AutoSize = true, Padding = new Padding(8, 6, 0, 0) });
            diskRange.Items.AddRange(new object[] { "24 години", "7 днів", "14 днів", "30 днів" });
            diskRange.SelectedIndex = 1;
            diskRange.SelectedIndexChanged += (s, e) => { diskLoaded = DateTime.MinValue; RefreshDisks(); };
            bar.Controls.Add(diskRange);
            bar.Controls.Add(diskStatus);
            var panel = new Panel();
            panel.Controls.Add(diskSummary);
            panel.Controls.Add(diskChart);
            panel.Controls.Add(bar);
            panel.Controls.Add(diskList);
            return panel;
        }

        int DiskDays { get { return new[] { 1, 7, 14, 30 }[Math.Max(0, diskRange.SelectedIndex)]; } }

        static string DiskStatusText()
        {
            var t = DiskMonitor.SmartTime;
            return t == DateTime.MinValue ? "SMART ще не зчитувався." : "SMART зчитано " + t.ToString("yyyy-MM-dd HH:mm") + ".";
        }

        void RefreshDisks()
        {
            if (diskLoading) return;
            diskLoading = true;
            diskLoaded = DateTime.Now;
            int days = DiskDays;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                List<DiskInfo> disks = null; List<DiskEvent> events = null; string summary = "";
                try
                {
                    disks = DiskMonitor.Inventory();
                    events = DiskMonitor.LoadEvents(days, disks);
                    events.AddRange(StallDetector.ReadStalls(DateTime.Now.AddDays(-days), DateTime.Now));
                    events = events.OrderBy(e => e.Time).ToList();
                    DiskMonitor.AssignLanes(events, disks);
                    summary = DiskMonitor.Summary(disks, events, days);
                }
                catch (Exception ex) { summary = "Помилка: " + ex.Message; }
                try { BeginInvoke(new Action(() => { diskLoading = false; ShowDisks(disks ?? new List<DiskInfo>(), events ?? new List<DiskEvent>(), summary, days); })); }
                catch { diskLoading = false; }
            });
        }

        void ShowDisks(List<DiskInfo> disks, List<DiskEvent> events, string summary, int days)
        {
            var t = app.Theme;
            Func<long, string> N = v => v < 0 ? "—" : v.ToString("N0");
            diskList.BeginUpdate();
            diskList.Items.Clear();
            foreach (var d in disks)
            {
                var li = new ListViewItem(new[]
                {
                    d.Label, d.Model, d.Media + " " + d.Bus, d.SizeGb >= 1000 ? (d.SizeGb / 1000).ToString("0.#") + " TB" : d.SizeGb.ToString("0") + " GB",
                    d.Health, N(d.Temp), d.PowerOnHours < 0 ? "—" : d.PowerOnHours.ToString("N0") + " г", N(d.Reallocated), N(d.Pending), N(d.Crc),
                    N(d.StartStop), N(d.LoadCycles), d.Wear < 0 ? "—" : d.Wear + "%", d.Serial
                });
                bool bad = d.Reallocated > 0 || d.Pending > 0 || d.Uncorrectable > 0 || (d.Health != "Healthy" && d.Health != "?");
                bool warn = d.Crc > 0 || (d.IsHdd && d.LoadCycles > 250000) || d.Temp > 50 || d.Wear > 80 || events.Any(e => e.Disk == d.Number && e.Kind == "reset");
                li.ForeColor = bad ? t.Danger : warn ? t.Warn : t.Fg;
                diskList.Items.Add(li);
            }
            diskList.EndUpdate();
            diskChart.SetData(disks, events, days);
            if (diskSummary.Text != summary) diskSummary.Text = summary;
            if (app.Sampler.Stalls.Live == "") diskStatus.Text = DiskStatusText();
        }
        // ---- закономірності та зміни
        void RefreshAnalysisPages()
        {
            if (patternText.Text != app.PatternText) patternText.Text = app.PatternText;
            var t = app.Theme;
            changeList.BeginUpdate();
            changeList.Items.Clear();
            var rows = app.Changes.Select(x => new { Time = x.Time, Kind = x.Kind, Text = x.Text, Crash = false })
                .Concat(app.Crashes.Select(c => new { Time = c.Moment, Kind = "КРАШ", Text = (c.Code == 0 ? "без BSOD" : BugChecks.Get(c.Code)[0]) + (c.Driver != "" ? " (" + c.Driver + ")" : ""), Crash = true }))
                .OrderByDescending(x => x.Time);
            foreach (var x in rows)
            {
                var li = new ListViewItem(new[] { x.Time.ToString("yyyy-MM-dd HH:mm"), x.Kind, x.Text });
                li.ForeColor = x.Crash ? t.Danger : x.Kind == "Драйвер" ? t.Accent : t.Fg;
                changeList.Items.Add(li);
            }
            changeList.EndUpdate();
        }

        void BuildPack(Button b)
        {
            b.Enabled = false;
            var old = b.Text;
            b.Text = "Збираю…";
            ThreadPool.QueueUserWorkItem(_ =>
            {
                string zip = null, err = null;
                try { zip = DiagPack.Build(app); } catch (Exception ex) { err = ex.Message; }
                try
                {
                    BeginInvoke(new Action(() =>
                    {
                        b.Enabled = true; b.Text = old;
                        if (err != null) MessageBox.Show(this, "Не вдалося зібрати пакет: " + err, "DEADPIXEL");
                        else System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + zip + "\"");
                    }));
                }
                catch { }
            });
        }
    }
    // ================================================================ графік
    class ChartSeries
    {
        public string Name, Unit;
        public Color Color;
        public Func<Sample, double> Value;
        public double Max;
        public ChartSeries(string name, Color color, Func<Sample, double> value, double max, string unit)
        { Name = name; Color = color; Value = value; Max = max; Unit = unit; }
    }

    class Chart : Control
    {
        readonly string title;
        readonly Func<Theme> theme;
        readonly Func<List<Sample>> source;
        readonly ChartSeries[] series;
        Font bold;

        public Chart(string title, Func<Theme> theme, Func<List<Sample>> source, ChartSeries[] series)
        {
            this.title = title; this.theme = theme; this.source = source; this.series = series;
            Tag = "surface"; // фарбується темою як картка
            DoubleBuffered = true;
            SetStyle(ControlStyles.ResizeRedraw | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = theme();
            var g = e.Graphics;
            g.Clear(t.Surface);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var area = new Rectangle(10, 26, Width - 20, Height - 40);
            using (var grid = new Pen(t.Grid))
                for (int i = 0; i <= 4; i++) { int y = area.Top + area.Height * i / 4; g.DrawLine(grid, area.Left, y, area.Right, y); }

            var data = source();
            float lx = 10;
            if (bold == null) bold = new Font(Font, FontStyle.Bold);
            TextRenderer.DrawText(g, title, bold, new Point((int)lx, 6), t.Fg);
            lx += 40;
            foreach (var s in series)
            {
                var cur = data.Count > 0 ? s.Value(data[data.Count - 1]) : double.NaN;
                var label = s.Name + " " + (double.IsNaN(cur) ? "—" : cur.ToString("0")) + s.Unit;
                TextRenderer.DrawText(g, label, Font, new Point((int)lx, 6), s.Color);
                lx += TextRenderer.MeasureText(label, Font).Width + 8;
                if (data.Count < 2) continue;
                var pts = new List<PointF>();
                for (int i = 0; i < data.Count; i++)
                {
                    var v = s.Value(data[i]);
                    if (double.IsNaN(v)) continue;
                    float x = area.Right - (data.Count - 1 - i) * area.Width / (float)(Sampler.MaxSamples - 1);
                    float y = area.Bottom - (float)(Math.Min(v, s.Max) / s.Max) * area.Height;
                    pts.Add(new PointF(x, y));
                }
                if (pts.Count > 1) using (var pen = new Pen(s.Color, 1.6f)) g.DrawLines(pen, pts.ToArray());
            }
            var span = data.Count > 1 ? (data[data.Count - 1].Time - data[0].Time) : TimeSpan.Zero;
            var hint = span.TotalMinutes >= 1 ? string.Format("останні {0:0} хв", span.TotalMinutes) : "збір даних…";
            var sz = TextRenderer.MeasureText(hint, Font);
            TextRenderer.DrawText(g, hint, Font, new Point(Width - sz.Width - 8, Height - sz.Height - 2), t.Muted);
        }
    }
}
