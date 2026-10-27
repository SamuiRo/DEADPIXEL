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
            // --background — сканування за розкладом (Планувальник): без вікна, результат забере трей із summary.ini
            if (args.Contains("--background"))
            {
                try { ModuleHost.RunScript<AuditReport>("Audit.ps1", "-Save", false); } catch { }
                return;
            }
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
    // Хвіст, який можна перенести в карантин (поля - як у New-CleanupItem в Audit.ps1; Setup.ps1 -Cleanup читає їх назад)
    class CleanupItem
    {
        public string Kind { get; set; } public string Label { get; set; } public bool Default { get; set; } public long Size { get; set; }
        public string Target { get; set; } public string Key { get; set; } public string Name { get; set; } public string Scope { get; set; }
    }
    class CleanupOutcome { public string Label { get; set; } public string Status { get; set; } public string Message { get; set; } }
    class CleanupResult { public string Error { get; set; } public string Session { get; set; } public List<CleanupOutcome> Items { get; set; } }
    class QuarantineSession
    {
        public string Id { get; set; } public string Time { get; set; } public int AgeDays { get; set; } public int Count { get; set; }
        public long Size { get; set; } public bool Restored { get; set; } public bool CanPurge { get; set; } public List<string> Labels { get; set; }
    }
    class QuarantineList { public string Error { get; set; } public string Root { get; set; } public int Days { get; set; } public List<QuarantineSession> Sessions { get; set; } }
    class CheckResult
    {
        public string Id { get; set; } public string Area { get; set; } public string Title { get; set; }
        public string Status { get; set; } public string Severity { get; set; } public string Value { get; set; } public string Detail { get; set; }
        public List<string> Evidence { get; set; } public List<string> Files { get; set; } public bool NeedsAdmin { get; set; } public bool Ignored { get; set; }
        public bool New { get; set; }
        public List<CleanupItem> Cleanup { get; set; }
        public string Explain { get; set; } public List<string> Pros { get; set; } public List<string> Cons { get; set; }
        public FixInfo Fix { get; set; }
        public bool IsIssue { get { return Status == "issue"; } }
    }
    class AreaInfo { public string Id { get; set; } public string Title { get; set; } public int Score { get; set; } public string Grade { get; set; } public int Issues { get; set; } }
    class AuditReport
    {
        public string Error { get; set; } public string Time { get; set; } public bool IsAdmin { get; set; }
        public int Score { get; set; } public string Grade { get; set; }
        public int ScheduleDays { get; set; } public int NewCount { get; set; }
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
        // Картки переносяться на другий рядок, коли областей більше, ніж уміщує ширина вікна
        readonly FlowLayoutPanel areaBar = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true, Padding = new Padding(0, 4, 0, 6) };
        readonly ListView list;
        readonly RichTextBox details = new RichTextBox { ReadOnly = true, BorderStyle = BorderStyle.None, Tag = "surface", DetectUrls = false, ScrollBars = RichTextBoxScrollBars.Vertical };
        readonly Button btnScan, btnScanAdmin, btnSchedule, btnHtml, btnQuarantine, btnSetup, btnFix, btnOpen, btnDefender, btnCleanup, btnIgnore;
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
            btnSchedule = Ui.Btn("Розклад…", (s, e) => EditSchedule());
            btnHtml = Ui.Btn("Звіт HTML", (s, e) => ExportHtml());
            btnQuarantine = Ui.Btn("Карантин…", (s, e) => ShowQuarantine());
            btnSetup = Ui.Btn("Сетап ПК…", (s, e) => OpenSetup(null));
            var scoreBox = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Left };
            var gradeBox = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = Padding.Empty };
            gradeBox.Controls.Add(grade);
            gradeBox.Controls.Add(when);
            scoreBox.Controls.Add(score);
            scoreBox.Controls.Add(gradeBox);
            var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Right, Padding = new Padding(0, 14, 0, 0) };
            actions.Controls.AddRange(new Control[] { btnScanAdmin, btnScan, btnSchedule, btnHtml, btnQuarantine, btnSetup });
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
            btnCleanup = Ui.Btn("Прибрати…", (s, e) => { var r = Selected; if (r != null) CleanUp(r); });
            btnIgnore = Ui.Btn("Ігнорувати", (s, e) => ToggleIgnore());
            var detailBar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(0, 6, 0, 0), WrapContents = false };
            detailBar.Controls.AddRange(new Control[] { btnFix, btnCleanup, btnOpen, btnDefender, btnIgnore });
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
                if (x.Cleanup == null) x.Cleanup = new List<CleanupItem>();
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
                SetStatus(n == 0 ? "Проблем не знайдено." :
                    "Знайдено проблем: " + n + (r.NewCount > 0 ? ", нових з минулого сканування: " + r.NewCount : "") + ". Виберіть рядок, щоб побачити пояснення і що зробити.",
                    n == 0 ? ModuleHost.Ok(theme) : theme.Warn);
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
            // Побачене у вікні трей уже не повідомлятиме (той самий файл, що й у TrayApp.CheckAudit)
            try { if (!string.IsNullOrEmpty(r.Time)) File.WriteAllText(Path.Combine(ModuleHost.DataDir("audit"), "notified.txt"), r.Time); } catch { }
            score.Text = r.Score.ToString();
            score.ForeColor = grade.ForeColor = ScoreColor(r.Score);
            grade.Text = r.Grade;
            DateTime t;
            when.Text = (DateTime.TryParse(r.Time, out t) ? "Сканування " + t.ToString("dd.MM.yyyy HH:mm") : "") +
                        (r.IsAdmin ? " · з правами адміністратора" : "") +
                        (r.ScheduleDays > 0 ? " · автоматично раз на " + r.ScheduleDays + " дн." : " · розклад вимкнено");
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
            var b = new Button { Text = text, AutoSize = true, MinimumSize = new Size(150, 50), Padding = new Padding(10, 2, 10, 2), Margin = new Padding(0, 0, 6, 4), TextAlign = ContentAlignment.MiddleLeft, Tag = id == area ? "tab-selected" : "tab" };
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
                    var title = r.New && !r.Ignored ? r.Title + "   · нове" : r.Title;
                    var lvi = new ListViewItem(new[] { StatusText(r), title, r.Value }, groups[r.Area]) { Tag = r, UseItemStyleForSubItems = false, ToolTipText = r.Detail };
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
            btnCleanup.Visible = r != null && r.Cleanup.Count > 0 && !r.Ignored;
            btnIgnore.Visible = r != null && (r.IsIssue || r.Status == "info" || r.Ignored);
            if (r != null) btnIgnore.Text = r.Ignored ? "Не ігнорувати" : "Ігнорувати";
            btnFix.Enabled = btnOpen.Enabled = btnDefender.Enabled = btnCleanup.Enabled = btnIgnore.Enabled = !busy;
            if (r == null)
            {
                Add(report == null ? "Натисніть «Сканувати», щоб перевірити систему." : "Виберіть перевірку зліва.", theme.Muted, false, 10f);
                return;
            }

            Add(r.Title + "\n", theme.Fg, true, 13f);
            Add(StatusLong(r) + (string.IsNullOrEmpty(r.Value) ? "" : "  ·  " + r.Value) + "\n", StatusColor(r), true, 10f);
            if (!string.IsNullOrEmpty(r.Detail)) Add(r.Detail + "\n", theme.Fg, false, 10f);
            if (r.New && !r.Ignored) Add("Нове з минулого сканування.\n", theme.Accent, true, 9.5f);
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
            if (r.Cleanup.Count > 0)
                fixLines.Insert(0, "«Прибрати…» — виберіть, що перенести в карантин: файли переносяться, записи зберігаються, тож усе можна відновити («Карантин…»). Остаточно видалити можна через 30 днів.");
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

        // Пункти списку: висячий відступ (перенесені рядки — під текстом, а не під маркером) і невеликий проміжок
        // між пунктами — довгі докази зі шляхами інакше зливаються в суцільний текст
        void Bullets(IEnumerable<string> items, Color mark, string prefix)
        {
            bool first = true;
            foreach (var s in items)
            {
                if (!first) Add("\n", theme.Fg, false, 4f);
                first = false;
                hanging = 16;
                Add(prefix, mark, true, 10f);
                Add(s + "\n", theme.Fg, false, 10f);
                hanging = 0;
            }
        }

        int hanging;   // висячий відступ абзацу, який зараз вставляється (пікселі)

        // AppendText у RichTextBox губить колір/шрифт виділення після кількох рядків; SelectedText — ні
        // (ReadOnly на час вставки знімаємо: інакше вставка ігнорується)
        void Add(string text, Color color, bool bold, float size)
        {
            details.ReadOnly = false;
            details.SelectionStart = details.TextLength;
            details.SelectionLength = 0;
            details.SelectionHangingIndent = hanging;
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

        // ================================================================ хвости: прибирання і карантин (рушій — Setup.ps1)

        const string SetupScript = @"..\setup\Setup.ps1";

        static string SizeText(long b)
        {
            return b >= 1L << 30 ? (b / (double)(1L << 30)).ToString("0.0") + " ГБ" : b >= 1L << 20 ? (b >> 20) + " МБ" : b > 0 ? Math.Max(1, b >> 10) + " КБ" : "";
        }

        Form NewDialog(string title, int w, int h)
        {
            var f = new Form { Text = title, StartPosition = FormStartPosition.CenterParent, Font = Font, AutoScaleMode = AutoScaleMode.Dpi,
                               AutoScaleDimensions = new SizeF(96f, 96f), ClientSize = new Size(w, h), ShowInTaskbar = false, MinimizeBox = false,
                               Icon = Icon, MinimumSize = new Size(560, 380) };
            f.Load += (s, e) => { theme.Apply(f); theme.ApplyTitleBar(f); };
            return f;
        }

        // Список того, що можна прибрати: позначено те, що точно зламане; «можливі залишки» — ні
        void CleanUp(CheckResult r)
        {
            using (var dlg = NewDialog("Прибрати: " + r.Title, 760, 520))
            {
                var info = new Label { Dock = DockStyle.Top, Height = 64, Padding = new Padding(12, 10, 12, 0), Tag = "muted",
                    Text = "Позначене буде перенесено в карантин: файли й папки — у data\\quarantine, записи реєстру, завдання й правила брандмауера — зберігаються для відновлення. " +
                           "Повернути все можна кнопкою «Карантин…». Потрібні права адміністратора (UAC)." };
                var list = new CheckedListBox { Dock = DockStyle.Fill, CheckOnClick = true, BorderStyle = BorderStyle.None, IntegralHeight = false, HorizontalScrollbar = true };
                foreach (var it in r.Cleanup) list.Items.Add(it.Label, it.Default);
                var total = new Label { AutoSize = true, Padding = new Padding(4, 8, 0, 0), Tag = "muted" };
                Action recount = () =>
                {
                    long size = 0; int n = 0;
                    for (int i = 0; i < list.Items.Count; i++) if (list.GetItemChecked(i)) { n++; size += r.Cleanup[i].Size; }
                    total.Text = "Вибрано: " + n + (size > 0 ? ", " + SizeText(size) : "");
                };
                list.ItemCheck += (s, e) => BeginInvoke(recount);   // ItemCheck приходить до зміни позначки
                var all = Ui.Btn("Усі", (s, e) => { for (int i = 0; i < list.Items.Count; i++) list.SetItemChecked(i, true); recount(); });
                var none = Ui.Btn("Жодного", (s, e) => { for (int i = 0; i < list.Items.Count; i++) list.SetItemChecked(i, false); recount(); });
                var go = new Button { Text = "Перенести в карантин", DialogResult = DialogResult.OK, AutoSize = true, Height = 30, Padding = new Padding(10, 2, 10, 2) };
                var cancel = new Button { Text = "Скасувати", DialogResult = DialogResult.Cancel, AutoSize = true, Height = 30, Padding = new Padding(10, 2, 10, 2), Margin = new Padding(8, 0, 0, 0) };
                var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 46, Padding = new Padding(12, 8, 12, 6), WrapContents = false };
                bar.Controls.AddRange(new Control[] { all, none, total });
                var right = new FlowLayoutPanel { Dock = DockStyle.Right, AutoSize = true, WrapContents = false, Padding = new Padding(0, 8, 12, 6) };
                right.Controls.AddRange(new Control[] { go, cancel });
                var bottom = new Panel { Dock = DockStyle.Bottom, Height = 46 };
                bottom.Controls.Add(bar);
                bottom.Controls.Add(right);
                var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12, 6, 12, 0) };
                body.Controls.Add(Ui.Card(list, new Padding(6)));
                dlg.Controls.Add(body);
                dlg.Controls.Add(bottom);
                dlg.Controls.Add(info);
                dlg.AcceptButton = go; dlg.CancelButton = cancel;
                dlg.Shown += (s, e) => recount();
                if (dlg.ShowDialog(this) != DialogResult.OK) return;

                var chosen = new List<CleanupItem>();
                for (int i = 0; i < list.Items.Count; i++) if (list.GetItemChecked(i)) chosen.Add(r.Cleanup[i]);
                if (chosen.Count == 0) return;
                var tmp = Path.Combine(Path.GetTempPath(), "deadpixel-cleanup-" + Guid.NewGuid().ToString("N") + ".json");
                File.WriteAllText(tmp, new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(chosen), new UTF8Encoding(false));
                RunAsync("Переношу в карантин: " + chosen.Count + "…", () =>
                {
                    try { return ModuleHost.RunScript<CleanupResult>(SetupScript, "-Cleanup \"" + tmp + "\"", true); }
                    finally { try { File.Delete(tmp); } catch { } }
                }, res =>
                {
                    var cr = (CleanupResult)res;
                    if (cr.Error != null) { SetStatus(cr.Error, theme.Danger); return; }
                    var items = cr.Items ?? new List<CleanupOutcome>();
                    int moved = items.Count(x => x.Status == "MOVED"), skipped = items.Count - moved;
                    SetStatus("У карантині: " + moved + (skipped > 0 ? ", пропущено: " + skipped : "") + ". Повернути — «Карантин…».", skipped > 0 ? theme.Warn : ModuleHost.Ok(theme));
                    if (skipped > 0)
                        MessageBox.Show(this, string.Join("\n", items.Where(x => x.Status != "MOVED").Select(x => "— " + x.Label + ": " + x.Message)),
                            "DEADPIXEL — пропущено", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    Scan(false);
                });
            }
        }

        void ShowQuarantine()
        {
            using (var dlg = NewDialog("Карантин", 820, 460))
            {
                var list = Ui.List(() => theme, 1, "Дата", 130, "Що", 420, "Розмір", 90, "Стан", 140);
                var info = new Label { Dock = DockStyle.Top, Height = 44, Padding = new Padding(12, 10, 12, 0), Tag = "muted" };
                QuarantineList data = null;
                Action load = () =>
                {
                    UseWaitCursor = dlg.UseWaitCursor = true;
                    try { data = ModuleHost.RunScript<QuarantineList>(SetupScript, "-Quarantine", false); }
                    catch (Exception ex) { data = new QuarantineList { Error = ex.Message }; }
                    finally { UseWaitCursor = dlg.UseWaitCursor = false; }
                    list.Items.Clear();
                    if (data.Error != null) { info.Text = data.Error; return; }
                    info.Text = "Сесії прибирання. «Відновити» повертає все на місце. «Видалити назавжди» стає доступним через " + data.Days +
                                " днів — час помітити, якщо щось перестало працювати. Папка: " + data.Root;
                    foreach (var s in data.Sessions ?? new List<QuarantineSession>())
                    {
                        DateTime t; DateTime.TryParse(s.Time, out t);
                        var what = s.Count + " шт.: " + string.Join("; ", (s.Labels ?? new List<string>()).Take(3)) + ((s.Labels ?? new List<string>()).Count > 3 ? "…" : "");
                        var state = s.Restored ? "відновлено" : s.CanPurge ? "можна видалити" : "ще " + Math.Max(1, data.Days - s.AgeDays) + " дн.";
                        list.Items.Add(new ListViewItem(new[] { t.ToString("dd.MM.yyyy HH:mm"), what, SizeText(s.Size), state }) { Tag = s, ToolTipText = string.Join("\n", s.Labels ?? new List<string>()) });
                    }
                };
                Func<QuarantineSession> sel = () => list.SelectedItems.Count == 0 ? null : (QuarantineSession)list.SelectedItems[0].Tag;
                Action<string, string> act = (verb, id) =>
                {
                    UseWaitCursor = dlg.UseWaitCursor = true;
                    CleanupResult res;
                    try { res = ModuleHost.RunScript<CleanupResult>(SetupScript, verb + " \"" + id + "\"", true); }
                    catch (Win32Exception) { res = new CleanupResult { Error = "Скасовано: права адміністратора не надано." }; }
                    catch (Exception ex) { res = new CleanupResult { Error = ex.Message }; }
                    finally { UseWaitCursor = dlg.UseWaitCursor = false; }
                    var items = res.Items ?? new List<CleanupOutcome>();
                    var msg = res.Error ?? (items.Count == 0 ? "Готово." : string.Join("\n", items.Select(x => (x.Status == "RESTORED" ? "✓ " : "✕ ") + x.Label + (string.IsNullOrEmpty(x.Message) ? "" : " — " + x.Message))));
                    MessageBox.Show(dlg, msg, "DEADPIXEL — карантин", MessageBoxButtons.OK, res.Error != null || items.Any(x => x.Status == "FAIL") ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
                    load();
                };
                var restore = Ui.Btn("Відновити", (s, e) => { var q = sel(); if (q != null && !q.Restored) act("-Restore", q.Id); });
                var purge = Ui.Btn("Видалити назавжди", (s, e) =>
                {
                    var q = sel();
                    if (q == null || !q.CanPurge) return;
                    if (MessageBox.Show(dlg, "Остаточно видалити " + q.Count + " шт. (" + SizeText(q.Size) + ")? Відновити буде неможливо.", "DEADPIXEL",
                                        MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK) act("-Purge", q.Id);
                });
                var folder = Ui.Btn("Відкрити папку", (s, e) => { if (data != null && data.Root != null) TryOpen(data.Root); });
                list.SelectedIndexChanged += (s, e) => { var q = sel(); restore.Enabled = q != null && !q.Restored; purge.Enabled = q != null && q.CanPurge; };
                restore.Enabled = purge.Enabled = false;
                var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 46, Padding = new Padding(12, 8, 12, 6), WrapContents = false };
                bar.Controls.AddRange(new Control[] { restore, purge, folder });
                var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12, 6, 12, 0) };
                body.Controls.Add(Ui.Card(list));
                dlg.Controls.Add(body);
                dlg.Controls.Add(bar);
                dlg.Controls.Add(info);
                dlg.Shown += (s, e) => { if (theme.Dark) SetWindowTheme(list.Handle, "DarkMode_ItemsView", null); load(); };
                dlg.ShowDialog(this);
            }
        }

        // Розклад — завдання Планувальника з найвищими правами (бачить усі процеси), тому зміна потребує UAC
        void EditSchedule()
        {
            int current = report != null ? report.ScheduleDays : 0;
            using (var dlg = new Form { Text = "Розклад аудиту", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
                                        StartPosition = FormStartPosition.CenterParent, Font = Font, AutoScaleMode = AutoScaleMode.Dpi, AutoScaleDimensions = new SizeF(96f, 96f),
                                        ClientSize = new Size(470, 230), ShowInTaskbar = false })
            {
                var on = new CheckBox { Text = "Сканувати автоматично", Checked = current > 0, AutoSize = true, Location = new Point(18, 18) };
                var lbl = new Label { Text = "раз на", AutoSize = true, Location = new Point(40, 54) };
                var days = new NumericUpDown { Minimum = 1, Maximum = 30, Value = current > 0 ? current : 3, Width = 60, Location = new Point(96, 50) };
                var lbl2 = new Label { Text = "дн.", AutoSize = true, Location = new Point(162, 54) };
                var info = new Label { Tag = "muted", Location = new Point(18, 90), Size = new Size(434, 84),
                    Text = "Аудит запуститься у фоні з низьким пріоритетом (о 12:00, або щойно ПК увімкнуть, якщо час пропущено) і займе кілька секунд. " +
                           "Трей повідомить лише про нові серйозні проблеми. Зміна розкладу потребує прав адміністратора: з ними аудит бачить усі процеси." };
                var ok = new Button { Text = "Зберегти", DialogResult = DialogResult.OK, AutoSize = true, Location = new Point(270, 186) };
                var cancel = new Button { Text = "Скасувати", DialogResult = DialogResult.Cancel, AutoSize = true, Location = new Point(362, 186) };
                on.CheckedChanged += (s, e) => days.Enabled = lbl.Enabled = lbl2.Enabled = on.Checked;
                days.Enabled = lbl.Enabled = lbl2.Enabled = on.Checked;
                dlg.Controls.AddRange(new Control[] { on, lbl, days, lbl2, info, ok, cancel });
                dlg.AcceptButton = ok; dlg.CancelButton = cancel;
                dlg.Load += (s, e) => { theme.Apply(dlg); theme.ApplyTitleBar(dlg); };
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                int n = on.Checked ? (int)days.Value : 0;
                if (n == current) return;
                RunAsync("Зберігаю розклад…", () => ModuleHost.RunScript<AuditReport>("Audit.ps1", "-Schedule " + n, true), res =>
                {
                    var r = Normalize((AuditReport)res);
                    if (r.Error != null) { SetStatus(r.Error, theme.Danger); return; }
                    if (report != null) { report.ScheduleDays = r.ScheduleDays; ShowReport(report); }
                    SetStatus(r.ScheduleDays > 0 ? "Аудит запускатиметься автоматично раз на " + r.ScheduleDays + " дн." : "Автоматичний аудит вимкнено.", theme.Muted);
                });
            }
        }

        // HTML-звіт — у reports\ поруч із програмою (там і звіти DeadPixel.ps1), інакше в %LOCALAPPDATA%\DeadPixel\reports
        void ExportHtml()
        {
            if (report == null) { SetStatus("Спершу запустіть сканування.", theme.Warn); return; }
            var dir = Path.GetFullPath(Path.Combine(ModuleHost.Dir, @"..\..\reports"));
            try { Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, ".write-test"), ""); File.Delete(Path.Combine(dir, ".write-test")); }
            catch { dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DeadPixel\reports"); }
            var path = Path.Combine(dir, "audit-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".html");
            RunAsync("Створюю звіт…", () => ModuleHost.RunScript<AuditReport>("Audit.ps1", "-Html \"" + path + "\"", false), res =>
            {
                var r = (AuditReport)res;
                if (r.Error != null) { SetStatus(r.Error, theme.Danger); return; }
                SetStatus("Звіт: " + path, theme.Muted);
                TryOpen(path);
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
            btnScan.Enabled = btnScanAdmin.Enabled = btnSchedule.Enabled = btnHtml.Enabled = btnQuarantine.Enabled = !busy;
            btnFix.Enabled = btnOpen.Enabled = btnDefender.Enabled = btnCleanup.Enabled = btnIgnore.Enabled = !busy;
            UseWaitCursor = busy;
        }

        void SetStatus(string text, Color c) { status.Text = text; status.ForeColor = c; }

        [System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    }
}
