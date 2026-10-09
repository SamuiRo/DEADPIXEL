// DEADPIXEL Setup GUI — окремий процес модуля налаштувань: трей лише запускає його.
// Уся логіка (рецепти, бекапи, відкат) — у Setup.ps1; GUI викликає його з -OutFile і показує JSON-результат.
// Перевірка йде з правами користувача, застосування/відкат — через UAC лише на час дії.
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
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadPixel
{
    static class SetupProgram
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupForm());
        }
    }

    // ---------------------------------------------------------------- JSON-контракт Setup.ps1

    class Step { public string Text { get; set; } public string Run { get; set; } }
    class ItemInfo { public string Id { get; set; } public string Title { get; set; } public string Hint { get; set; } public string DesiredText { get; set; } }
    class RecipeInfo
    {
        public string Name { get; set; } public string Title { get; set; } public string Description { get; set; }
        public bool Reboot { get; set; } public bool HasBackup { get; set; }
        public List<Step> Steps { get; set; } public List<ItemInfo> Items { get; set; }
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

    // ---------------------------------------------------------------- вікно

    class SetupForm : Form
    {
        readonly Theme theme = Engine.LoadTheme();
        Catalog catalog = new Catalog { Recipes = new List<RecipeInfo>(), Profiles = new List<ProfileInfo>() };
        readonly Dictionary<string, RecipeResult> results = new Dictionary<string, RecipeResult>();
        object selected; // RecipeInfo | ProfileInfo

        readonly TreeView nav = new NavTree { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, HideSelection = false, ShowLines = false, ShowPlusMinus = false, ShowRootLines = false, Scrollable = true, FullRowSelect = true, ItemHeight = 26, Tag = "surface" };
        readonly Label title = new Label { Dock = DockStyle.Top, Height = 34, Font = new Font("Segoe UI Semibold", 14f), Padding = new Padding(0, 4, 0, 0), AutoEllipsis = true };
        readonly Label desc = new Label { Dock = DockStyle.Top, Height = 40, Tag = "muted", AutoEllipsis = true };
        readonly ListView items, steps;
        readonly TextBox hint = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.Vertical, Font = new Font("Segoe UI", 9.5f) };
        readonly Button btnCheck, btnApply, btnRevert, btnCheckAll;
        readonly Label status = new Label { AutoSize = true, Padding = new Padding(6, 7, 0, 0), Tag = "muted" };
        bool busy;

        public SetupForm()
        {
            Text = "DEADPIXEL — Сетап ПК";
            Font = new Font("Segoe UI", 9f);
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            Size = new Size(1180, Math.Min(820, Screen.PrimaryScreen.WorkingArea.Height - 40));
            MinimumSize = new Size(900, 560);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = MakeIcon(theme.Accent);

            items = MakeList("Стан", 90, "Налаштування", 330, "Зараз", 170, "Треба", 170);
            items.ShowGroups = true;
            items.SelectedIndexChanged += (s, e) => ShowItemHint();
            steps = MakeList("Що зробити вручну", 600, "Дія", 110);
            steps.CheckBoxes = true;
            steps.SelectedIndexChanged += (s, e) => ShowStepHint();
            steps.MouseClick += OnStepClick;
            steps.MouseMove += (s, e) =>
            {
                var hit = steps.HitTest(e.Location);
                steps.Cursor = hit.SubItem != null && hit.Item.SubItems.IndexOf(hit.SubItem) == 1 && hit.Item.Tag is Step && ((Step)hit.Item.Tag).Run != null ? Cursors.Hand : Cursors.Default;
            };
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

            // ---- ліва колонка: профілі й рецепти
            btnCheckAll = Btn("Перевірити все", (s, e) => RunCheck("-Recipe *", "Перевіряю всі рецепти…"));
            var left = new Panel { Dock = DockStyle.Left, Width = 340, Padding = new Padding(10, 10, 6, 10) };
            var leftBottom = new Panel { Dock = DockStyle.Bottom, Height = 42, Padding = new Padding(0, 8, 0, 0) };
            btnCheckAll.Dock = DockStyle.Fill;
            leftBottom.Controls.Add(btnCheckAll);
            left.Controls.Add(Card(nav));
            left.Controls.Add(leftBottom);

            // ---- права колонка: заголовок, пункти, підказка, кроки, кнопки
            var right = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(6, 10, 12, 10), ColumnCount = 1, RowCount = 6 };
            right.RowStyles.Add(new RowStyle(SizeType.Absolute, 78));
            right.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            right.RowStyles.Add(new RowStyle(SizeType.Percent, 30));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
            var head = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
            head.Controls.Add(desc);
            head.Controls.Add(title);
            right.Controls.Add(head, 0, 0);
            right.Controls.Add(Card(items), 0, 1);
            right.Controls.Add(new Label { Text = "Підказка", Dock = DockStyle.Fill, Tag = "accent", TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 9f) }, 0, 2);
            right.Controls.Add(Card(hint, new Padding(8, 6, 8, 6)), 0, 3);
            right.Controls.Add(Card(steps), 0, 4);
            var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(0, 8, 0, 0), WrapContents = false };
            btnCheck = Btn("Перевірити", (s, e) => RunCheck(SelectionArgs(), "Перевіряю…"));
            btnApply = Btn("Застосувати", (s, e) => RunChange("-Apply"));
            btnRevert = Btn("Відкотити", (s, e) => RunChange("-Revert"));
            bar.Controls.AddRange(new Control[] { btnCheck, btnApply, btnRevert, status });
            right.Controls.Add(bar, 0, 5);

            Controls.Add(right);
            Controls.Add(left);

            Load += (s, e) =>
            {
                theme.Apply(this);
                theme.ApplyTitleBar(this);
                // У DarkMode_Explorer заголовки груп ListView темно-сині й нечитабельні; ItemsView (як у Провіднику) — світлі
                if (theme.Dark) foreach (var lv in new[] { items, steps }) SetWindowTheme(lv.Handle, "DarkMode_ItemsView", null);
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
                catalog = c;
                BuildNav();
                // одразу перевіряємо все — щоб стан ПК було видно без зайвого кліку
                RunCheck("-Recipe *", "Перевіряю ПК…");
            });
        }

        void BuildNav()
        {
            var key = SelectedKey();
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
            var node = AllNodes().FirstOrDefault(n => Key(n.Tag) == key) ?? AllNodes().FirstOrDefault(n => n.Tag != null);
            if (node != null) nav.SelectedNode = node;
            UpdateNavColors();
        }

        IEnumerable<TreeNode> AllNodes() { return nav.Nodes.Cast<TreeNode>().SelectMany(r => r.Nodes.Cast<TreeNode>()); }
        static string Key(object o) { return o is RecipeInfo ? "r:" + ((RecipeInfo)o).Name : o is ProfileInfo ? "p:" + ((ProfileInfo)o).Name : null; }
        string SelectedKey() { return Key(selected); }

        List<RecipeInfo> SelectedRecipes()
        {
            var r = selected as RecipeInfo;
            if (r != null) return new List<RecipeInfo> { r };
            var p = selected as ProfileInfo;
            if (p == null) return new List<RecipeInfo>();
            return p.Recipes.Select(n => catalog.Recipes.FirstOrDefault(x => x.Name == n)).Where(x => x != null).ToList();
        }

        string SelectionArgs()
        {
            var p = selected as ProfileInfo;
            if (p != null) return "-ProfileName \"" + p.Name + "\"";
            var r = selected as RecipeInfo;
            return r != null ? "-Recipe \"" + r.Name + "\"" : "-Recipe *";
        }

        // Зведений стан рецепта: FAIL > DIFF > NA-лише > OK; null — ще не перевіряли
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
            ShowItems();
            ShowSteps();
            hint.Text = "Виберіть налаштування або крок, щоб побачити пояснення.";
            UpdateButtons();
        }

        void ShowItems()
        {
            items.BeginUpdate();
            items.Items.Clear();
            items.Groups.Clear();
            foreach (var r in SelectedRecipes())
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

        void ShowSteps()
        {
            steps.BeginUpdate();
            steps.Items.Clear();
            steps.Groups.Clear();
            var all = new List<Tuple<string, Step>>();
            var p = selected as ProfileInfo;
            if (p != null) foreach (var s in p.Steps ?? new List<Step>()) all.Add(Tuple.Create(p.Title, s));
            bool reboot = false;
            foreach (var r in SelectedRecipes())
            {
                foreach (var s in r.Steps ?? new List<Step>()) all.Add(Tuple.Create(r.Title, s));
                reboot |= r.Reboot;
            }
            if (reboot) all.Add(Tuple.Create("Після застосування", new Step { Text = "Перезавантажте ПК, щоб зміни набули чинності." }));
            var groups = new Dictionary<string, ListViewGroup>();
            foreach (var t in all)
            {
                ListViewGroup g;
                if (!groups.TryGetValue(t.Item1, out g)) { g = new ListViewGroup(t.Item1); groups[t.Item1] = g; steps.Groups.Add(g); }
                var lvi = new ListViewItem(new[] { t.Item2.Text, string.IsNullOrEmpty(t.Item2.Run) ? "" : "Відкрити ↗" }, g)
                { Tag = t.Item2, UseItemStyleForSubItems = false, ToolTipText = t.Item2.Text };
                lvi.SubItems[1].ForeColor = theme.Accent;
                steps.Items.Add(lvi);
            }
            if (all.Count == 0) steps.Items.Add(new ListViewItem("Ручних кроків немає — усе робиться автоматично.") { ForeColor = theme.Muted });
            steps.EndUpdate();
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

        void ShowStepHint()
        {
            if (steps.SelectedItems.Count == 0) return;
            var s = steps.SelectedItems[0].Tag as Step;
            if (s == null) return;
            hint.Text = s.Text + (string.IsNullOrEmpty(s.Run) ? "" : "\r\n\r\nКнопка «Відкрити» запустить: " + s.Run) +
                        "\r\n\r\nПозначка ✓ — для вас, щоб не загубитися в кроках; вона ніде не зберігається.";
        }

        void OnStepClick(object sender, MouseEventArgs e)
        {
            var hit = steps.HitTest(e.Location);
            if (hit.Item == null || hit.SubItem == null || hit.Item.SubItems.IndexOf(hit.SubItem) != 1) return;
            var s = hit.Item.Tag as Step;
            if (s == null || string.IsNullOrEmpty(s.Run)) return;
            try { Engine.Open(s.Run); hit.Item.Checked = true; }
            catch (Exception ex) { SetStatus("Не вдалося відкрити " + s.Run + ": " + ex.Message, theme.Danger); }
        }

        void UpdateNavColors()
        {
            foreach (var n in AllNodes())
            {
                var r = n.Tag as RecipeInfo;
                var p = n.Tag as ProfileInfo;
                var recipes = r != null ? new List<RecipeInfo> { r } : p.Recipes.Select(x => catalog.Recipes.FirstOrDefault(y => y.Name == x)).Where(x => x != null).ToList();
                var states = recipes.Select(RecipeState).ToList();
                string st = states.Contains("FAIL") ? "FAIL" : states.Contains("DIFF") ? "DIFF" : states.Any(s => s == null) ? null : states.All(s => s == "OK" || s == "NA") ? "OK" : null;
                int diff = DiffCount(recipes);
                var baseTitle = r != null ? r.Title : p.Title;
                n.Text = diff > 0 ? baseTitle + "   · " + diff : baseTitle;
                n.ForeColor = st == null ? theme.Fg : StatusColor(st);
            }
        }

        void UpdateButtons()
        {
            var rs = SelectedRecipes();
            btnCheck.Enabled = !busy && rs.Count > 0;
            btnApply.Enabled = !busy && rs.Count > 0;
            btnRevert.Enabled = !busy && rs.Any(r => r.HasBackup);
            btnCheckAll.Enabled = !busy;
            nav.Enabled = !busy;
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
                case "OK": case "SET": return theme.Dark ? Color.FromArgb(74, 222, 128) : Color.FromArgb(22, 135, 60);
                case "DIFF": return theme.Warn;
                case "FAIL": return theme.Danger;
                case "BACK": return theme.Accent;
                default: return theme.Muted;
            }
        }

        // ================================================================ дії

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
            });
        }

        void RunChange(string verb)
        {
            var rs = SelectedRecipes();
            var name = selected is ProfileInfo ? ((ProfileInfo)selected).Title : rs[0].Title;
            string question;
            if (verb == "-Apply")
            {
                int diff = DiffCount(rs);
                question = "Застосувати «" + name + "»?\n\n" +
                           (diff > 0 ? "Буде змінено налаштувань: " + diff + "." : "Перевірка ще не виявила відхилень — зміниться лише те, що відрізняється.") +
                           "\nПоточні значення збережуться, їх можна буде відкотити.\n\nWindows попросить права адміністратора.";
            }
            else question = "Відкотити «" + name + "» до значень, що були перед останнім застосуванням?\n\nWindows попросить права адміністратора.";
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
                    if (steps.Items.Cast<ListViewItem>().Any(i => i.Tag is Step)) msg += " Перегляньте кроки вручну нижче.";
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
            ShowItems();
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

        // ================================================================ побудова

        ListView MakeList(params object[] cols)
        {
            var lv = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, BorderStyle = BorderStyle.None, ShowItemToolTips = true };
            for (int i = 0; i < cols.Length; i += 2) lv.Columns.Add((string)cols[i], (int)cols[i + 1]);
            Theme.OwnerDrawHeaders(lv, () => theme);
            // текстова колонка ("Налаштування" / "Що зробити вручну") забирає вільну ширину, решта фіксовані
            lv.Resize += (s, e) =>
            {
                int stretch = lv.Columns.Count == 2 ? 0 : 1;
                int fixedW = 0;
                for (int i = 0; i < lv.Columns.Count; i++) if (i != stretch) fixedW += lv.Columns[i].Width;
                lv.Columns[stretch].Width = Math.Max(200, lv.ClientSize.Width - fixedW - 4);
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

        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        static Icon MakeIcon(Color c)
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var b = new SolidBrush(c)) g.FillEllipse(b, 2, 2, 28, 28);
                    using (var pen = new Pen(Color.White, 3.5f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                        g.DrawLines(pen, new[] { new Point(9, 16), new Point(14, 21), new Point(23, 11) });
                }
                var h = bmp.GetHicon();
                var ico = (Icon)Icon.FromHandle(h).Clone();
                DestroyIcon(h);
                return ico;
            }
        }
    }
}

namespace DeadPixel
{
    // Дерево без горизонтальної прокрутки: довгі назви обрізаються, повна назва — у заголовку справа
    class NavTree : TreeView
    {
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.Style |= 0x8000; return cp; } // TVS_NOHSCROLL
        }
    }
}
