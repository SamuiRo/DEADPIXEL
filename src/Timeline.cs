using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

namespace CrashDoctor
{
    // Графік останніх хвилин перед крашем: телеметрія, смуга P-state і позначки подій/процесів
    class TimelineChart : Control
    {
        readonly Func<Theme> theme;
        CrashInfo crash;
        int mouseX = -1;
        Font small, bold;

        static readonly ChartSeries[] Series =
        {
            new ChartSeries("Частота GPU", Color.FromArgb(34, 170, 90), s => s.GpuClock, 3300, "MHz"),
            new ChartSeries("Потужн.", Color.FromArgb(59, 130, 246), s => s.GpuPower, 350, "W"),
            new ChartSeries("Завант. GPU", Color.FromArgb(150, 150, 160), s => s.GpuUtil, 100, "%"),
            new ChartSeries("Темп. GPU", Color.FromArgb(245, 124, 40), s => s.GpuTemp, 100, "°C"),
            new ChartSeries("CPU", Color.FromArgb(168, 85, 247), s => s.CpuPct, 100, "%"),
        };

        public TimelineChart(Func<Theme> theme)
        {
            this.theme = theme;
            DoubleBuffered = true;
            SetStyle(ControlStyles.ResizeRedraw | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            MouseMove += (s, e) => { mouseX = e.X; Invalidate(); };
            MouseLeave += (s, e) => { mouseX = -1; Invalidate(); };
        }

        public void SetCrash(CrashInfo c) { crash = c; Invalidate(); }

        DateTime From { get { return crash.Moment.AddMinutes(-10); } }
        DateTime To { get { return crash.Moment.AddSeconds(30); } }

        float X(Rectangle a, DateTime t)
        {
            return a.Left + (float)((t - From).TotalSeconds / (To - From).TotalSeconds) * a.Width;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = theme();
            var g = e.Graphics;
            g.Clear(t.Surface);
            if (small == null) { small = new Font(Font.FontFamily, 7.5f); bold = new Font(Font, FontStyle.Bold); }
            if (crash == null) return;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            // область графіка: зверху легенда, знизу підписи часу і смуга P-state
            var a = new Rectangle(12, 40, Width - 24, Height - 40 - 40);
            if (a.Width < 50 || a.Height < 30) return;
            using (var grid = new Pen(t.Grid))
            {
                for (int i = 0; i <= 4; i++) { int y = a.Top + a.Height * i / 4; g.DrawLine(grid, a.Left, y, a.Right, y); }
                for (int m = -10; m <= 0; m += 2)
                {
                    float x = X(a, crash.Moment.AddMinutes(m));
                    g.DrawLine(grid, x, a.Top, x, a.Bottom);
                    var lbl = m == 0 ? crash.Moment.ToString("HH:mm:ss") : m + " хв";
                    var sz = TextRenderer.MeasureText(lbl, small);
                    TextRenderer.DrawText(g, lbl, small, new Point((int)x - sz.Width / 2, a.Bottom + 16), t.Muted);
                }
            }

            var rows = crash.Rows;
            // легенда
            float lx = 12;
            TextRenderer.DrawText(g, "Останні 10 хв перед збоєм", bold, new Point(12, 4), t.Fg);
            foreach (var s in Series)
            {
                var label = "■ " + s.Name;
                TextRenderer.DrawText(g, label, small, new Point((int)lx, 22), s.Color);
                lx += TextRenderer.MeasureText(label, small).Width + 6;
            }

            if (rows.Count == 0)
            {
                var msg = "Немає даних чорної скриньки для цього краша — CrashDoctor тоді не працював. Позначки подій нижче все одно показано.";
                TextRenderer.DrawText(g, msg, Font, a, t.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
            }
            else
            {
                foreach (var s in Series)
                {
                    var pts = new List<PointF>();
                    foreach (var r in rows)
                    {
                        var v = s.Value(r);
                        if (double.IsNaN(v)) { if (pts.Count > 1) Draw(g, s.Color, pts); pts.Clear(); continue; }
                        pts.Add(new PointF(X(a, r.Time), a.Bottom - (float)(Math.Min(v, s.Max) / s.Max) * a.Height));
                    }
                    if (pts.Count > 1) Draw(g, s.Color, pts);
                }
                // смуга P-state
                for (int i = 0; i < rows.Count; i++)
                {
                    float x1 = X(a, rows[i].Time), x2 = i + 1 < rows.Count ? X(a, rows[i + 1].Time) : x1 + 3;
                    var ps = rows[i].PState;
                    var col = ps == "P0" || ps == "P1" || ps == "P2" ? Color.FromArgb(34, 170, 90) : ps == "P3" || ps == "P4" || ps == "P5" ? Color.FromArgb(230, 160, 0) : Color.FromArgb(120, 120, 130);
                    using (var b = new SolidBrush(col)) g.FillRectangle(b, x1, a.Bottom + 3, Math.Max(1, x2 - x1), 8);
                }
                TextRenderer.DrawText(g, "P-state", small, new Point(a.Right - 40, a.Bottom + 28), t.Muted);
            }

            // позначки: процеси, події, момент збою
            int lane = 0;
            foreach (var p in crash.Procs.Where(p => p.Kind != "fg"))
            {
                float x = X(a, p.Time);
                var col = p.Kind == "exit" ? Color.FromArgb(234, 88, 12) : Color.FromArgb(34, 170, 90);
                using (var pen = new Pen(col, 1.2f) { DashStyle = DashStyle.Dash }) g.DrawLine(pen, x, a.Top, x, a.Bottom);
                TextRenderer.DrawText(g, (p.Kind == "exit" ? "✕ " : "▶ ") + p.Name, small, new Point((int)x + 2, a.Top + 2 + (lane++ % 4) * 12), col);
            }
            foreach (var p in crash.Procs.Where(p => p.Kind == "fg"))
            {
                float x = X(a, p.Time);
                using (var pen = new Pen(t.Muted)) g.DrawLine(pen, x, a.Bottom - 6, x, a.Bottom);
            }
            foreach (var ev in crash.Events)
            {
                float x = X(a, ev.Time);
                var col = ev.Level <= 2 ? t.Danger : t.Warn;
                using (var b = new SolidBrush(col)) g.FillPolygon(b, new[] { new PointF(x - 4, a.Top - 7), new PointF(x + 4, a.Top - 7), new PointF(x, a.Top) });
            }
            float cx = X(a, crash.Moment);
            using (var pen = new Pen(t.Danger, 2f)) g.DrawLine(pen, cx, a.Top - 4, cx, a.Bottom + 12);
            TextRenderer.DrawText(g, "ЗБІЙ", bold, new Point((int)cx + 4, a.Bottom - 18), t.Danger);

            // курсор з підказкою
            if (mouseX >= a.Left && mouseX <= a.Right)
            {
                var time = From.AddSeconds((mouseX - a.Left) / (double)a.Width * (To - From).TotalSeconds);
                using (var pen = new Pen(t.Muted) { DashStyle = DashStyle.Dot }) g.DrawLine(pen, mouseX, a.Top, mouseX, a.Bottom);
                var lines = new List<string> { time.ToString("HH:mm:ss") + string.Format("  (за {0:0} с до збою)", (crash.Moment - time).TotalSeconds) };
                var r = rows.Count > 0 ? rows.OrderBy(x => Math.Abs((x.Time - time).TotalSeconds)).First() : null;
                if (r != null && Math.Abs((r.Time - time).TotalSeconds) < 15)
                {
                    lines.Add(string.Format("GPU {0} · {1:0} MHz · {2:0} W · {3:0}% · {4:0} °C", r.PState, r.GpuClock, r.GpuPower, r.GpuUtil, r.GpuTemp));
                    if (!double.IsNaN(r.CpuPct)) lines.Add(string.Format("CPU {0:0}% · {1:0} MHz", r.CpuPct, r.CpuMhz));
                    if (r.Fg != "") lines.Add("Активна: " + r.Fg);
                }
                foreach (var ev in crash.Events.Where(x => Math.Abs((x.Time - time).TotalSeconds) < 10).Take(3))
                    lines.Add("⚠ " + ev.Source + ": " + (ev.Text.Length > 70 ? ev.Text.Substring(0, 70) + "…" : ev.Text));
                foreach (var p in crash.Procs.Where(x => Math.Abs((x.Time - time).TotalSeconds) < 10).Take(3))
                    lines.Add((p.Kind == "exit" ? "Закрито: " : p.Kind == "start" ? "Запущено: " : "Активне вікно: ") + p.Name);
                var text = string.Join("\n", lines);
                var sz = TextRenderer.MeasureText(text, small);
                int bx = mouseX + 12 + sz.Width + 12 > Width ? mouseX - sz.Width - 20 : mouseX + 12;
                var box = new Rectangle(bx, a.Top + 4, sz.Width + 10, sz.Height + 8);
                using (var b = new SolidBrush(t.Bg)) g.FillRectangle(b, box);
                using (var p = new Pen(t.Border)) g.DrawRectangle(p, box);
                TextRenderer.DrawText(g, text, small, new Point(box.X + 5, box.Y + 4), t.Fg);
            }
        }

        static void Draw(Graphics g, Color c, List<PointF> pts)
        {
            using (var pen = new Pen(c, 1.6f)) g.DrawLines(pen, pts.ToArray());
        }
    }
}
