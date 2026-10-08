using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CrashDoctor
{
    class Theme
    {
        public bool Dark;
        public Color Bg, Surface, Fg, Muted, Border, Accent, Danger, Warn, Grid, Selected;

        public static readonly Theme Light = new Theme
        {
            Dark = false,
            Bg = Color.FromArgb(243, 244, 246), Surface = Color.White, Fg = Color.FromArgb(28, 31, 36),
            Muted = Color.FromArgb(107, 114, 128), Border = Color.FromArgb(218, 222, 228), Accent = Color.FromArgb(37, 99, 235),
            Danger = Color.FromArgb(198, 40, 40), Warn = Color.FromArgb(180, 100, 0), Grid = Color.FromArgb(234, 236, 239),
            Selected = Color.FromArgb(219, 234, 254)
        };

        public static readonly Theme DarkTheme = new Theme
        {
            Dark = true,
            Bg = Color.FromArgb(22, 24, 28), Surface = Color.FromArgb(32, 35, 41), Fg = Color.FromArgb(229, 231, 235),
            Muted = Color.FromArgb(150, 158, 170), Border = Color.FromArgb(52, 57, 66), Accent = Color.FromArgb(96, 165, 250),
            Danger = Color.FromArgb(248, 113, 113), Warn = Color.FromArgb(251, 191, 36), Grid = Color.FromArgb(45, 49, 56),
            Selected = Color.FromArgb(30, 58, 95)
        };

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        public void ApplyTitleBar(Form f)
        {
            if (!f.IsHandleCreated) return;
            int v = Dark ? 1 : 0;
            // 20 — Windows 10 20H1+ і Windows 11; 19 — Windows 10 1809–1909
            try { if (DwmSetWindowAttribute(f.Handle, 20, ref v, 4) != 0) DwmSetWindowAttribute(f.Handle, 19, ref v, 4); } catch { }
        }

        // Рекурсивно фарбує стандартні контроли. Плитки/картки позначені Tag = "surface".
        public void Apply(Control c)
        {
            var tag = c.Tag as string;
            if (c is Form) { c.BackColor = Bg; c.ForeColor = Fg; }
            else if (c is ListView)
            {
                var lv = (ListView)c;
                lv.BackColor = Surface; lv.ForeColor = Fg;
                Native(lv, Dark ? "DarkMode_Explorer" : "Explorer");
                lv.Invalidate();
            }
            else if (c is TextBox || c is NumericUpDown)
            {
                c.BackColor = Surface; c.ForeColor = Fg;
                Native(c, Dark ? "DarkMode_Explorer" : "Explorer");
            }
            else if (c is ComboBox)
            {
                var cb = (ComboBox)c;
                cb.FlatStyle = FlatStyle.Flat; cb.BackColor = Surface; cb.ForeColor = Fg;
                Native(c, Dark ? "DarkMode_CFD" : "CFD");
            }
            else if (c is Button)
            {
                var b = (Button)c;
                b.FlatStyle = FlatStyle.Flat;
                b.FlatAppearance.BorderColor = Border;
                bool sel = tag == "tab-selected";
                b.BackColor = tag != null && tag.StartsWith("tab") ? (sel ? Surface : Bg) : Surface;
                b.ForeColor = sel ? Accent : Fg;
                b.FlatAppearance.BorderSize = tag != null && tag.StartsWith("tab") ? 0 : 1;
                b.FlatAppearance.MouseOverBackColor = Selected;
            }
            else if (c is CheckBox) { c.ForeColor = Fg; c.BackColor = Color.Transparent; }
            else if (c is Label)
            {
                c.BackColor = Color.Transparent;
                c.ForeColor = tag == "muted" ? Muted : tag == "accent" ? Accent : tag == "warn" ? Warn : Fg;
                var ll = c as LinkLabel;
                if (ll != null) { ll.LinkColor = Accent; ll.ActiveLinkColor = Accent; ll.VisitedLinkColor = Accent; }
            }
            else if (c is Chart) { c.BackColor = Surface; c.ForeColor = Fg; }
            else
            {
                c.BackColor = tag == "surface" ? Surface : tag == "border" ? Border : Bg; c.ForeColor = Fg;
                var sc = c as ScrollableControl;
                if (sc != null && sc.AutoScroll) Native(c, Dark ? "DarkMode_Explorer" : "Explorer");
            }

            foreach (Control ch in c.Controls) Apply(ch);
        }

        static void Native(Control c, string name)
        {
            if (!c.IsHandleCreated) return;
            try { SetWindowTheme(c.Handle, name, null); } catch { }
        }

        // Темні заголовки колонок ListView (стандартні завжди світлі)
        public static void OwnerDrawHeaders(ListView lv, Func<Theme> theme)
        {
            lv.OwnerDraw = true;
            lv.DrawItem += (s, e) => e.DrawDefault = true;
            lv.DrawSubItem += (s, e) => e.DrawDefault = true;
            lv.DrawColumnHeader += (s, e) =>
            {
                var t = theme();
                using (var b = new SolidBrush(t.Dark ? t.Bg : Color.FromArgb(248, 249, 250))) e.Graphics.FillRectangle(b, e.Bounds);
                using (var p = new Pen(t.Border)) e.Graphics.DrawLine(p, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                var r = new Rectangle(e.Bounds.X + 6, e.Bounds.Y, e.Bounds.Width - 8, e.Bounds.Height);
                TextRenderer.DrawText(e.Graphics, e.Header.Text, lv.Font, r, t.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            };
        }
    }

    // Кольори контекстного меню трею
    class MenuColors : ProfessionalColorTable
    {
        readonly Theme t;
        public MenuColors(Theme t) { this.t = t; UseSystemColors = false; }
        public override Color ToolStripDropDownBackground { get { return t.Surface; } }
        public override Color ImageMarginGradientBegin { get { return t.Surface; } }
        public override Color ImageMarginGradientMiddle { get { return t.Surface; } }
        public override Color ImageMarginGradientEnd { get { return t.Surface; } }
        public override Color MenuBorder { get { return t.Border; } }
        public override Color MenuItemBorder { get { return t.Selected; } }
        public override Color MenuItemSelected { get { return t.Selected; } }
        public override Color SeparatorDark { get { return t.Border; } }
        public override Color SeparatorLight { get { return t.Border; } }
        public override Color CheckBackground { get { return t.Selected; } }
        public override Color CheckSelectedBackground { get { return t.Selected; } }
        public override Color CheckPressedBackground { get { return t.Selected; } }
    }
}
