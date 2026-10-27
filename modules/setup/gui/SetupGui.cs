// DEADPIXEL Setup GUI — окремий процес модуля налаштувань: трей лише запускає його.
// Стан ПК (рецепти: перевірка/застосування/відкат) рахує Setup.ps1 — GUI викликає його з -OutFile і показує JSON.
// Сценарії (вкладки рецептів) — покрокові інструкції: кроки-команди GUI виконає сам кнопкою ▶,
// прогрес зберігається в data\setup\progress.json і переживає перезавантаження.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadPixel
{
    static class SetupProgram
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            // --open <рецепт>/<вкладка> — після перезапуску з правами адміністратора; --resume — після перезавантаження ПК
            string open = null;
            for (int i = 0; i < args.Length; i++)
                if (args[i] == "--open" && i + 1 < args.Length) open = args[i + 1];
            Application.Run(new SetupForm(open));
        }
    }

    // ---------------------------------------------------------------- JSON-контракт Setup.ps1

    class Step
    {
        public string Text { get; set; } public string Hint { get; set; }
        public string Run { get; set; } public string Expect { get; set; } public string If { get; set; }
        public string Open { get; set; } public string Reboot { get; set; }
        public bool Admin { get; set; } public string Confirm { get; set; }
        public bool IsCommand { get { return !string.IsNullOrEmpty(Run); } }
    }
    class ParamInfo { public string Name { get; set; } public string Title { get; set; } public string Default { get; set; } public string Pattern { get; set; } public string Hint { get; set; } }
    class TabInfo
    {
        public string Id { get; set; } public string Title { get; set; } public string Description { get; set; }
        public List<ParamInfo> Params { get; set; } public List<Step> Steps { get; set; }
    }
    class ItemInfo { public string Id { get; set; } public string Title { get; set; } public string Hint { get; set; } public string DesiredText { get; set; } }
    class RecipeInfo
    {
        public string Name { get; set; } public string Title { get; set; } public string Description { get; set; }
        public bool Reboot { get; set; } public bool HasBackup { get; set; }
        public List<Step> Steps { get; set; } public List<ItemInfo> Items { get; set; } public List<TabInfo> Tabs { get; set; }
    }
    class ProfileInfo
    {
        public string Name { get; set; } public string Title { get; set; } public string Description { get; set; }
        public List<string> Recipes { get; set; } public List<Step> Steps { get; set; }
    }
    class Catalog { public string Error { get; set; } public List<RecipeInfo> Recipes { get; set; } public List<ProfileInfo> Profiles { get; set; } }
    class ItemResult
    {
        public string Recipe { get; set; } public string Id { get; set; } public string Title { get; set; } public string Status { get; set; }
        public string CurrentText { get; set; } public string DesiredText { get; set; } public string Message { get; set; }
    }
    class RecipeResult
    {
        public string Recipe { get; set; } public string Title { get; set; } public List<ItemResult> Results { get; set; }
        public string Backup { get; set; } public string Message { get; set; } public bool HasBackup { get; set; }
    }
    class RunResult { public string Error { get; set; } public List<RecipeResult> Recipes { get; set; } }

    static class Engine
    {
        public static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory;

        public static bool IsAdmin
        {
            get { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        }

        // Дані як у Setup.ps1: data\setup поруч із програмою, інакше %LOCALAPPDATA%\DeadPixel\setup
        static string dataDir;
        public static string DataDir
        {
            get
            {
                if (dataDir != null) return dataDir;
                var d = Path.GetFullPath(Path.Combine(Dir, @"..\..\data\setup"));
                try
                {
                    Directory.CreateDirectory(d);
                    var probe = Path.Combine(d, ".write-test");
                    File.WriteAllText(probe, "");
                    File.Delete(probe);
                }
                catch
                {
                    d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DeadPixel\setup");
                    Directory.CreateDirectory(d);
                }
                return dataDir = d;
            }
        }

        // Запускає Setup.ps1 і читає JSON, який він записав у тимчасовий файл (stdout з підвищеного процесу не перехопити)
        public static T Run<T>(string args, bool elevate)
        {
            var tmp = Path.Combine(Path.GetTempPath(), "deadpixel-setup-" + Guid.NewGuid().ToString("N") + ".json");
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(Dir, "Setup.ps1") + "\" " + args + " -OutFile \"" + tmp + "\"");
            if (elevate && !IsAdmin) { psi.UseShellExecute = true; psi.Verb = "runas"; psi.WindowStyle = ProcessWindowStyle.Hidden; }
            else { psi.UseShellExecute = false; psi.CreateNoWindow = true; }
            try
            {
                using (var p = Process.Start(psi)) p.WaitForExit();
                if (!File.Exists(tmp)) throw new Exception("Setup.ps1 не повернув результат.");
                return new JavaScriptSerializer().Deserialize<T>(File.ReadAllText(tmp, Encoding.UTF8));
            }
            finally { try { File.Delete(tmp); } catch { } }
        }

        // "control.exe /name X" → файл + аргументи; ms-settings:... і *.msc відкриваються як є
        public static void Open(string run)
        {
            int sp = run.IndexOf(' ');
            var psi = sp > 0 && run.Substring(0, sp).EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? new ProcessStartInfo(run.Substring(0, sp), run.Substring(sp + 1))
                : new ProcessStartInfo(run);
            psi.UseShellExecute = true;
            Process.Start(psi);
        }

        [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        public static DateTime BootTimeUtc { get { return DateTime.UtcNow - TimeSpan.FromMilliseconds(GetTickCount64()); } }

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
    }

    // ---------------------------------------------------------------- виконання команд кроків

    class CommandRun
    {
        // Обгортка: UTF-8 у stdout; помилки командлетів = невдача; stderr нативних програм — лише текст, для них важить код виходу
        const string Prefix =
            "[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false\n" +
            "$ProgressPreference = 'SilentlyContinue'\n" +
            "$global:LASTEXITCODE = 0\n" +
            "$script:failed = $false\n" +
            "try {\n& {\n";
        const string Suffix =
            "\n} 2>&1 | ForEach-Object {\n" +
            "  if ($_ -is [System.Management.Automation.ErrorRecord]) {\n" +
            "    if ($_.FullyQualifiedErrorId -like 'NativeCommandError*') { $_.ToString() } else { $script:failed = $true; '! ' + $_.ToString() }\n" +
            "  } else { $_ }\n" +
            "} | Out-String -Stream -Width 200\n" +
            "} catch { '! ' + $_.Exception.Message; exit 1 }\n" +
            "if ($script:failed) { exit 1 }\n" +
            "if ($LASTEXITCODE) { exit $LASTEXITCODE }\n" +
            "exit 0\n";

        Process p;
        public volatile bool Cancelled;

        // Блокує потік до завершення; рядки виводу — через onLine (з фонового потоку). true — успіх (код 0)
        public bool Execute(string command, Action<string> onLine)
        {
            var enc = Convert.ToBase64String(Encoding.Unicode.GetBytes(Prefix + command + Suffix));
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + enc)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            p = Process.Start(psi);
            // з перенаправленим stderr PowerShell пише туди службовий прогрес як CLIXML — це не помилки, пропускаємо
            p.ErrorDataReceived += (s, e) => { if (e.Data != null && !e.Data.StartsWith("#< CLIXML") && !e.Data.StartsWith("<Objs ")) onLine(e.Data); };
            p.BeginErrorReadLine();
            string line;
            while ((line = p.StandardOutput.ReadLine()) != null) onLine(line);
            p.WaitForExit();
            return !Cancelled && p.ExitCode == 0;
        }

        public void Cancel()
        {
            Cancelled = true;
            try { if (p != null && !p.HasExited) p.Kill(); } catch { }
        }
    }

    // ---------------------------------------------------------------- прогрес сценаріїв (data\setup\progress.json)

    class StepRecord { public string Text { get; set; } public string State { get; set; } public string Output { get; set; } public DateTime Time { get; set; } }
    class TabProgress { public Dictionary<string, string> Params { get; set; } public List<StepRecord> Steps { get; set; } }

    class Progress
    {
        public string Resume { get; set; }   // ключ сценарію, який треба відкрити після перезавантаження
        public Dictionary<string, TabProgress> Tabs { get; set; }

        static string FilePath { get { return Path.Combine(Engine.DataDir, "progress.json"); } }

        public static Progress Load()
        {
            try
            {
                if (File.Exists(FilePath))
                {
                    var p = new JavaScriptSerializer().Deserialize<Progress>(File.ReadAllText(FilePath, Encoding.UTF8));
                    if (p != null) { if (p.Tabs == null) p.Tabs = new Dictionary<string, TabProgress>(); return p; }
                }
            }
            catch { }
            return new Progress { Tabs = new Dictionary<string, TabProgress>() };
        }

        public void Save()
        {
            try { File.WriteAllText(FilePath, new JavaScriptSerializer().Serialize(this), Encoding.UTF8); } catch { }
        }

        public TabProgress Get(string key)
        {
            TabProgress t;
            if (!Tabs.TryGetValue(key, out t)) Tabs[key] = t = new TabProgress();
            if (t.Params == null) t.Params = new Dictionary<string, string>();
            if (t.Steps == null) t.Steps = new List<StepRecord>();
            return t;
        }
    }

    // ---------------------------------------------------------------- картка кроку

    class StepRow : Panel
    {
        public readonly int Index;
        public readonly Step Step;
        public string State = "";   // "" | running | ok | fail | skipped | done | reboot
        public bool Current;
        readonly Theme theme;
        readonly Label text = MakeLabel(null), meta = MakeLabel("muted"), code = MakeLabel(null), hint = MakeLabel("muted");
        readonly LinkLabel why = new LinkLabel { AutoSize = true, Text = "Чому це?", LinkBehavior = LinkBehavior.HoverUnderline };
        readonly Panel codeBox = new Panel(), outBox = new Panel { Padding = new Padding(1) };
        readonly TextBox output = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, Dock = DockStyle.Fill, Font = new Font("Consolas", 9f) };
        readonly FlowLayoutPanel actions = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Margin = Padding.Empty };
        public readonly Button RunBtn, CopyBtn, OpenBtn, RebootBtn;
        public readonly CheckBox Done;
        bool hintOpen, silent;
        public event Action<StepRow> RunClicked, CopyClicked, OpenClicked, RebootClicked, DoneChanged;

        public StepRow(Theme theme, int index, Step step)
        {
            this.theme = theme;
            Index = index;
            Step = step;
            Tag = "surface";
            Margin = new Padding(0, 0, 0, 6);
            DoubleBuffered = true;
            code.Font = new Font("Consolas", 9.5f);
            codeBox.Controls.Add(code);
            outBox.Controls.Add(output);
            outBox.Visible = false;
            hint.Visible = false;
            why.Visible = !string.IsNullOrEmpty(step.Hint);
            why.LinkClicked += (s, e) => { hintOpen = !hintOpen; hint.Visible = hintOpen; why.Text = hintOpen ? "Сховати пояснення" : "Чому це?"; Relayout(); };
            hint.Text = step.Hint ?? "";
            codeBox.Visible = step.IsCommand;

            if (step.IsCommand)
            {
                RunBtn = ActionBtn("▶ Виконати", () => Fire(RunClicked));
                CopyBtn = ActionBtn("Копіювати", () => Fire(CopyClicked));
            }
            if (!string.IsNullOrEmpty(step.Open)) OpenBtn = ActionBtn("Відкрити ↗", () => Fire(OpenClicked));
            if (step.Reboot != null) RebootBtn = ActionBtn(step.Reboot == "firmware" ? "⟳ У BIOS/UEFI" : "⟳ Перезавантажити", () => Fire(RebootClicked));
            if (!step.IsCommand)
            {
                Done = new CheckBox { Text = "Зроблено", AutoSize = true, Margin = new Padding(6, 6, 0, 0) };
                Done.CheckedChanged += (s, e) => { if (!silent) Fire(DoneChanged); };
                actions.Controls.Add(Done);
            }

            var m = new List<string>();
            if (step.If == "ok") m.Add("лише якщо попередня команда вдалася");
            if (step.If == "fail") m.Add("лише якщо попередня команда НЕ вдалася");
            if (step.Admin) m.Add("потрібні права адміністратора");
            if (!string.IsNullOrEmpty(step.Expect)) m.Add("успіх, якщо у виводі є: " + step.Expect);
            meta.Text = string.Join("  ·  ", m);
            meta.Visible = m.Count > 0;

            Controls.AddRange(new Control[] { text, meta, codeBox, why, hint, outBox, actions });
        }

        static Label MakeLabel(string tag) { return new Label { AutoSize = false, UseMnemonic = false, Tag = tag }; }

        Button ActionBtn(string caption, Action click)
        {
            var b = new Button { Text = caption, AutoSize = true, Height = 28, Padding = new Padding(6, 0, 6, 0), Margin = new Padding(6, 0, 0, 0) };
            b.Click += (s, e) => click();
            actions.Controls.Add(b);
            return b;
        }

        void Fire(Action<StepRow> h) { if (h != null) h(this); }

        // Після theme.Apply: кольори, яких тема не знає
        public void ApplyColors()
        {
            codeBox.BackColor = theme.Bg;
            outBox.BackColor = theme.Border;
            output.BackColor = theme.Bg;
            output.ForeColor = theme.Fg;
            why.LinkColor = why.ActiveLinkColor = theme.Accent;
            if (RunBtn != null) RunBtn.ForeColor = StateColor("ok", theme);
        }

        public void SetDisplay(string textValue, string codeValue)
        {
            text.Text = textValue;
            code.Text = codeValue ?? "";
        }

        public void SetState(string st)
        {
            State = st;
            if (Done != null) { silent = true; Done.Checked = st == "done" || st == "ok"; silent = false; }
            if (RunBtn != null)
            {
                RunBtn.Text = st == "running" ? "■ Стоп" : st == "ok" || st == "fail" ? "▶ Ще раз" : st == "skipped" ? "▶ Все одно" : "▶ Виконати";
                RunBtn.ForeColor = st == "running" ? theme.Danger : StateColor("ok", theme);
            }
            Invalidate();
        }

        public void ClearOutput() { output.Clear(); }

        public void AppendOutput(string line)
        {
            outBox.Visible = true;
            output.AppendText(line + "\r\n");
            if (output.Lines.Length <= 16) Relayout(); // далі висота вже максимальна
        }

        // Після зміни висоти картки сусіди мають зсунутися — перерахунок у списку
        void Relayout()
        {
            var list = Parent as StepList;
            if (list != null) list.Relayout(); else if (Parent != null) DoLayout(Width);
        }

        public void SetOutput(string all)
        {
            output.Text = all ?? "";
            outBox.Visible = !string.IsNullOrEmpty(all);
        }


        // Ручна розкладка: колонка тексту між значком стану й кнопками, висота — за вмістом
        public void DoLayout(int w)
        {
            SuspendLayout();
            var aw = actions.PreferredSize.Width;
            int x = 46, cw = Math.Max(160, w - x - aw - 22), y = 10;
            Place(text, x, ref y, cw);
            if (meta.Visible) Place(meta, x, ref y, cw);
            if (codeBox.Visible)
            {
                var h = Measure(code, cw - 16);
                code.SetBounds(8, 6, cw - 16, h);
                codeBox.SetBounds(x, y, cw, h + 12);
                y += codeBox.Height + 6;
            }
            if (why.Visible) { why.Location = new Point(x, y); y += why.Height + 4; }
            if (hint.Visible) Place(hint, x, ref y, cw);
            if (outBox.Visible)
            {
                // висота за обсягом виводу, довший — з прокруткою
                int oh = Math.Min(160, Math.Max(38, output.Lines.Length * output.Font.Height + 10));
                outBox.SetBounds(x, y, w - x - 12, oh);
                y += oh + 6;
            }
            actions.Location = new Point(w - aw - 12, 9);
            Size = new Size(w, Math.Max(y + 4, 50));
            ResumeLayout();
        }

        static void Place(Label l, int x, ref int y, int w)
        {
            var h = Measure(l, w);
            l.SetBounds(x, y, w, h);
            y += h + 4;
        }

        static int Measure(Label l, int w)
        {
            return TextRenderer.MeasureText(l.Text.Length == 0 ? " " : l.Text, l.Font, new Size(w, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix).Height;
        }

        public static Color StateColor(string st, Theme t)
        {
            switch (st)
            {
                case "ok": case "done": return t.Dark ? Color.FromArgb(74, 222, 128) : Color.FromArgb(22, 135, 60);
                case "fail": return t.Danger;
                case "running": case "reboot": return t.Accent;
                default: return t.Muted;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (Current) using (var b = new SolidBrush(theme.Accent)) g.FillRectangle(b, 0, 0, 3, Height);
            var c = StateColor(State, theme);
            var r = new Rectangle(12, 10, 24, 24);
            bool filled = State == "ok" || State == "done" || State == "fail" || State == "running";
            if (filled) using (var b = new SolidBrush(c)) g.FillEllipse(b, r);
            else using (var p = new Pen(Current ? theme.Accent : c, 1.5f)) g.DrawEllipse(p, r);
            var glyph = State == "ok" || State == "done" ? "✓" : State == "fail" ? "✕" : State == "running" ? "…" : State == "skipped" ? "–" : State == "reboot" ? "⟳" : (Index + 1).ToString();
            TextRenderer.DrawText(g, glyph, new Font("Segoe UI Semibold", 9f), r, filled ? (theme.Dark ? theme.Bg : Color.White) : Current ? theme.Accent : c,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    // ---------------------------------------------------------------- список кроків із логікою сценарію

    class StepList : FlowLayoutPanel
    {
        readonly Theme theme;
        readonly Progress progress;
        readonly string key;
        readonly Func<Dictionary<string, string>> paramValues;
        readonly Func<string> paramError;
        readonly List<StepRow> rows = new List<StepRow>();
        readonly List<Control> headers = new List<Control>();
        CommandRun running;
        StepRow runningRow;
        bool runAll;

        public event Action<string, Color> Status;
        public event Action<bool> RunningChanged;
        public bool IsRunning { get { return running != null; } }

        // steps: (заголовок розділу або null, крок)
        public StepList(Theme theme, Progress progress, string key, IList<KeyValuePair<string, Step>> steps,
                        Func<Dictionary<string, string>> paramValues, Func<string> paramError)
        {
            this.theme = theme;
            this.progress = progress;
            this.key = key;
            this.paramValues = paramValues ?? (() => new Dictionary<string, string>());
            this.paramError = paramError ?? (() => null);
            Dock = DockStyle.Fill;
            FlowDirection = FlowDirection.TopDown;
            WrapContents = false;
            // лише вертикальна прокрутка: картки завжди підганяються під ширину
            HorizontalScroll.Maximum = 0;
            HorizontalScroll.Visible = false;
            AutoScroll = true;
            Padding = new Padding(0, 2, 0, 2);

            var tp = progress.Get(key);
            var boot = Engine.BootTimeUtc;
            string section = null;
            for (int i = 0; i < steps.Count; i++)
            {
                if (steps[i].Key != null && steps[i].Key != section)
                {
                    section = steps[i].Key;
                    var h = new Label { Text = section, AutoSize = false, Height = 24, Tag = "accent", Font = new Font("Segoe UI Semibold", 9f), TextAlign = ContentAlignment.BottomLeft, Margin = new Padding(0, 4, 0, 2) };
                    headers.Add(h);
                    Controls.Add(h);
                }
                var row = new StepRow(theme, i, steps[i].Value);
                var rec = i < tp.Steps.Count && tp.Steps[i] != null && tp.Steps[i].Text == row.Step.Text ? tp.Steps[i] : null;
                if (rec != null)
                {
                    var st = rec.State ?? "";
                    // крок "перезавантаження" зараховується, якщо ПК відтоді справді перезавантажувався
                    if (st == "reboot" && rec.Time.ToUniversalTime() < boot) { st = "ok"; rec.State = st; }
                    if (st == "running") st = "";
                    row.SetState(st);
                    row.SetOutput(rec.Output);
                }
                row.RunClicked += OnRun;
                row.CopyClicked += r => { try { Clipboard.SetText(Subst(r.Step.Run, true)); Say("Команду скопійовано.", theme.Muted); } catch { } };
                row.OpenClicked += r =>
                {
                    try { Engine.Open(Subst(r.Step.Open, false)); }
                    catch (Exception ex) { Say("Не вдалося відкрити " + r.Step.Open + ": " + ex.Message, theme.Danger); }
                };
                row.RebootClicked += OnReboot;
                row.DoneChanged += r => { SetState(r, r.Done.Checked ? "done" : "", null); ApplyConditions(); };
                rows.Add(row);
                Controls.Add(row);
            }
            if (rows.Count == 0)
            {
                var empty = new Label { Text = "Ручних кроків немає — усе робиться автоматично.", AutoSize = true, Tag = "muted", Margin = new Padding(4, 8, 0, 0) };
                headers.Add(empty);
                Controls.Add(empty);
            }
            UpdateDisplay();
            ApplyConditions();
            Resize += (s, e) => Relayout();
        }

        public void ApplyTheme()
        {
            theme.Apply(this);
            foreach (var r in rows) r.ApplyColors();
        }

        // Тексти й команди з підставленими параметрами
        public void UpdateDisplay()
        {
            foreach (var r in rows) r.SetDisplay(Subst(r.Step.Text, false), r.Step.IsCommand ? Subst(r.Step.Run, true) : null);
            Relayout();
        }

        public void Relayout()
        {
            SuspendLayout();
            // місце під вертикальну прокрутку резервуємо заздалегідь, інакше її поява дає горизонтальну
            int w = Math.Max(300, ClientSize.Width - (VerticalScroll.Visible ? 0 : SystemInformation.VerticalScrollBarWidth) - 4);
            foreach (var h in headers) if (!h.AutoSize) h.Width = w;
            foreach (var r in rows) r.DoLayout(w);
            ResumeLayout();
        }

        // {Param}: у команді — як рядок PowerShell у лапках (без ін'єкцій), у тексті — як є
        string Subst(string s, bool quote)
        {
            if (string.IsNullOrEmpty(s)) return s;
            foreach (var kv in paramValues())
                s = s.Replace("{" + kv.Key + "}", quote ? "'" + (kv.Value ?? "").Replace("'", "''") + "'" : kv.Value);
            return s;
        }

        void Say(string text, Color c) { var h = Status; if (h != null) h(text, c); }

        void SetRunning(StepRow row, CommandRun run)
        {
            running = run;
            runningRow = row;
            var h = RunningChanged;
            if (h != null) h(run != null);
        }

        void SetState(StepRow row, string st, string output)
        {
            row.SetState(st);
            var tp = progress.Get(key);
            while (tp.Steps.Count <= row.Index) tp.Steps.Add(null);
            var rec = tp.Steps[row.Index] ?? new StepRecord();
            rec.Text = row.Step.Text;
            rec.State = st;
            if (output != null) rec.Output = output.Length > 8000 ? output.Substring(output.Length - 8000) : output;
            rec.Time = DateTime.UtcNow;
            tp.Steps[row.Index] = rec;
            if (AllSettled() && progress.Resume == key) progress.Resume = null;
            progress.Save();
            UpdateCurrent();
        }

        // ---- умови If

        int PrevCommand(int i)
        {
            for (int k = i - 1; k >= 0; k--) if (rows[k].Step.IsCommand) return k;
            return -1;
        }

        bool? ConditionMet(int i)
        {
            var cond = rows[i].Step.If;
            if (string.IsNullOrEmpty(cond)) return true;
            int k = PrevCommand(i);
            if (k < 0) return true;
            var st = rows[k].State;
            if (st == "ok") return cond == "ok";
            if (st == "fail") return cond == "fail";
            if (st == "skipped") return false;
            return null; // попередня команда ще не виконувалась
        }

        bool HasFailBranch(int i)
        {
            for (int j = i + 1; j < rows.Count; j++)
            {
                if (rows[j].Step.If == "fail") return true;
                if (rows[j].Step.IsCommand) break;
            }
            return false;
        }

        // Крок пройдено: виконано/зроблено/пропущено, або впав, але для невдачі є окрема гілка
        bool Settled(int i)
        {
            var st = rows[i].State;
            return st == "ok" || st == "done" || st == "skipped" || st == "fail" && HasFailBranch(i);
        }

        bool AllSettled()
        {
            for (int i = 0; i < rows.Count; i++) if (!Settled(i)) return false;
            return true;
        }

        void ApplyConditions()
        {
            for (int i = 0; i < rows.Count; i++)
            {
                var met = ConditionMet(i);
                if (met == false && rows[i].State == "") SetState(rows[i], "skipped", null);
                else if (met != false && rows[i].State == "skipped") SetState(rows[i], "", null);
            }
            UpdateCurrent();
        }

        void UpdateCurrent()
        {
            int cur = -1;
            for (int i = 0; i < rows.Count; i++) if (!Settled(i)) { cur = i; break; }
            for (int i = 0; i < rows.Count; i++)
                if (rows[i].Current != (i == cur)) { rows[i].Current = i == cur; rows[i].Invalidate(); }
        }

        public int CurrentNumber
        {
            get { for (int i = 0; i < rows.Count; i++) if (!Settled(i)) return i + 1; return 0; }
        }

        public void ScrollToCurrent()
        {
            var r = rows.FirstOrDefault(x => x.Current);
            if (r != null) ScrollControlIntoView(r);
        }

        // ---- дії

        void OnRun(StepRow row)
        {
            if (runningRow == row) { running.Cancel(); runAll = false; return; }
            if (running != null) { Say("Зачекайте — виконується крок " + (runningRow.Index + 1) + ".", theme.Warn); return; }
            runAll = false;
            RunStep(row, null);
        }

        // false — крок не запущено (немає прав, скасовано, помилка в параметрах)
        bool RunStep(StepRow row, Action<bool> after)
        {
            var s = row.Step;
            if (s.Admin && !Engine.IsAdmin)
            {
                Say("Крок " + (row.Index + 1) + " потребує прав адміністратора — натисніть «Перезапустити з правами» вгорі.", theme.Warn);
                return false;
            }
            var perr = paramError();
            if (perr != null && s.Run.Contains("{")) { Say(perr, theme.Danger); return false; }
            if (!string.IsNullOrEmpty(s.Confirm) &&
                MessageBox.Show(FindForm(), s.Confirm, "DEADPIXEL", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return false;

            var cmd = Subst(s.Run, true);
            var run = new CommandRun();
            var sb = new StringBuilder();
            row.ClearOutput();
            row.AppendOutput("> " + cmd);
            SetState(row, "running", null);
            SetRunning(row, run);
            Say("Виконую крок " + (row.Index + 1) + "…", theme.Muted);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                bool ok;
                string err = null;
                try
                {
                    ok = run.Execute(cmd, line =>
                    {
                        lock (sb) sb.AppendLine(line);
                        Ui(() => row.AppendOutput(line));
                    });
                }
                catch (Exception ex) { ok = false; err = ex.Message; }
                Ui(() =>
                {
                    SetRunning(null, null);
                    string outText;
                    lock (sb) outText = sb.ToString();
                    if (err != null) row.AppendOutput("! " + err);
                    if (ok && !string.IsNullOrEmpty(s.Expect))
                    {
                        try { ok = Regex.IsMatch(outText, s.Expect, RegexOptions.IgnoreCase | RegexOptions.Multiline); }
                        catch (ArgumentException ex) { ok = false; row.AppendOutput("! неправильний Expect у рецепті: " + ex.Message); }
                        if (!ok) row.AppendOutput("— у виводі немає очікуваного: " + s.Expect);
                    }
                    if (run.Cancelled) row.AppendOutput("— зупинено");
                    SetState(row, ok ? "ok" : "fail", "> " + cmd + "\r\n" + outText + (err != null ? "! " + err : ""));
                    ApplyConditions();
                    if (after != null) after(ok);
                    else Say(ok ? "Крок " + (row.Index + 1) + " виконано." : "Крок " + (row.Index + 1) + " не вдався — подивіться вивід.", ok ? StepRow.StateColor("ok", theme) : theme.Danger);
                });
            });
            return true;
        }

        void Ui(Action a)
        {
            try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { }
        }

        // «Виконати все»: команди підряд; зупинка на ручній дії, перезавантаженні або невдачі без запасної гілки
        public void RunAll()
        {
            if (running != null) return;
            runAll = true;
            Next(0);
        }

        void Next(int i)
        {
            if (!runAll) return;
            for (; i < rows.Count; i++)
            {
                if (Settled(i)) continue;
                var r = rows[i];
                var met = ConditionMet(i);
                if (met == false) { SetState(r, "skipped", null); continue; }
                if (r.Step.IsCommand)
                {
                    int idx = i;
                    if (!RunStep(r, ok =>
                    {
                        if (ok || HasFailBranch(idx)) Next(idx + 1);
                        else { runAll = false; Say("Крок " + (idx + 1) + " не вдався — подивіться вивід.", theme.Danger); }
                    })) runAll = false;
                    return;
                }
                runAll = false;
                ScrollControlIntoView(r);
                Say(r.Step.Reboot != null ? "Крок " + (i + 1) + ": потрібне перезавантаження." : "Крок " + (i + 1) + " — ваша дія. Позначте «Зроблено» і натисніть «Виконати все» знову.", theme.Warn);
                return;
            }
            runAll = false;
            Say("Усі кроки пройдено ✓", StepRow.StateColor("ok", theme));
        }

        public void Reset()
        {
            if (running != null) return;
            progress.Get(key).Steps.Clear();
            if (progress.Resume == key) progress.Resume = null;
            foreach (var r in rows) { r.SetState(""); r.SetOutput(null); }
            progress.Save();
            ApplyConditions();
            Relayout();
            Say("Прогрес скинуто.", theme.Muted);
        }

        void OnReboot(StepRow row)
        {
            bool fw = row.Step.Reboot == "firmware";
            if (fw && !Engine.IsAdmin)
            {
                Say("Перезавантаження в BIOS/UEFI потребує прав адміністратора — натисніть «Перезапустити з правами» вгорі.", theme.Warn);
                return;
            }
            var q = (fw ? "ПК перезавантажиться одразу в BIOS/UEFI." : "ПК буде перезавантажено.") +
                    "\n\nЗбережіть відкриту роботу. Прогрес сценарію збережено — після входу в Windows це вікно відкриється на наступному кроці.\n\nПерезавантажити зараз?";
            if (MessageBox.Show(FindForm(), q, "DEADPIXEL", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;

            SetState(row, "reboot", null);
            progress.Resume = key;
            progress.Save();
            try
            {
                // RunOnce: Windows сама видаляє запис після запуску
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\RunOnce"))
                    k.SetValue("DeadPixelSetup", "\"" + Application.ExecutablePath + "\" --open \"" + key + "\"");
            }
            catch { }
            try
            {
                using (var p = Process.Start(new ProcessStartInfo("shutdown.exe", fw ? "/r /fw /t 0" : "/r /t 0") { UseShellExecute = false, CreateNoWindow = true }))
                {
                    p.WaitForExit(10000);
                    if (p.HasExited && p.ExitCode != 0) throw new Exception("shutdown завершився з кодом " + p.ExitCode + (fw ? " (можливо, плата не підтримує вхід в UEFI з Windows — перезавантажте вручну і тисніть Del/F2)" : ""));
                }
            }
            catch (Exception ex)
            {
                SetState(row, "", null);
                Say("Не вдалося перезавантажити: " + ex.Message, theme.Danger);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && running != null) running.Cancel();
            base.Dispose(disposing);
        }
    }

    // ---------------------------------------------------------------- вікно

    class SetupForm : Form
    {
        readonly Theme theme = Engine.LoadTheme();
        readonly Progress progress = Progress.Load();
        Catalog catalog = new Catalog { Recipes = new List<RecipeInfo>(), Profiles = new List<ProfileInfo>() };
        readonly Dictionary<string, RecipeResult> results = new Dictionary<string, RecipeResult>();
        object selected;        // RecipeInfo | ProfileInfo
        TabInfo currentTab;     // null — "Рекомендовані"
        string pendingOpen;     // "<рецепт>/<вкладка>" для відкриття після завантаження каталогу

        readonly TreeView nav = new NavTree { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, HideSelection = false, ShowLines = false, ShowPlusMinus = false, ShowRootLines = false, FullRowSelect = true, ItemHeight = 26, Tag = "surface" };
        readonly Label title = new Label { Dock = DockStyle.Top, Height = 34, Font = new Font("Segoe UI Semibold", 14f), Padding = new Padding(0, 4, 0, 0), AutoEllipsis = true };
        readonly Label desc = new Label { Dock = DockStyle.Top, Height = 38, Tag = "muted", AutoEllipsis = true };
        readonly FlowLayoutPanel tabBar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 36, WrapContents = false, Padding = new Padding(0, 2, 0, 0) };
        readonly Panel content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(0, 6, 0, 0) };
        // сторінка "Рекомендовані"
        readonly TableLayoutPanel recPage = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5 };
        readonly ListView items;
        readonly TextBox hint = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.Vertical, Font = new Font("Segoe UI", 9.5f) };
        readonly Panel recSteps = new Panel { Dock = DockStyle.Fill };
        StepList recList;
        Control scenarioPage;
        StepList scenarioList;
        readonly Button btnCheck, btnApply, btnRevert, btnCheckAll;
        readonly Label status = new Label { AutoSize = true, Padding = new Padding(6, 7, 0, 0), Tag = "muted" };
        bool busy, stepsRunning;

        public SetupForm(string open)
        {
            pendingOpen = open ?? progress.Resume;
            Text = "DEADPIXEL — Сетап ПК" + (Engine.IsAdmin ? " (адміністратор)" : "");
            Font = new Font("Segoe UI", 9f);
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            Size = new Size(1220, Math.Min(860, Screen.PrimaryScreen.WorkingArea.Height - 40));
            MinimumSize = new Size(940, 600);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            items = MakeList("Стан", 90, "Налаштування", 330, "Зараз", 170, "Треба", 170);
            items.ShowGroups = true;
            items.SelectedIndexChanged += (s, e) => ShowItemHint();
            nav.AfterSelect += (s, e) => Select(e.Node.Tag);
            // Системне виділення в TreeView — біле навіть у темній темі; малюємо рядки кольорами теми
            nav.DrawMode = TreeViewDrawMode.OwnerDrawText;
            nav.DrawNode += (s, e) =>
            {
                if (e.Bounds.IsEmpty) return;
                bool sel = (e.State & TreeNodeStates.Selected) != 0 && e.Node.Tag != null;
                using (var b = new SolidBrush(sel ? theme.Selected : nav.BackColor))
                    e.Graphics.FillRectangle(b, 0, e.Bounds.Top, nav.ClientSize.Width, e.Bounds.Height);
                var r = new Rectangle(e.Bounds.Left, e.Bounds.Top, nav.ClientSize.Width - e.Bounds.Left - 4, e.Bounds.Height);
                TextRenderer.DrawText(e.Graphics, e.Node.Text, e.Node.NodeFont ?? nav.Font, r, e.Node.ForeColor.IsEmpty ? nav.ForeColor : e.Node.ForeColor,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            };
            nav.BeforeSelect += (s, e) => { if (busy || stepsRunning) e.Cancel = true; };

            // ---- ліва колонка: профілі й рецепти
            btnCheckAll = Btn("Перевірити все", (s, e) => RunCheck("-Recipe *", "Перевіряю всі рецепти…"));
            var left = new Panel { Dock = DockStyle.Left, Width = 340, Padding = new Padding(10, 10, 6, 10) };
            var leftBottom = new Panel { Dock = DockStyle.Bottom, Height = 42, Padding = new Padding(0, 8, 0, 0) };
            btnCheckAll.Dock = DockStyle.Fill;
            leftBottom.Controls.Add(btnCheckAll);
            left.Controls.Add(Card(nav));
            left.Controls.Add(leftBottom);

            // ---- "Рекомендовані": таблиця стану, підказка, кроки вручну
            recPage.RowStyles.Add(new RowStyle(SizeType.Percent, 55));
            recPage.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
            recPage.RowStyles.Add(new RowStyle(SizeType.Absolute, 104));
            recPage.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
            recPage.RowStyles.Add(new RowStyle(SizeType.Percent, 45));
            recPage.Controls.Add(Card(items), 0, 0);
            recPage.Controls.Add(Caption("Підказка"), 0, 1);
            recPage.Controls.Add(Card(hint, new Padding(8, 6, 8, 6)), 0, 2);
            recPage.Controls.Add(Caption("Що зробити вручну"), 0, 3);
            recPage.Controls.Add(recSteps, 0, 4);
            content.Controls.Add(recPage);

            // ---- права колонка
            var right = new Panel { Dock = DockStyle.Fill, Padding = new Padding(6, 10, 12, 6) };
            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(0, 8, 0, 0), WrapContents = false };
            btnCheck = Btn("Перевірити", (s, e) => RunCheck(SelectionArgs(), "Перевіряю…"));
            btnApply = Btn("Застосувати", (s, e) => RunChange("-Apply"));
            btnRevert = Btn("Відкотити", (s, e) => RunChange("-Revert"));
            bar.Controls.AddRange(new Control[] { btnCheck, btnApply, btnRevert, status });
            right.Controls.Add(content);
            right.Controls.Add(tabBar);
            right.Controls.Add(desc);
            right.Controls.Add(title);
            right.Controls.Add(bar);

            Controls.Add(right);
            Controls.Add(left);

            Load += (s, e) =>
            {
                theme.Apply(this);
                theme.ApplyTitleBar(this);
                // У DarkMode_Explorer заголовки груп ListView темно-сині й нечитабельні; ItemsView (як у Провіднику) — світлі
                if (theme.Dark) SetWindowTheme(items.Handle, "DarkMode_ItemsView", null);
                if (theme.Dark) SetWindowTheme(nav.Handle, "DarkMode_Explorer", null); // темні виділення й прокрутка
                LoadCatalog();
            };
        }

        // ================================================================ дані

        void LoadCatalog()
        {
            RunAsync("Завантажую рецепти…", () => Engine.Run<Catalog>("-List", false), res =>
            {
                var c = (Catalog)res;
                if (c.Error != null) { SetStatus(c.Error, theme.Danger); return; }
                foreach (var r in c.Recipes)
                {
                    if (r.Items == null) r.Items = new List<ItemInfo>();
                    if (r.Tabs == null) r.Tabs = new List<TabInfo>();
                }
                catalog = c;
                BuildNav();
                // одразу перевіряємо все — щоб стан ПК було видно без зайвого кліку
                RunCheck("-Recipe *", "Перевіряю ПК…");
            });
        }

        void BuildNav()
        {
            nav.BeginUpdate();
            nav.Nodes.Clear();
            var profiles = nav.Nodes.Add("ПРОФІЛІ");
            foreach (var p in catalog.Profiles) profiles.Nodes.Add(new TreeNode(p.Title) { Tag = p, ToolTipText = p.Description });
            var recipes = nav.Nodes.Add("РЕЦЕПТИ");
            foreach (var r in catalog.Recipes) recipes.Nodes.Add(new TreeNode(r.Title) { Tag = r, ToolTipText = r.Description });
            foreach (TreeNode root in nav.Nodes) { root.NodeFont = new Font("Segoe UI Semibold", 8f); root.ForeColor = theme.Muted; }
            nav.ShowNodeToolTips = true;
            nav.ExpandAll();
            nav.EndUpdate();
            TreeNode node = null;
            if (pendingOpen != null)
            {
                var recipe = pendingOpen.Split('/')[0];
                node = AllNodes().FirstOrDefault(n => n.Tag is RecipeInfo && ((RecipeInfo)n.Tag).Name == recipe);
            }
            if (node == null) node = AllNodes().FirstOrDefault(n => n.Tag != null);
            if (node != null) nav.SelectedNode = node;
            UpdateNavColors();
        }

        IEnumerable<TreeNode> AllNodes() { return nav.Nodes.Cast<TreeNode>().SelectMany(r => r.Nodes.Cast<TreeNode>()); }

        List<RecipeInfo> SelectedRecipes()
        {
            var r = selected as RecipeInfo;
            if (r != null) return new List<RecipeInfo> { r };
            var p = selected as ProfileInfo;
            if (p == null) return new List<RecipeInfo>();
            return p.Recipes.Select(n => catalog.Recipes.FirstOrDefault(x => x.Name == n)).Where(x => x != null).ToList();
        }

        bool HasItems { get { return selected is ProfileInfo || SelectedRecipes().Any(r => r.Items.Count > 0); } }

        string SelectionArgs()
        {
            var p = selected as ProfileInfo;
            if (p != null) return "-ProfileName \"" + p.Name + "\"";
            var r = selected as RecipeInfo;
            return r != null ? "-Recipe \"" + r.Name + "\"" : "-Recipe *";
        }

        // Зведений стан рецепта: FAIL > DIFF > NA-лише > OK; null — ще не перевіряли або немає налаштувань
        string RecipeState(RecipeInfo r)
        {
            RecipeResult res;
            if (!results.TryGetValue(r.Name, out res) || res.Results == null || res.Results.Count == 0) return null;
            var st = res.Results.Select(x => x.Status).ToList();
            if (st.Contains("FAIL")) return "FAIL";
            if (st.Contains("DIFF")) return "DIFF";
            if (st.All(s => s == "NA")) return "NA";
            if (st.Contains("BACK")) return "BACK";
            return "OK";
        }

        int DiffCount(IEnumerable<RecipeInfo> recipes)
        {
            int n = 0;
            foreach (var r in recipes)
            {
                RecipeResult res;
                if (results.TryGetValue(r.Name, out res) && res.Results != null) n += res.Results.Count(x => x.Status == "DIFF" || x.Status == "FAIL");
            }
            return n;
        }

        // ================================================================ відображення

        void Select(object tag)
        {
            if (tag == null) return;
            selected = tag;
            var r = tag as RecipeInfo;
            var p = tag as ProfileInfo;
            title.Text = r != null ? r.Title : p.Title;
            desc.Text = r != null ? r.Description : p.Description;

            TabInfo tab = null;
            if (pendingOpen != null && r != null && pendingOpen.StartsWith(r.Name + "/"))
                tab = r.Tabs.FirstOrDefault(t => t.Id == pendingOpen.Substring(r.Name.Length + 1));
            if (tab == null && !HasItems && r != null) tab = r.Tabs.FirstOrDefault();
            ShowTab(tab);
        }

        void BuildTabs()
        {
            tabBar.Controls.Clear();
            var r = selected as RecipeInfo;
            var tabs = r != null ? r.Tabs : new List<TabInfo>();
            if (HasItems) tabBar.Controls.Add(TabBtn("Рекомендовані", currentTab == null, () => ShowTab(null)));
            foreach (var t in tabs)
            {
                var tt = t;
                tabBar.Controls.Add(TabBtn(t.Title, currentTab == t, () => ShowTab(tt)));
            }
            tabBar.Visible = tabBar.Controls.Count > 1;
            theme.Apply(tabBar);
        }

        Button TabBtn(string text, bool sel, Action click)
        {
            var b = new Button { Text = text, AutoSize = true, Height = 30, Padding = new Padding(10, 0, 10, 0), Margin = new Padding(0, 0, 2, 0), Tag = sel ? "tab-selected" : "tab" };
            b.Click += (s, e) => { if (!busy && !stepsRunning) click(); };
            return b;
        }

        void ShowTab(TabInfo tab)
        {
            currentTab = tab;
            BuildTabs();
            if (scenarioPage != null) { content.Controls.Remove(scenarioPage); scenarioPage.Dispose(); scenarioPage = null; scenarioList = null; }
            recPage.Visible = tab == null;
            if (tab == null)
            {
                ShowItems();
                ShowRecSteps();
                hint.Text = "Виберіть налаштування, щоб побачити пояснення.";
            }
            else
            {
                scenarioPage = BuildScenario((RecipeInfo)selected, tab);
                content.Controls.Add(scenarioPage);
                scenarioPage.BringToFront();
                theme.Apply(scenarioPage);
                scenarioList.ApplyTheme();
                scenarioList.Relayout();
                scenarioList.ScrollToCurrent();
            }
            UpdateButtons();
        }

        void ShowItems()
        {
            items.BeginUpdate();
            items.Items.Clear();
            items.Groups.Clear();
            foreach (var r in SelectedRecipes().Where(x => x.Items.Count > 0))
            {
                var g = new ListViewGroup(r.Title);
                items.Groups.Add(g);
                RecipeResult res;
                results.TryGetValue(r.Name, out res);
                foreach (var it in r.Items)
                {
                    var x = res == null || res.Results == null ? null : res.Results.FirstOrDefault(z => z.Id == it.Id);
                    var st = x == null ? "" : x.Status;
                    var lvi = new ListViewItem(new[] { StatusText(st), it.Title, x == null ? "?" : x.CurrentText, it.DesiredText }, g)
                    { Tag = new object[] { it, x }, UseItemStyleForSubItems = false, ToolTipText = it.Hint };
                    lvi.SubItems[0].ForeColor = StatusColor(st);
                    lvi.SubItems[0].Font = new Font(items.Font, FontStyle.Bold);
                    items.Items.Add(lvi);
                }
            }
            items.EndUpdate();
        }

        void ShowRecSteps()
        {
            if (recList != null) { recSteps.Controls.Remove(recList); recList.Dispose(); }
            var all = new List<KeyValuePair<string, Step>>();
            var p = selected as ProfileInfo;
            if (p != null) foreach (var s in p.Steps ?? new List<Step>()) all.Add(new KeyValuePair<string, Step>(p.Title, s));
            bool reboot = false;
            foreach (var r in SelectedRecipes())
            {
                foreach (var s in r.Steps ?? new List<Step>()) all.Add(new KeyValuePair<string, Step>(p != null ? r.Title : null, s));
                reboot |= r.Reboot;
            }
            if (reboot) all.Add(new KeyValuePair<string, Step>(p != null ? "Після застосування" : null, new Step { Text = "Перезавантажте ПК, щоб зміни набули чинності.", Reboot = "restart" }));
            var key = (p != null ? "profile:" + p.Name : ((RecipeInfo)selected).Name) + "/_recommended";
            recList = new StepList(theme, progress, key, all, null, null);
            recList.Status += SetStatus;
            recList.RunningChanged += r => { stepsRunning = r; UpdateButtons(); };
            recSteps.Controls.Add(recList);
            recList.ApplyTheme();
            recList.Relayout();
        }

        // Вкладка-сценарій: банери, параметри, панель дій, кроки
        Control BuildScenario(RecipeInfo r, TabInfo t)
        {
            var key = r.Name + "/" + t.Id;
            var page = new Panel { Dock = DockStyle.Fill };
            var tp = progress.Get(key);
            var boxes = new Dictionary<ParamInfo, TextBox>();

            Func<Dictionary<string, string>> values = () => boxes.ToDictionary(kv => kv.Key.Name, kv => kv.Value.Text.Trim());
            Func<string> error = () =>
            {
                foreach (var kv in boxes)
                {
                    var v = kv.Value.Text.Trim();
                    if (v.Length == 0) return "Заповніть параметр «" + (kv.Key.Title ?? kv.Key.Name) + "».";
                    if (!string.IsNullOrEmpty(kv.Key.Pattern) && !Regex.IsMatch(v, "^(?:" + kv.Key.Pattern + ")$"))
                        return "Параметр «" + (kv.Key.Title ?? kv.Key.Name) + "» має неправильний формат.";
                }
                return null;
            };

            var steps = (t.Steps ?? new List<Step>()).Select(s => new KeyValuePair<string, Step>(null, s)).ToList();
            var list = scenarioList = new StepList(theme, progress, key, steps, values, error);
            list.Status += SetStatus;
            list.RunningChanged += running => { stepsRunning = running; UpdateButtons(); };

            // Dock=Top додаються знизу вгору: останній доданий — найвище
            var tools = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, WrapContents = false, Padding = new Padding(0, 4, 0, 4) };
            tools.Controls.Add(Btn("▶ Виконати все", (s, e) => list.RunAll()));
            tools.Controls.Add(Btn("Скинути прогрес", (s, e) =>
            {
                if (MessageBox.Show(this, "Скинути позначки й вивід усіх кроків цього сценарію?", "DEADPIXEL", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK) list.Reset();
            }));

            page.Controls.Add(list);
            page.Controls.Add(tools);

            if (t.Params != null && t.Params.Count > 0)
            {
                var grid = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 3, Padding = new Padding(10, 6, 10, 6), Tag = "surface", Margin = new Padding(0, 0, 0, 6) };
                grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
                grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 260));
                grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                foreach (var prm in t.Params)
                {
                    string saved;
                    var tb = new TextBox { Width = 240, Text = tp.Params.TryGetValue(prm.Name, out saved) ? saved : prm.Default ?? "", Margin = new Padding(0, 3, 0, 3) };
                    var p = prm;
                    tb.TextChanged += (s, e) =>
                    {
                        progress.Get(key).Params[p.Name] = tb.Text;
                        progress.Save();
                        list.UpdateDisplay();
                        bool bad = !string.IsNullOrEmpty(p.Pattern) && !Regex.IsMatch(tb.Text.Trim(), "^(?:" + p.Pattern + ")$");
                        tb.ForeColor = bad ? theme.Danger : theme.Fg;
                    };
                    boxes[prm] = tb;
                    grid.Controls.Add(new Label { Text = prm.Title ?? prm.Name, AutoSize = true, Margin = new Padding(0, 7, 6, 0) });
                    grid.Controls.Add(tb);
                    grid.Controls.Add(new Label { Text = prm.Hint ?? "", AutoSize = true, Tag = "muted", Margin = new Padding(6, 7, 0, 0) });
                }
                page.Controls.Add(grid);
            }

            if (!string.IsNullOrEmpty(t.Description))
                page.Controls.Add(new Label { Text = t.Description, Dock = DockStyle.Top, Height = 36, Tag = "muted", AutoEllipsis = true, Padding = new Padding(2, 2, 0, 0) });

            if (progress.Resume == key)
            {
                page.Controls.Add(Banner("⟳ Продовжуємо сценарій після перезавантаження — наступний крок підсвічено (" + list.CurrentNumber + ").", null, null));
            }
            bool needsAdmin = (t.Steps ?? new List<Step>()).Any(s => s.Admin || s.Reboot == "firmware");
            if (needsAdmin && !Engine.IsAdmin)
                page.Controls.Add(Banner("Деякі кроки потребують прав адміністратора.", "Перезапустити з правами", () => RelaunchAsAdmin(key)));

            list.UpdateDisplay();
            return page;
        }

        Control Banner(string text, string button, Action click)
        {
            var p = new Panel { Dock = DockStyle.Top, Height = 44, Tag = "surface", Padding = new Padding(10, 7, 10, 7), Margin = new Padding(0, 0, 0, 6) };
            var l = new Label { Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Tag = "warn" };
            p.Controls.Add(l);
            if (button != null)
            {
                var b = Btn(button, (s, e) => click());
                b.Dock = DockStyle.Right;
                p.Controls.Add(b);
            }
            var wrap = new Panel { Dock = DockStyle.Top, Height = 50, Padding = new Padding(0, 0, 0, 6) };
            wrap.Controls.Add(p);
            p.Dock = DockStyle.Fill;
            return wrap;
        }

        void RelaunchAsAdmin(string key)
        {
            try
            {
                Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--open \"" + key + "\"") { UseShellExecute = true, Verb = "runas" });
                Close();
            }
            catch (Win32Exception ex)
            {
                SetStatus(ex.NativeErrorCode == 1223 ? "Скасовано: права адміністратора не надано." : "Не вдалося перезапустити: " + ex.Message, theme.Warn);
            }
        }

        static Label Caption(string text)
        {
            return new Label { Text = text, Dock = DockStyle.Fill, Tag = "accent", TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 9f) };
        }

        void ShowItemHint()
        {
            if (items.SelectedItems.Count == 0) return;
            var tag = (object[])items.SelectedItems[0].Tag;
            var it = (ItemInfo)tag[0];
            var x = (ItemResult)tag[1];
            var sb = new StringBuilder();
            sb.Append(string.IsNullOrEmpty(it.Hint) ? it.Title : it.Hint);
            if (x != null)
            {
                sb.Append("\r\n\r\n");
                switch (x.Status)
                {
                    case "OK": sb.Append("✓ Налаштовано як треба."); break;
                    case "DIFF": sb.Append("Зараз: " + x.CurrentText + ". Буде змінено на: " + x.DesiredText + "."); break;
                    case "NA": sb.Append("Недоступно на цьому ПК: " + x.Message + ". Пункт пропускається."); break;
                    case "SET": sb.Append("Застосовано (" + x.Message + " → " + x.CurrentText + ")."); break;
                    case "BACK": sb.Append("Відкочено, зараз: " + x.CurrentText + "."); break;
                    case "FAIL": sb.Append("Помилка: " + x.Message); break;
                    default: if (!string.IsNullOrEmpty(x.Message)) sb.Append(x.Message); break;
                }
            }
            hint.Text = sb.ToString();
        }

        void UpdateNavColors()
        {
            foreach (var n in AllNodes())
            {
                var r = n.Tag as RecipeInfo;
                var p = n.Tag as ProfileInfo;
                var recipes = r != null ? new List<RecipeInfo> { r } : p.Recipes.Select(x => catalog.Recipes.FirstOrDefault(y => y.Name == x)).Where(x => x != null).ToList();
                var states = recipes.Where(x => x.Items.Count > 0).Select(RecipeState).ToList();
                string st = states.Count == 0 ? null : states.Contains("FAIL") ? "FAIL" : states.Contains("DIFF") ? "DIFF" : states.Any(s => s == null) ? null : states.All(s => s == "OK" || s == "NA") ? "OK" : null;
                int diff = DiffCount(recipes);
                var baseTitle = r != null ? r.Title : p.Title;
                n.Text = diff > 0 ? baseTitle + "   · " + diff : baseTitle;
                n.ForeColor = st == null ? theme.Fg : StatusColor(st);
            }
        }

        void UpdateButtons()
        {
            var rs = SelectedRecipes();
            bool rec = currentTab == null && HasItems;
            btnCheck.Visible = btnApply.Visible = btnRevert.Visible = rec;
            btnCheck.Enabled = !busy && !stepsRunning && rs.Count > 0;
            btnApply.Enabled = !busy && !stepsRunning && rs.Count > 0;
            btnRevert.Enabled = !busy && !stepsRunning && rs.Any(r => r.HasBackup);
            btnCheckAll.Enabled = !busy && !stepsRunning;
            UseWaitCursor = busy;
        }

        static string StatusText(string st)
        {
            switch (st)
            {
                case "OK": return "✓ OK";
                case "DIFF": return "● Інакше";
                case "NA": return "— Немає";
                case "SET": return "✓ Змінено";
                case "BACK": return "↺ Відкочено";
                case "FAIL": return "✕ Помилка";
                case "SKIP": return "Пропущено";
                default: return "";
            }
        }

        Color StatusColor(string st)
        {
            switch (st)
            {
                case "OK": case "SET": return StepRow.StateColor("ok", theme);
                case "DIFF": return theme.Warn;
                case "FAIL": return theme.Danger;
                case "BACK": return theme.Accent;
                default: return theme.Muted;
            }
        }

        // ================================================================ дії зі станом (Setup.ps1)

        void RunCheck(string args, string text)
        {
            RunAsync(text, () => Engine.Run<RunResult>(args, false), res =>
            {
                var rr = (RunResult)res;
                if (rr.Error != null) { SetStatus(rr.Error, theme.Danger); return; }
                Merge(rr);
                int diff = rr.Recipes.Sum(x => x.Results.Count(i => i.Status == "DIFF"));
                if (diff == 0) SetStatus("Усе налаштовано як треба.", StatusColor("OK"));
                else SetStatus("Відхилень: " + diff + ". Виберіть рецепт або профіль і натисніть «Застосувати».", theme.Warn);
                if (pendingOpen != null && pendingOpen == progress.Resume) SetStatus("Продовжуємо сценарій після перезавантаження.", theme.Accent);
                pendingOpen = null;
            });
        }

        void RunChange(string verb)
        {
            var rs = SelectedRecipes();
            var name = selected is ProfileInfo ? ((ProfileInfo)selected).Title : rs[0].Title;
            string question;
            var uac = Engine.IsAdmin ? "" : "\n\nWindows попросить права адміністратора.";
            if (verb == "-Apply")
            {
                int diff = DiffCount(rs);
                question = "Застосувати «" + name + "»?\n\n" +
                           (diff > 0 ? "Буде змінено налаштувань: " + diff + "." : "Перевірка ще не виявила відхилень — зміниться лише те, що відрізняється.") +
                           "\nПоточні значення збережуться, їх можна буде відкотити." + uac;
            }
            else question = "Відкотити «" + name + "» до значень, що були перед останнім застосуванням?" + uac;
            if (MessageBox.Show(this, question, "DEADPIXEL", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;

            RunAsync(verb == "-Apply" ? "Застосовую…" : "Відкочую…", () => Engine.Run<RunResult>(SelectionArgs() + " " + verb, true), res =>
            {
                var rr = (RunResult)res;
                if (rr.Error != null) { SetStatus(rr.Error, theme.Danger); return; }
                Merge(rr);
                var all = rr.Recipes.SelectMany(x => x.Results).ToList();
                int fail = all.Count(x => x.Status == "FAIL");
                if (verb == "-Apply")
                {
                    int set = all.Count(x => x.Status == "SET");
                    var msg = set == 0 && fail == 0 ? "Нічого змінювати — усе вже як треба." : "Змінено: " + set + (fail > 0 ? ", помилок: " + fail : "") + ".";
                    if (recList != null && recList.CurrentNumber > 0) msg += " Перегляньте кроки вручну нижче.";
                    SetStatus(msg, fail > 0 ? theme.Danger : StatusColor("OK"));
                }
                else
                {
                    var none = rr.Recipes.Where(x => x.Results.Count == 0).Select(x => x.Title).ToList();
                    SetStatus("Відкочено: " + all.Count(x => x.Status == "BACK") + (fail > 0 ? ", помилок: " + fail : "") +
                              (none.Count > 0 ? ". Без бекапу: " + string.Join(", ", none) : "") + ".", fail > 0 ? theme.Danger : theme.Accent);
                }
            });
        }

        // Результати змін накладаються на попередню перевірку; HasBackup оновлюється в каталозі
        void Merge(RunResult rr)
        {
            foreach (var x in rr.Recipes)
            {
                results[x.Recipe] = x;
                var r = catalog.Recipes.FirstOrDefault(c => c.Name == x.Recipe);
                if (r != null) r.HasBackup = x.HasBackup;
            }
            UpdateNavColors();
            if (currentTab == null) ShowItems();
            UpdateButtons();
        }

        void RunAsync(string text, Func<object> work, Action<object> done)
        {
            busy = true;
            UpdateButtons();
            SetStatus(text, theme.Muted);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                object res = null;
                Exception err = null;
                try { res = work(); } catch (Exception ex) { err = ex; }
                try
                {
                    BeginInvoke(new Action(() =>
                    {
                        busy = false;
                        UpdateButtons();
                        var w32 = err as Win32Exception;
                        if (w32 != null && w32.NativeErrorCode == 1223) SetStatus("Скасовано: права адміністратора не надано.", theme.Warn);
                        else if (err != null) SetStatus("Помилка: " + err.Message, theme.Danger);
                        else done(res);
                    }));
                }
                catch { } // вікно вже закрито
            });
        }

        void SetStatus(string text, Color c) { status.Text = text; status.ForeColor = c; }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (stepsRunning && MessageBox.Show(this, "Виконується крок сценарію. Зупинити його й закрити вікно?", "DEADPIXEL", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                e.Cancel = true;
            base.OnFormClosing(e);
        }

        // ================================================================ побудова

        ListView MakeList(params object[] cols)
        {
            var lv = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, BorderStyle = BorderStyle.None, ShowItemToolTips = true };
            for (int i = 0; i < cols.Length; i += 2) lv.Columns.Add((string)cols[i], (int)cols[i + 1]);
            Theme.OwnerDrawHeaders(lv, () => theme);
            // колонка "Налаштування" забирає вільну ширину, решта фіксовані
            lv.Resize += (s, e) =>
            {
                int fixedW = 0;
                for (int i = 0; i < lv.Columns.Count; i++) if (i != 1) fixedW += lv.Columns[i].Width;
                lv.Columns[1].Width = Math.Max(200, lv.ClientSize.Width - fixedW - 4);
            };
            return lv;
        }

        static Control Card(Control inner) { return Card(inner, Padding.Empty); }

        static Control Card(Control inner, Padding pad)
        {
            var p = new Panel { Dock = DockStyle.Fill, Padding = pad, Tag = "surface", Margin = new Padding(0, 0, 0, 6) };
            inner.Dock = DockStyle.Fill;
            p.Controls.Add(inner);
            return p;
        }

        static Button Btn(string text, EventHandler h)
        {
            var b = new Button { Text = text, AutoSize = true, Height = 30, Padding = new Padding(10, 2, 10, 2), Margin = new Padding(0, 0, 8, 0) };
            b.Click += h;
            return b;
        }

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    }

    // Дерево без горизонтальної прокрутки: довгі назви обрізаються, повна назва — у заголовку справа
    class NavTree : TreeView
    {
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.Style |= 0x8000; return cp; } // TVS_NOHSCROLL
        }
    }
}
