// DEADPIXEL Audit GUI — окремий процес модуля аудиту: трей лише запускає його.
// Перевірки, оцінку й список ігнорованого веде Audit.ps1 — GUI викликає його з -OutFile і показує JSON.
// Аудит нічого не змінює: кнопка «Виправити…» відкриває рецепт у Сетапі ПК (там видно зміни і є відкат).
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace DeadPixel
{
    static class AuditProgram
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            // --check <id> — відкрити з виділеною перевіркою (для сповіщень трея)
            string check = null;
            for (int i = 0; i < args.Length; i++)
                if (args[i] == "--check" && i + 1 < args.Length) check = args[i + 1];
            Application.Run(new AuditForm(check));
        }
    }

    // ---------------------------------------------------------------- JSON-контракт Audit.ps1

    class FixInfo { public string Recipe { get; set; } public string Open { get; set; } public List<string> Steps { get; set; } }
    class CheckResult
    {
        public string Id { get; set; } public string Area { get; set; } public string Title { get; set; }
        public string Status { get; set; } public string Severity { get; set; } public string Value { get; set; } public string Detail { get; set; }
        public List<string> Evidence { get; set; } public List<string> Files { get; set; } public bool NeedsAdmin { get; set; } public bool Ignored { get; set; }
        public string Explain { get; set; } public List<string> Pros { get; set; } public List<string> Cons { get; set; }
        public FixInfo Fix { get; set; }
        public bool IsIssue { get { return Status == "issue"; } }
    }
    class AreaInfo { public string Id { get; set; } public string Title { get; set; } public int Score { get; set; } public string Grade { get; set; } public int Issues { get; set; } }
    class AuditReport
    {
        public string Error { get; set; } public string Time { get; set; } public bool IsAdmin { get; set; }
        public int Score { get; set; } public string Grade { get; set; }
        public List<AreaInfo> Areas { get; set; } public List<CheckResult> Results { get; set; }
    }

    class AuditForm : Form
    {
        readonly Theme theme = ModuleHost.LoadTheme();
        AuditReport report;
        string area;            // null — усі області
        string focusId;         // перевірка, яку виділити після завантаження
        bool busy;

        readonly Label score = new Label { AutoSize = true, Font = new Font("Segoe UI Semibold", 30f), Margin = new Padding(0, 0, 12, 0) };
        readonly Label grade = new Label { AutoSize = true, Font = new Font("Segoe UI Semibold", 13f), Margin = new Padding(0, 10, 0, 0) };
        readonly Label when = new Label { AutoSize = true, Tag = "muted", Margin = new Padding(0, 2, 0, 0) };
        readonly FlowLayoutPanel areaBar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 64, WrapContents = false, AutoScroll = false, Padding = new Padding(0, 4, 0, 6) };
        readonly ListView list;
        readonly RichTextBox details = new RichTextBox { ReadOnly = true, BorderStyle = BorderStyle.None, Tag = "surface", DetectUrls = false, ScrollBars = RichTextBoxScrollBars.Vertical };
        readonly Button btnScan, btnScanAdmin, btnSetup, btnFix, btnOpen, btnDefender, btnIgnore;
        readonly Label status = new Label { AutoSize = true, Padding = new Padding(6, 7, 0, 0), Tag = "muted" };

        public AuditForm(string check)
        {
            focusId = check;
            Text = "DEADPIXEL — Аудит системи" + (ModuleHost.IsAdmin ? " (адміністратор)" : "");
            Font = new Font("Segoe UI", 9f);
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            Size = new Size(1240, Math.Min(860, Screen.PrimaryScreen.WorkingArea.Height - 40));
            MinimumSize = new Size(960, 600);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            // ---- шапка: оцінка і кнопки
            btnScan = Ui.Btn("Сканувати", (s, e) => Scan(false));
            btnScanAdmin = Ui.Btn("Сканувати з правами", (s, e) => Scan(true));
            btnSetup = Ui.Btn("Сетап ПК…", (s, e) => OpenSetup(null));
            var scoreBox = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Left };
            var gradeBox = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = Padding.Empty };
            gradeBox.Controls.Add(grade);
            gradeBox.Controls.Add(when);
            scoreBox.Controls.Add(score);
            scoreBox.Controls.Add(gradeBox);
            var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Right, Padding = new Padding(0, 14, 0, 0) };
            actions.Controls.AddRange(new Control[] { btnScanAdmin, btnScan, btnSetup });
            var header = new Panel { Dock = DockStyle.Top, Height = 70 };
            header.Controls.Add(scoreBox);
            header.Controls.Add(actions);

            // ---- список і подробиці
            list = Ui.List(() => theme, 1, "Стан", 120, "Перевірка", 300, "Зараз", 210);
            list.ShowGroups = true;
            list.SelectedIndexChanged += (s, e) => ShowDetails();
            btnFix = Ui.Btn("Виправити…", (s, e) => { var r = Selected; if (r != null) OpenSetup(r.Fix.Recipe); });
            btnOpen = Ui.Btn("Відкрити в Windows", (s, e) => { var r = Selected; if (r != null) TryOpen(r.Fix.Open); });
            btnDefender = Ui.Btn("Перевірити Defender'ом", (s, e) => { var r = Selected; if (r != null) ScanFiles(r.Files); });
            btnIgnore = Ui.Btn("Ігнорувати", (s, e) => ToggleIgnore());
            var detailBar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(0, 6, 0, 0), WrapContents = false };
            detailBar.Controls.AddRange(new Control[] { btnFix, btnOpen, btnDefender, btnIgnore });
            var right = new Panel { Dock = DockStyle.Fill, Padding = new Padding(6, 0, 0, 0) };
            right.Controls.Add(Ui.Card(details, new Padding(12, 10, 8, 8)));
            right.Controls.Add(detailBar);

            var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
            body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 54));
            body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 46));
            body.Controls.Add(Ui.Card(list), 0, 0);
            body.Controls.Add(right, 1, 0);

            var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 32, WrapContents = false };
            bottom.Controls.Add(status);

            var root = new Panel { Dock = DockStyle.Fill, Padding = new Padding(14, 8, 14, 6) };
            root.Controls.Add(body);
            root.Controls.Add(areaBar);
            root.Controls.Add(header);
            root.Controls.Add(bottom);
            Controls.Add(root);

            Load += (s, e) =>
            {
                theme.Apply(this);
                theme.ApplyTitleBar(this);
                if (theme.Dark) SetWindowTheme(list.Handle, "DarkMode_ItemsView", null);
                ShowReport(LoadLatest());
                // Останній звіт видно одразу; якщо він старший за годину або його немає — оновлюємо (сканування ~3 с)
                DateTime t;
                if (report == null || !DateTime.TryParse(report.Time, out t) || DateTime.Now - t > TimeSpan.FromHours(1)) Scan(false);
                else SetStatus("Показано звіт від " + t.ToString("dd.MM.yyyy HH:mm") + ".", theme.Muted);
            };
        }

        CheckResult Selected
        {
            get { return list.SelectedItems.Count == 0 ? null : list.SelectedItems[0].Tag as CheckResult; }
        }

        // ================================================================ дані

        static AuditReport LoadLatest()
        {
            try
            {
                var f = Path.Combine(ModuleHost.DataDir("audit"), "latest.json");
                return File.Exists(f) ? Normalize(ModuleHost.Deserialize<AuditReport>(File.ReadAllText(f, Encoding.UTF8))) : null;
            }
            catch { return null; }
        }

        // Порожні масиви з PowerShell можуть прийти як null — далі код не перевіряє їх щоразу
        static AuditReport Normalize(AuditReport r)
        {
            if (r == null) return null;
            if (r.Areas == null) r.Areas = new List<AreaInfo>();
            if (r.Results == null) r.Results = new List<CheckResult>();
            foreach (var x in r.Results)
            {
                if (x.Evidence == null) x.Evidence = new List<string>();
                if (x.Files == null) x.Files = new List<string>();
                if (x.Pros == null) x.Pros = new List<string>();
                if (x.Cons == null) x.Cons = new List<string>();
                if (x.Fix == null) x.Fix = new FixInfo();
                if (x.Fix.Steps == null) x.Fix.Steps = new List<string>();
            }
            return r;
        }

        void Scan(bool elevate)
        {
            RunAsync(elevate ? "Сканую з правами адміністратора…" : "Сканую систему…", () => ModuleHost.RunScript<AuditReport>("Audit.ps1", "-Save", elevate), res =>
            {
                var r = Normalize((AuditReport)res);
                if (r.Error != null) { SetStatus(r.Error, theme.Danger); return; }
                ShowReport(r);
                int n = r.Results.Count(x => x.IsIssue && !x.Ignored);
                SetStatus(n == 0 ? "Проблем не знайдено." : "Знайдено проблем: " + n + ". Виберіть рядок, щоб побачити пояснення і що зробити.", n == 0 ? ModuleHost.Ok(theme) : theme.Warn);
            });
        }

        void ToggleIgnore()
        {
            var r = Selected;
            if (r == null) return;
            focusId = r.Id;
            var args = (r.Ignored ? "-Unignore " : "-Ignore ") + "\"" + r.Id + "\"";
            RunAsync("Оновлюю список ігнорованого…", () => ModuleHost.RunScript<AuditReport>("Audit.ps1", args, false), res =>
            {
                var rep = Normalize((AuditReport)res);
                if (rep.Error != null) { SetStatus(rep.Error, theme.Danger); return; }
                ShowReport(rep);
                SetStatus(r.Ignored ? "Знахідка знову враховується." : "«" + r.Title + "» більше не враховується в оцінці (видно сірим унизу).", theme.Muted);
            });
        }

        // ================================================================ відображення

        void ShowReport(AuditReport r)
        {
            report = r;
            if (r == null)
            {
                score.Text = "—"; score.ForeColor = theme.Muted;
                grade.Text = "Ще не сканувалося"; grade.ForeColor = theme.Fg;
                when.Text = "";
                list.Items.Clear();
                BuildAreaBar();
                ShowDetails();
                return;
            }
            score.Text = r.Score.ToString();
            score.ForeColor = grade.ForeColor = ScoreColor(r.Score);
            grade.Text = r.Grade;
            DateTime t;
            when.Text = (DateTime.TryParse(r.Time, out t) ? "Сканування " + t.ToString("dd.MM.yyyy HH:mm") : "") +
                        (r.IsAdmin ? " · з правами адміністратора" : "");
            if (area != null && !r.Areas.Any(a => a.Id == area)) area = null;
            BuildAreaBar();
            FillList();
            btnScanAdmin.Visible = !ModuleHost.IsAdmin && r.Results.Any(x => x.NeedsAdmin);
        }

        // Картки областей — фільтр списку. Tag кнопки зайнятий стилем теми ("tab"/"tab-selected"), тож колір
        // за кількістю проблем ставимо після theme.Apply
        void BuildAreaBar()
        {
            areaBar.Controls.Clear();
            var colored = new List<KeyValuePair<Button, int>>();
            if (report != null)
            {
                colored.Add(AreaButton(null, "Усі області", report.Results.Count(x => x.IsIssue && !x.Ignored)));
                foreach (var a in report.Areas) colored.Add(AreaButton(a.Id, a.Title + "  ·  " + a.Score, a.Issues));
            }
            foreach (var kv in colored) areaBar.Controls.Add(kv.Key);
            theme.Apply(areaBar);
            foreach (var kv in colored)
                if ((string)kv.Key.Tag != "tab-selected") kv.Key.ForeColor = kv.Value > 0 ? theme.Warn : ModuleHost.Ok(theme);
        }

        KeyValuePair<Button, int> AreaButton(string id, string title, int issues)
        {
            var text = title + "\n" + (issues == 0 ? "проблем немає" : issues + " " + Plural(issues, "проблема", "проблеми", "проблем"));
            var b = new Button { Text = text, AutoSize = true, MinimumSize = new Size(150, 50), Padding = new Padding(10, 2, 10, 2), Margin = new Padding(0, 0, 6, 0), TextAlign = ContentAlignment.MiddleLeft, Tag = id == area ? "tab-selected" : "tab" };
            b.Click += (s, e) => { if (busy) return; area = id; BuildAreaBar(); FillList(); };
            return new KeyValuePair<Button, int>(b, issues);
        }

        // Порядок: найнебезпечніше вгорі; ігноровані, інформаційні й «гаразд» — нижче
        static int Rank(CheckResult r)
        {
            if (r.Ignored) return 7;
            switch (r.Status)
            {
                case "issue": return r.Severity == "critical" ? 0 : r.Severity == "high" ? 1 : r.Severity == "medium" ? 2 : 3;
                case "unknown": return 4;
                case "info": return 5;
                case "ok": return 6;
                default: return 8;
            }
        }

        void FillList()
        {
            var keep = focusId ?? (Selected != null ? Selected.Id : null);
            list.BeginUpdate();
            list.Items.Clear();
            list.Groups.Clear();
            if (report != null)
            {
                var groups = new Dictionary<string, ListViewGroup>();
                foreach (var a in report.Areas)
                {
                    if (area != null && a.Id != area) continue;
                    var g = new ListViewGroup(a.Title);
                    groups[a.Id] = g;
                    list.Groups.Add(g);
                }
                foreach (var r in report.Results.Where(x => groups.ContainsKey(x.Area)).OrderBy(Rank))
                {
                    var lvi = new ListViewItem(new[] { StatusText(r), r.Title, r.Value }, groups[r.Area]) { Tag = r, UseItemStyleForSubItems = false, ToolTipText = r.Detail };
                    lvi.SubItems[0].ForeColor = StatusColor(r);
                    lvi.SubItems[0].Font = new Font(list.Font, FontStyle.Bold);
                    if (r.Ignored || r.Status == "na") lvi.SubItems[1].ForeColor = lvi.SubItems[2].ForeColor = theme.Muted;
                    list.Items.Add(lvi);
                }
            }
            list.EndUpdate();
            ListViewItem sel = null;
            if (keep != null) sel = list.Items.Cast<ListViewItem>().FirstOrDefault(i => ((CheckResult)i.Tag).Id == keep);
            if (sel == null && list.Items.Count > 0) sel = list.Items[0];
            if (sel != null) { sel.Selected = true; sel.Focused = true; sel.EnsureVisible(); }
            focusId = null;
            ShowDetails();
        }

        void ShowDetails()
        {
            var r = Selected;
            details.Clear();
            btnFix.Visible = r != null && !string.IsNullOrEmpty(r.Fix.Recipe);
            btnOpen.Visible = r != null && !string.IsNullOrEmpty(r.Fix.Open);
            btnDefender.Visible = r != null && r.Files.Count > 0;
            btnIgnore.Visible = r != null && (r.IsIssue || r.Status == "info" || r.Ignored);
            if (r != null) btnIgnore.Text = r.Ignored ? "Не ігнорувати" : "Ігнорувати";
            btnFix.Enabled = btnOpen.Enabled = btnDefender.Enabled = btnIgnore.Enabled = !busy;
            if (r == null)
            {
                Add(report == null ? "Натисніть «Сканувати», щоб перевірити систему." : "Виберіть перевірку зліва.", theme.Muted, false, 10f);
                return;
            }

            Add(r.Title + "\n", theme.Fg, true, 13f);
            Add(StatusLong(r) + (string.IsNullOrEmpty(r.Value) ? "" : "  ·  " + r.Value) + "\n", StatusColor(r), true, 10f);
            if (!string.IsNullOrEmpty(r.Detail)) Add(r.Detail + "\n", theme.Fg, false, 10f);
            if (r.Ignored) Add("Ви позначили це як свідомий вибір — знахідка не враховується в оцінці.\n", theme.Muted, false, 9.5f);
            if (r.NeedsAdmin) Add("Щоб перевірити точно, натисніть «Сканувати з правами».\n", theme.Warn, false, 9.5f);

            if (!string.IsNullOrEmpty(r.Explain)) { Heading("Що це"); Add(r.Explain + "\n", theme.Fg, false, 10f); }
            if (r.Pros.Count > 0) { Heading("Плюси"); Bullets(r.Pros, ModuleHost.Ok(theme), "+  "); }
            if (r.Cons.Count > 0) { Heading("Мінуси і на що зважити"); Bullets(r.Cons, theme.Warn, "−  "); }
            if (r.Evidence.Count > 0) { Heading("Докази"); Bullets(r.Evidence, theme.Muted, "·  "); }

            var fixLines = new List<string>(r.Fix.Steps);
            if (!string.IsNullOrEmpty(r.Fix.Recipe))
                fixLines.Insert(0, "«Виправити…» відкриє рецепт у Сетапі ПК: там видно, що саме зміниться, а поточні значення зберігаються для відкату.");
            if (!string.IsNullOrEmpty(r.Fix.Open))
                fixLines.Add("«Відкрити в Windows» — відповідне вікно налаштувань.");
            if (r.Files.Count > 0)
                fixLines.Insert(0, "«Перевірити Defender'ом» — перевірка підозрілих файлів (" + r.Files.Count + "); нічого не видаляє, лише повідомляє результат.");
            if ((r.IsIssue || r.Status == "info") && fixLines.Count > 0) { Heading("Як виправити"); Bullets(fixLines, theme.Fg, "→  "); }
            details.SelectionStart = 0;
            details.ScrollToCaret();
        }

        // Перенос рядка — окремо: якщо вставити його разом із заголовком, RichEdit бере формат попереднього абзацу
        void Heading(string text)
        {
            Add("\n", theme.Fg, false, 6f);
            Add(text + "\n", theme.Accent, true, 10.5f);
        }

        void Bullets(IEnumerable<string> items, Color mark, string prefix)
        {
            foreach (var s in items)
            {
                Add(prefix, mark, true, 10f);
                Add(s + "\n", theme.Fg, false, 10f);
            }
        }

        // AppendText у RichTextBox губить колір/шрифт виділення після кількох рядків; SelectedText — ні
        // (ReadOnly на час вставки знімаємо: інакше вставка ігнорується)
        void Add(string text, Color color, bool bold, float size)
        {
            details.ReadOnly = false;
            details.SelectionStart = details.TextLength;
            details.SelectionLength = 0;
            details.SelectionColor = color;
            details.SelectionFont = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
            details.SelectedText = text;
            details.ReadOnly = true;
        }

        static string StatusText(CheckResult r)
        {
            if (r.Ignored) return "◌ Ігнор.";
            switch (r.Status)
            {
                case "ok": return "✓ Гаразд";
                case "info": return "ℹ Інфо";
                case "unknown": return "? Невідомо";
                case "na": return "— Н/д";
            }
            switch (r.Severity)
            {
                case "critical": return "✕ Критично";
                case "high": return "✕ Високий";
                case "medium": return "● Середній";
                default: return "● Низький";
            }
        }

        static string StatusLong(CheckResult r)
        {
            if (r.Status == "ok") return "Усе гаразд";
            if (r.Status == "info") return "Для інформації";
            if (r.Status == "unknown") return "Не вдалося перевірити";
            if (r.Status == "na") return "Не стосується цього ПК";
            switch (r.Severity)
            {
                case "critical": return "Критичний ризик";
                case "high": return "Високий ризик";
                case "medium": return "Середній ризик";
                default: return "Низький ризик";
            }
        }

        Color StatusColor(CheckResult r)
        {
            if (r.Ignored) return theme.Muted;
            switch (r.Status)
            {
                case "ok": return ModuleHost.Ok(theme);
                case "info": return theme.Accent;
                case "unknown": case "na": return theme.Muted;
            }
            return r.Severity == "critical" || r.Severity == "high" ? theme.Danger : theme.Warn;
        }

        Color ScoreColor(int s) { return s >= 85 ? ModuleHost.Ok(theme) : s >= 40 ? theme.Warn : theme.Danger; }

        static string Plural(int n, string one, string few, string many)
        {
            int m10 = n % 10, m100 = n % 100;
            if (m10 == 1 && m100 != 11) return one;
            if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return few;
            return many;
        }

        // ================================================================ дії

        // Рецепти живуть у модулі Setup: аудит лише відкриває потрібний (--open вибирає його в списку)
        void OpenSetup(string recipe)
        {
            var exe = Path.GetFullPath(Path.Combine(ModuleHost.Dir, @"..\setup\SetupGui.exe"));
            if (!File.Exists(exe)) { SetStatus("Не знайдено " + exe, theme.Danger); return; }
            try { Process.Start(new ProcessStartInfo(exe, recipe == null ? "" : "--open \"" + recipe + "\"") { UseShellExecute = true }); }
            catch (Exception ex) { SetStatus(ex.Message, theme.Danger); }
        }

        // Перевірка файлів Microsoft Defender без лікування (-DisableRemediation): аудит нічого не змінює сам.
        // Код виходу MpCmdRun: 0 — загроз немає, 2 — знайдено загрозу, інше — помилка сканування
        void ScanFiles(List<string> files)
        {
            var mp = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Windows Defender\MpCmdRun.exe");
            if (!File.Exists(mp)) { SetStatus("Microsoft Defender не знайдено (працює інший антивірус?) — перевірте файли ним.", theme.Warn); return; }
            var list = files.Take(20).ToList();
            RunAsync("Defender перевіряє файлів: " + list.Count + "…", () =>
            {
                var lines = new List<string>();
                int threats = 0, errors = 0;
                foreach (var f in list)
                {
                    if (!File.Exists(f)) { lines.Add("—  " + f + " (файлу вже немає)"); continue; }
                    var psi = new ProcessStartInfo(mp, "-Scan -ScanType 3 -File \"" + f + "\" -DisableRemediation")
                    { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, StandardOutputEncoding = Encoding.UTF8 };
                    using (var p = Process.Start(psi))
                    {
                        var output = p.StandardOutput.ReadToEnd();
                        p.WaitForExit();
                        if (p.ExitCode == 0) lines.Add("✓  " + f);
                        else if (p.ExitCode == 2) { threats++; lines.Add("✕  " + f + "  — ЗАГРОЗА: " + string.Join("; ", output.Split('\n').Where(l => l.IndexOf("Threat", StringComparison.OrdinalIgnoreCase) >= 0).Select(l => l.Trim()))); }
                        else { errors++; lines.Add("?  " + f + "  — не вдалося перевірити (код " + p.ExitCode + ")"); }
                    }
                }
                return new object[] { threats, errors, lines };
            }, res =>
            {
                var a = (object[])res;
                int threats = (int)a[0], errors = (int)a[1];
                var lines = (List<string>)a[2];
                if (threats > 0) SetStatus("Defender знайшов загроз: " + threats + ". Відкрийте «Безпека Windows», щоб видалити їх.", theme.Danger);
                else if (errors > 0) SetStatus("Загроз не знайдено, але " + errors + " файл(и) перевірити не вдалося.", theme.Warn);
                else SetStatus("Defender: загроз не знайдено (" + list.Count + " файл.). Підозра лишається, якщо ви не впізнаєте програму.", ModuleHost.Ok(theme));
                MessageBox.Show(this, string.Join("\n", lines) + (threats > 0 ? "\n\nЗагрозу не видалено: зробіть це в «Безпека Windows» → «Захист від вірусів і загроз»." : ""),
                    "DEADPIXEL — перевірка Defender'ом", MessageBoxButtons.OK, threats > 0 ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
            });
        }

        void TryOpen(string what)
        {
            try { ModuleHost.Open(what); }
            catch (Exception ex) { SetStatus("Не вдалося відкрити: " + ex.Message, theme.Danger); }
        }

        void RunAsync(string text, Func<object> work, Action<object> done)
        {
            busy = true;
            UpdateBusy();
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
                        UpdateBusy();
                        var w32 = err as Win32Exception;
                        if (w32 != null && w32.NativeErrorCode == 1223) SetStatus("Скасовано: права адміністратора не надано.", theme.Warn);
                        else if (err != null) SetStatus("Помилка: " + err.Message, theme.Danger);
                        else done(res);
                    }));
                }
                catch { } // вікно вже закрито
            });
        }

        void UpdateBusy()
        {
            btnScan.Enabled = btnScanAdmin.Enabled = !busy;
            btnFix.Enabled = btnOpen.Enabled = btnDefender.Enabled = btnIgnore.Enabled = !busy;
            UseWaitCursor = busy;
        }

        void SetStatus(string text, Color c) { status.Text = text; status.ForeColor = c; }

        [System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    }
}
