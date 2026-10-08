using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace DeadPixel
{
    // ================================================================ контекст одного краша
    static class CrashAnalyzer
    {
        public static string LkrRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "LiveKernelReports"); } }

        // Дамп зависання GPU (LiveKernelReports\WATCHDOG\WATCHDOG-yyyyMMdd-HHmm.dmp) → час
        public static List<Tuple<DateTime, string>> WatchdogDumps()
        {
            var res = new List<Tuple<DateTime, string>>();
            try
            {
                foreach (var f in Directory.GetFiles(LkrRoot, "*.dmp", SearchOption.AllDirectories))
                {
                    var m = Regex.Match(Path.GetFileName(f), @"^(\w+?)-(\d{8})-(\d{4})(-\d+)?\.dmp$");
                    if (!m.Success) continue;
                    DateTime t;
                    if (DateTime.TryParseExact(m.Groups[2].Value + m.Groups[3].Value, "yyyyMMddHHmm", null, DateTimeStyles.None, out t))
                        res.Add(Tuple.Create(t, f));
                }
            }
            catch { }
            return res.OrderBy(x => x.Item1).ToList();
        }

        public static void Enrich(List<CrashInfo> crashes, List<ChangeItem> changes, string currentDriver)
        {
            var boots = EventMonitor.BootTimes(120);
            var lkr = WatchdogDumps();
            foreach (var c in crashes)
            {
                // 1. Момент збою: дамп TDR → чорна скринька → (невідомо) час перезавантаження
                c.Moment = c.Boot; c.MomentSource = "невідомо (взято час перезавантаження)";
                var tdr = lkr.Where(x => x.Item1 <= c.Boot && x.Item1 > c.Boot.AddMinutes(-40) && Path.GetFileName(x.Item2).StartsWith("WATCHDOG-"))
                             .OrderByDescending(x => x.Item1).FirstOrDefault();
                if (tdr != null) { c.Moment = tdr.Item1.AddSeconds(59); c.MomentSource = "дамп зависання GPU (точність до хвилини)"; c.LkrDump = tdr.Item2; }
                var lastRow = Sampler.ReadBefore(c.Boot, 1);
                DateTime lt;
                if (lastRow.Count > 0 && Sampler.TryTime(lastRow[0], out lt) && (tdr == null || Math.Abs((lt - tdr.Item1).TotalMinutes) < 3))
                { c.Moment = lt; c.MomentSource = "останній запис чорної скриньки (точність ±інтервал запису)"; }

                // 2. Скільки працювала система
                var prev = boots.Where(b => b < c.Boot.AddSeconds(-30)).DefaultIfEmpty(DateTime.MinValue).Max();
                if (prev != DateTime.MinValue && prev < c.Moment) c.Uptime = c.Moment - prev;

                // 3. Дані навколо моменту
                c.Rows = Sampler.ReadSamples(c.Moment.AddMinutes(-10), c.Moment.AddSeconds(30));
                c.Procs = Sampler.ReadProcEvents(c.Moment.AddMinutes(-10), c.Moment.AddSeconds(30));
                c.Events = EventMonitor.QueryRange(c.Moment.AddMinutes(-10), c.Moment.AddSeconds(30));
                c.LastSample = c.Rows.LastOrDefault(r => r.Time <= c.Moment);
                c.LastExit = c.Procs.LastOrDefault(p => p.Kind == "exit" && p.Time <= c.Moment);
                if (c.LastSample != null && c.LastSample.Fg != "") c.LastFg = c.LastSample.Fg;

                // 4. Версія драйвера NVIDIA на момент краша
                var nvBefore = changes.Where(x => x.IsNvidiaDisplay && x.Time <= c.Moment).OrderByDescending(x => x.Time).FirstOrDefault();
                var nvAfter = changes.Where(x => x.IsNvidiaDisplay && x.Time > c.Moment).OrderBy(x => x.Time).FirstOrDefault();
                if (nvBefore != null) c.DriverAtCrash = NvVersion(nvBefore.Version);
                else if (nvAfter == null) c.DriverAtCrash = currentDriver;
                else c.DriverAtCrash = "старіший за " + NvVersion(nvAfter.Version);
            }
        }

        // 32.0.15.9186 → 591.86
        public static string NvVersion(string v)
        {
            if (string.IsNullOrEmpty(v)) return "?";
            var p = v.Split('.');
            if (p.Length < 4) return v;
            var digits = p[2] + p[3].PadLeft(4, '0');
            if (digits.Length < 5) return v;
            digits = digits.Substring(digits.Length - 5);
            return digits.Substring(0, 3) + "." + digits.Substring(3);
        }

        public static bool IsGpuCrash(CrashInfo c)
        {
            return c.Code == 0x116 || c.Code == 0x117 || c.Code == 0x119 || c.Code == 0x141 || c.Driver.StartsWith("nvlddmkm", StringComparison.OrdinalIgnoreCase);
        }

        public static bool? WasIdle(CrashInfo c)
        {
            var s = c.LastSample;
            if (s == null || double.IsNaN(s.GpuUtil)) return null;
            bool lowPstate = s.PState == "P5" || s.PState == "P8" || s.PState == "P12";
            return s.GpuUtil < 15 && (lowPstate || s.GpuPower < 60);
        }

        public static string Ago(TimeSpan t)
        {
            if (t.TotalSeconds < 90) return string.Format("{0:0} с", t.TotalSeconds);
            if (t.TotalMinutes < 90) return string.Format("{0:0} хв", t.TotalMinutes);
            if (t.TotalHours < 48) return string.Format("{0} год {1} хв", (int)t.TotalHours, t.Minutes);
            return string.Format("{0:0} дн", t.TotalDays);
        }

        public static string Describe(CrashInfo c)
        {
            var bc = BugChecks.Get(c.Code);
            var sb = new StringBuilder();
            sb.AppendLine("Перезавантаження після збою: " + c.Boot.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("Момент збою:  " + c.Moment.ToString("yyyy-MM-dd HH:mm:ss") + "  — " + c.MomentSource);
            sb.AppendLine("Код:          " + (c.Code == 0 ? "— (без синього екрана)" : "0x" + c.Code.ToString("X") + "  " + bc[0]));
            sb.AppendLine("Що це:        " + bc[1]);
            if (c.Driver != "") sb.AppendLine("Драйвер:      " + c.Driver);
            sb.AppendLine("NVIDIA:       " + c.DriverAtCrash);
            if (c.Uptime.HasValue) sb.AppendLine("Аптайм:       " + Ago(c.Uptime.Value) + " після запуску системи");
            if (c.Dump != "") sb.AppendLine("Дамп:         " + c.Dump);
            if (c.LkrDump != "") sb.AppendLine("Дамп TDR:     " + c.LkrDump);

            sb.AppendLine();
            sb.AppendLine("Обставини:");
            var s = c.LastSample;
            if (s == null) sb.AppendLine("  чорна скринька не має даних для цього моменту (DEADPIXEL тоді не працював).");
            else
            {
                var idle = WasIdle(c);
                sb.AppendLine(string.Format("  GPU: {0}, {1}% навантаження, {2} W, {3} MHz, {4} °C, обмеження: {5}  → {6}",
                    s.PState, F(s.GpuUtil), F(s.GpuPower), F(s.GpuClock), F(s.GpuTemp), Sampler.DecodeReasons(s.Reasons),
                    idle == true ? "ПРОСТІЙ" : idle == false ? "ПІД НАВАНТАЖЕННЯМ" : "?"));
                if (!double.IsNaN(s.CpuPct)) sb.AppendLine(string.Format("  CPU: {0}%, {1} MHz{2}, RAM {3}%", F(s.CpuPct), F(s.CpuMhz), double.IsNaN(s.CpuTemp) ? "" : ", " + F(s.CpuTemp) + " °C", F(s.RamPct)));
                if (s.Fg != "") sb.AppendLine("  Активна програма: " + s.Fg);
                var lastTransition = c.Rows.Where(r => r.Time <= c.Moment).Zip(c.Rows.Where(r => r.Time <= c.Moment).Skip(1), (a, b) => new { a, b })
                                            .LastOrDefault(x => x.a.PState != x.b.PState);
                if (lastTransition != null)
                    sb.AppendLine(string.Format("  Остання зміна P-state: {0} → {1} за {2} до збою", lastTransition.a.PState, lastTransition.b.PState, Ago(c.Moment - lastTransition.b.Time)));
            }
            if (c.LastExit != null)
                sb.AppendLine(string.Format("  Закрито «{0}» ({1} МБ) за {2} до збою", c.LastExit.Name, c.LastExit.RamMb, Ago(c.Moment - c.LastExit.Time)));
            else if (c.Procs.Count > 0 || s != null)
                sb.AppendLine("  Закриття важких програм за 10 хв до збою не було.");

            if (c.Events.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("Події Windows за 10 хв до збою:");
                foreach (var e in c.Events.OrderBy(e => e.Time))
                    sb.AppendLine(string.Format("  {0:HH:mm:ss} [{1} {2}] {3}", e.Time, e.Source, e.Id, e.Text.Length > 160 ? e.Text.Substring(0, 160) + "…" : e.Text));
            }

            foreach (var dump in new[] { c.Dump, c.LkrDump })
            {
                if (dump == "") continue;
                var a = DumpAnalyzer.Load(dump);
                if (a == null) continue;
                sb.AppendLine();
                sb.AppendLine("Аналіз дампу " + Path.GetFileName(dump) + ":");
                sb.Append(a.Summary());
            }

            if (s != null)
            {
                sb.AppendLine();
                sb.AppendLine("Чорна скринька (останні записи):");
                sb.AppendLine("  " + Sampler.Header.Replace(",", " | "));
                foreach (var l in Sampler.ReadBefore(c.Moment.AddSeconds(1), 20)) sb.AppendLine("  " + l.Replace(",", " | "));
            }
            return sb.ToString().Replace("\r\n", "\n").Replace("\n", "\r\n");
        }

        static string F(double v) { return double.IsNaN(v) ? "—" : v.ToString("0", CultureInfo.InvariantCulture); }
    }

    // ================================================================ закономірності
    static class PatternAnalyzer
    {
        public static string Build(List<CrashInfo> crashes, List<ChangeItem> changes)
        {
            var sb = new StringBuilder();
            var list = crashes.OrderBy(c => c.Moment).ToList();
            sb.AppendLine(string.Format("Аварійних перезавантажень за 90 днів: {0}", list.Count));
            if (list.Count == 0) return sb.ToString();

            sb.AppendLine();
            sb.AppendLine("Типи збоїв:");
            foreach (var g in list.GroupBy(c => c.Code).OrderByDescending(g => g.Count()))
                sb.AppendLine(string.Format("  {0,-32} ×{1}", g.Key == 0 ? "без BSOD" : BugChecks.Get(g.Key)[0], g.Count()));
            var drv = list.Where(c => c.Driver != "").GroupBy(c => c.Driver).OrderByDescending(g => g.Count()).ToList();
            if (drv.Count > 0) sb.AppendLine("  Винний драйвер: " + string.Join(", ", drv.Select(g => g.Key + " ×" + g.Count())));
            sb.AppendLine("  Версія NVIDIA під час крашів: " + string.Join(", ", list.GroupBy(c => c.DriverAtCrash).Select(g => g.Key + " ×" + g.Count())));

            sb.AppendLine();
            sb.AppendLine("Хронологія:");
            foreach (var c in list)
            {
                var idle = CrashAnalyzer.WasIdle(c);
                sb.AppendLine(string.Format("  {0:yyyy-MM-dd HH:mm}  {1,-24} аптайм {2,-10} GPU: {3,-14} {4}",
                    c.Moment, c.Code == 0 ? "без BSOD" : BugChecks.Get(c.Code)[0],
                    c.Uptime.HasValue ? CrashAnalyzer.Ago(c.Uptime.Value) : "?",
                    idle == true ? "простій" : idle == false ? "навантаження" : "немає даних",
                    c.LastExit != null ? string.Format("закрито {0} за {1} до", c.LastExit.Name, CrashAnalyzer.Ago(c.Moment - c.LastExit.Time)) : ""));
            }

            // Історія відновлених зависань GPU (без BSOD) — показує, як давно проблема тягнеться
            var tdrs = CrashAnalyzer.WatchdogDumps().Where(x => Path.GetFileName(x.Item2).StartsWith("WATCHDOG-")).ToList();
            if (tdrs.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("Зависання GPU за місяцями (дампи TDR, включно з відновленими без BSOD):");
                foreach (var g in tdrs.GroupBy(x => x.Item1.ToString("yyyy-MM")))
                    sb.AppendLine(string.Format("  {0}  {1}", g.Key, new string('█', g.Count()) + " " + g.Count()));
            }

            // Висновки
            var tips = new List<string>();
            int gpu = list.Count(CrashAnalyzer.IsGpuCrash);
            var withData = list.Where(c => CrashAnalyzer.WasIdle(c).HasValue).ToList();
            int idleCnt = withData.Count(c => CrashAnalyzer.WasIdle(c) == true);
            var withProcs = list.Where(c => c.Procs.Count > 0 || c.LastSample != null).ToList();
            int afterExit = withProcs.Count(c => c.LastExit != null && (c.Moment - c.LastExit.Time).TotalSeconds <= 120);
            if (gpu * 2 >= list.Count) tips.Add(string.Format("{0} з {1} крашів пов'язані з відеодрайвером NVIDIA — основний підозрюваний GPU/драйвер/живлення GPU.", gpu, list.Count));
            if (withData.Count >= 2 && idleCnt * 2 > withData.Count) tips.Add(string.Format("{0} з {1} крашів (де є дані) сталися в ПРОСТОЇ — типово для збою при переході GPU в енергозбереження: вимкніть PCIe ASPM, спробуйте «Максимальна продуктивність» у панелі NVIDIA.", idleCnt, withData.Count));
            if (withData.Count >= 2 && idleCnt * 2 < withData.Count) tips.Add("Більшість крашів під навантаженням — перевірте живлення відеокарти (кабель 12V-2x6, БЖ) і температури.");
            if (withProcs.Count >= 1 && afterExit * 2 >= withProcs.Count && afterExit > 0) tips.Add(string.Format("{0} з {1} крашів (де є дані) сталися протягом 2 хв після закриття гри/важкої програми.", afterExit, withProcs.Count));
            var versions = list.Select(c => c.DriverAtCrash).Distinct().ToList();
            if (versions.Count == 1 && list.Count >= 2) tips.Add("Усі краші на одній версії драйвера NVIDIA (" + versions[0] + "). Оновлення драйвера — перший крок.");
            var shortUp = list.Count(c => c.Uptime.HasValue && c.Uptime.Value.TotalMinutes < 15);
            if (shortUp >= 2) tips.Add(string.Format("{0} крашів сталися менш ніж за 15 хв після запуску системи.", shortUp));
            if (withData.Count == 0) tips.Add("Даних чорної скриньки для минулих крашів немає. Після наступного краша тут з'явиться аналіз стану GPU і програм у момент збою.");

            // Початок серії і що змінилося перед ним
            CrashInfo seriesStart = list.Last();
            for (int i = list.Count - 1; i > 0; i--)
            {
                if ((list[i].Moment - list[i - 1].Moment).TotalDays > 30) break;
                seriesStart = list[i - 1];
            }
            var before = changes.Where(x => x.Time <= seriesStart.Moment && x.Time > seriesStart.Moment.AddDays(-7)).OrderByDescending(x => x.Time).ToList();

            sb.AppendLine();
            sb.AppendLine("Висновки:");
            if (tips.Count == 0) sb.AppendLine("  Явних закономірностей не видно.");
            foreach (var t in tips) sb.AppendLine("  • " + t);

            sb.AppendLine();
            sb.AppendLine(string.Format("Що змінилося за 7 днів до початку серії крашів ({0:yyyy-MM-dd HH:mm}):", seriesStart.Moment));
            if (before.Count == 0) sb.AppendLine("  нічого не знайдено (драйвери/оновлення/програми).");
            foreach (var x in before.Take(25)) sb.AppendLine(string.Format("  {0:yyyy-MM-dd HH:mm}  {1,-18} {2}", x.Time, x.Kind, x.Text));
            return sb.ToString().Replace("\r\n", "\n").Replace("\n", "\r\n");
        }
    }

    // ================================================================ історія змін
    class ChangeItem
    {
        public DateTime Time;
        public string Kind, Text, Inf = "", Version = "";
        public bool IsNvidiaDisplay { get { return Inf.StartsWith("nv_disp", StringComparison.OrdinalIgnoreCase); } }
    }

    static class ChangeHistory
    {
        public static List<ChangeItem> Load(int days)
        {
            var res = new List<ChangeItem>();
            var since = DateTime.Now.AddDays(-days);
            res.AddRange(DriverInstalls(since));
            var ms = ((long)days * 86400000L).ToString();
            foreach (var r in EventMonitor.ReadRawPublic("System", "*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and EventID=19 and TimeCreated[timediff(@SystemTime) <= " + ms + "]]]"))
            {
                var title = r.Item3.Length > 0 ? Convert.ToString(r.Item3[0]) : "";
                if (Regex.IsMatch(title, @"^[0-9A-Z]{12}-")) continue; // оновлення Store-застосунків — шум
                if (title.Contains("Security Intelligence Update") || title.Contains("Malicious Software Removal")) continue; // бази Defender — щодня
                res.Add(new ChangeItem { Time = r.Item1, Kind = "Оновлення Windows", Text = title });
            }
            foreach (var id in new[] { 11707, 11724 })
                foreach (var r in EventMonitor.ReadRawPublic("Application", "*[System[Provider[@Name='MsiInstaller'] and EventID=" + id + " and TimeCreated[timediff(@SystemTime) <= " + ms + "]]]"))
                {
                    // "Product: X -- ..." (на локалізованій Windows слово "Product" перекладено)
                    var t = Regex.Replace(r.Item3.Length > 0 ? Convert.ToString(r.Item3[0]) : r.Item2, @"\s+", " ");
                    var m = Regex.Match(t, @"^[^:]+:\s*(.+?)\s+--");
                    res.Add(new ChangeItem { Time = r.Item1, Kind = id == 11724 ? "Видалено програму" : "Встановлено програму", Text = m.Success ? m.Groups[1].Value : t });
                }
            return res.OrderByDescending(x => x.Time).ToList();
        }

        // Розбір C:\Windows\INF\setupapi.dev*.log — лог встановлення драйверів
        static IEnumerable<ChangeItem> DriverInstalls(DateTime since)
        {
            var found = new List<ChangeItem>();
            string[] files;
            try
            {
                files = Directory.GetFiles(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "INF"), "setupapi.dev*.log")
                                 .Where(f => File.GetLastWriteTime(f) >= since).OrderBy(f => File.GetLastWriteTime(f)).ToArray();
            }
            catch { return found; }
            foreach (var f in files)
            {
                try
                {
                    string header = null, inf = null, ver = null;
                    DateTime start = DateTime.MinValue;
                    foreach (var line in File.ReadLines(f))
                    {
                        if (line.StartsWith(">>>  ["))
                        {
                            header = line.Substring(6).TrimEnd(']');
                            inf = null; ver = null; start = DateTime.MinValue;
                        }
                        else if (header == null) continue;
                        else if (line.StartsWith(">>>  Section start "))
                            DateTime.TryParseExact(line.Substring(19, 19), "yyyy/MM/dd HH:mm:ss", null, DateTimeStyles.None, out start);
                        else if (line.StartsWith("<<<  Section end"))
                        {
                            if (start >= since && (header.StartsWith("Device Install") || header.StartsWith("Setup Import Driver Package")) && inf != null && ver != null)
                                found.Add(new ChangeItem { Time = start, Kind = "Драйвер", Inf = inf, Version = ver });
                            header = null;
                        }
                        else
                        {
                            if (inf == null)
                            {
                                var m = Regex.Match(line, @"\\([\w\-\.]+\.inf)\b", RegexOptions.IgnoreCase);
                                if (m.Success && !m.Groups[1].Value.StartsWith("oem", StringComparison.OrdinalIgnoreCase)) inf = m.Groups[1].Value.ToLowerInvariant();
                            }
                            if (ver == null)
                            {
                                var m = Regex.Match(line, @"Driver Version\s*=\s*([\d/]+,[\d\.]+)");
                                if (m.Success) ver = m.Groups[1].Value.Split(',')[1];
                            }
                        }
                    }
                }
                catch { }
            }
            // Лишаємо тільки реальні зміни версії (той самий драйвер часто перевстановлюється при кожному завантаженні)
            var res = new List<ChangeItem>();
            var last = new Dictionary<string, string>();
            foreach (var x in found.OrderBy(x => x.Time))
            {
                string prev;
                bool had = last.TryGetValue(x.Inf, out prev);
                if (had && prev == x.Version) continue;
                last[x.Inf] = x.Version;
                x.Text = Friendly(x.Inf) + " → " + x.Version + (x.IsNvidiaDisplay ? " (NVIDIA " + CrashAnalyzer.NvVersion(x.Version) + ")" : "") + (had ? "  (було " + prev + ")" : "");
                res.Add(x);
            }
            return res;
        }

        static string Friendly(string inf)
        {
            if (inf.StartsWith("nv_disp")) return "NVIDIA відеодрайвер (" + inf + ")";
            if (inf.StartsWith("nv")) return "NVIDIA (" + inf + ")";
            if (inf.StartsWith("u0")) return "AMD Radeon, вбудована графіка (" + inf + ")";
            if (inf.StartsWith("amd")) return "AMD чипсет (" + inf + ")";
            return inf;
        }
    }

    // ================================================================ аналіз дампів через cdb (WinDbg)
    class DumpAnalysis
    {
        public string Raw = "";
        public Dictionary<string, string> Keys = new Dictionary<string, string>();
        public List<string> Stack = new List<string>();

        public string Summary()
        {
            var sb = new StringBuilder();
            foreach (var k in new[] { "BUGCHECK_CODE", "PROCESS_NAME", "MODULE_NAME", "IMAGE_NAME", "IMAGE_VERSION", "NVIDIA_DRIVER", "DRIVER_BUILD", "DPC_TIMEOUT_TYPE", "SYMBOL_NAME", "FAILURE_BUCKET_ID" })
            {
                string v;
                if (Keys.TryGetValue(k, out v)) sb.AppendLine(string.Format("  {0,-18} {1}", k, v));
            }
            if (Stack.Count > 0)
            {
                sb.AppendLine("  Стек викликів (верхні кадри):");
                foreach (var l in Stack.Take(10)) sb.AppendLine("    " + l);
            }
            if (sb.Length == 0) sb.AppendLine("  (не вдалося розібрати вивід — відкрийте повний вивід)");
            return sb.ToString();
        }
    }

    static class DumpAnalyzer
    {
        static string cdbPath;
        static bool searched;
        public static string AnalysisDir { get { return Path.Combine(Program.DataDir, "analysis"); } }

        public static string FindCdb(bool refresh)
        {
            if (searched && !refresh) return cdbPath;
            searched = true;
            cdbPath = null;
            foreach (var p in new[] { @"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe", @"C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe" })
                if (File.Exists(p)) return cdbPath = p;
            try
            {
                var psi = new ProcessStartInfo("powershell", "-NoProfile -Command \"(Get-AppxPackage Microsoft.WinDbg | Select -First 1).InstallLocation\"")
                { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
                using (var p = Process.Start(psi))
                {
                    var dir = p.StandardOutput.ReadToEnd().Trim();
                    p.WaitForExit(15000);
                    if (dir != "")
                        foreach (var sub in new[] { @"amd64\cdb.exe", @"x64\cdb.exe", @"arm64\cdb.exe" })
                            if (File.Exists(Path.Combine(dir, sub))) return cdbPath = Path.Combine(dir, sub);
                }
            }
            catch { }
            return null;
        }

        public static string ResultPath(string dump) { return Path.Combine(AnalysisDir, Path.GetFileName(dump) + ".txt"); }
        public static string PendingPath(string dump) { return ResultPath(dump) + ".pending"; }

        public static bool CanRead(string path)
        {
            try { using (File.OpenRead(path)) return true; } catch { return false; }
        }

        // Повертає null, якщо аналіз завершено або запущено; інакше текст помилки
        public static string Start(string dump)
        {
            var cdb = FindCdb(false);
            if (cdb == null) return "WinDbg не встановлено.";
            Directory.CreateDirectory(AnalysisDir);
            File.WriteAllText(PendingPath(dump), DateTime.Now.ToString("o"));
            try
            {
                if (CanRead(dump))
                    System.Threading.ThreadPool.QueueUserWorkItem(_ => Run(dump));
                else
                    Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--analyze \"" + dump + "\"") { UseShellExecute = true, Verb = "runas" });
                return null;
            }
            catch (Exception ex)
            {
                try { File.Delete(PendingPath(dump)); } catch { }
                return ex.Message; // наприклад, користувач відмовився від UAC
            }
        }

        // Виконується у фоні або в окремому процесі з правами адміністратора (--analyze)
        public static void Run(string dump)
        {
            Directory.CreateDirectory(AnalysisDir);
            var cdb = FindCdb(false);
            string output;
            try
            {
                var sym = "srv*" + Path.Combine(Program.DataDir, "symbols") + "*https://msdl.microsoft.com/download/symbols";
                var psi = new ProcessStartInfo(cdb, "-z \"" + dump + "\" -y \"" + sym + "\" -c \"!analyze -v; lmvm nvlddmkm; q\"")
                { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
                using (var p = Process.Start(psi))
                {
                    var task = p.StandardOutput.ReadToEndAsync();
                    if (!p.WaitForExit(10 * 60 * 1000)) { try { p.Kill(); } catch { } }
                    output = task.Result;
                }
            }
            catch (Exception ex) { output = "Помилка запуску cdb: " + ex.Message; }
            File.WriteAllText(ResultPath(dump), output, Encoding.UTF8);
            try { File.Delete(PendingPath(dump)); } catch { }
        }

        public static bool IsPending(string dump)
        {
            var p = PendingPath(dump);
            if (!File.Exists(p)) return false;
            if (File.GetLastWriteTime(p) < DateTime.Now.AddMinutes(-15)) { try { File.Delete(p); } catch { } return false; }
            return true;
        }

        public static DumpAnalysis Load(string dump)
        {
            var path = ResultPath(dump);
            if (!File.Exists(path)) return null;
            var a = new DumpAnalysis();
            try { a.Raw = File.ReadAllText(path); } catch { return null; }
            var lines = a.Raw.Replace("\r", "").Split('\n');
            for (int i = 0; i < lines.Length; i++)
            {
                var m = Regex.Match(lines[i], @"^([A-Z][A-Z0-9_]+):\s+(.*)$");
                if (!m.Success) continue;
                var key = m.Groups[1].Value;
                if (key == "STACK_TEXT")
                {
                    for (int j = i + 1; j < lines.Length && lines[j].Trim() != ""; j++)
                    {
                        // "ffff... ffff... : retaddr args : nvlddmkm+0x1234" → беремо символ у кінці
                        var parts = lines[j].Split(new[] { " : " }, StringSplitOptions.None);
                        var frame = parts[parts.Length - 1].Trim();
                        if (!frame.StartsWith("0x")) a.Stack.Add(frame); // голі адреси без символу — шум
                    }
                }
                else if (!a.Keys.ContainsKey(key) && m.Groups[2].Value.Trim() != "") a.Keys[key] = m.Groups[2].Value.Trim();
            }
            var fv = Regex.Match(a.Raw, @"^\s+File version:\s+(\S+)", RegexOptions.Multiline);
            var ts = Regex.Match(a.Raw, @"^\s+Timestamp:\s+(.+?)\s+\(", RegexOptions.Multiline);
            if (ts.Success) a.Keys["DRIVER_BUILD"] = ts.Groups[1].Value;
            if (fv.Success) a.Keys["NVIDIA_DRIVER"] = fv.Groups[1].Value + " (" + CrashAnalyzer.NvVersion(fv.Groups[1].Value) + ")";
            return a;
        }

        public static void InstallWinDbg()
        {
            // На старих збірках Windows 10 / LTSC winget може не бути — тоді відкриваємо сторінку завантаження
            bool hasWinget = File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\winget.exe"));
            if (!hasWinget) { TrayApp.Open("https://aka.ms/windbg/download"); return; }
            Process.Start(new ProcessStartInfo("cmd.exe", "/k winget install --id Microsoft.WinDbg -e --accept-package-agreements && echo. && echo Готово. Поверніться в DEADPIXEL і натисніть «Аналізувати».") { UseShellExecute = true });
        }
    }

    // ================================================================ пакет для діагностики
    static class DiagPack
    {
        public static string Build(TrayApp app)
        {
            var stamp = DateTime.Now.ToString("yyyy-MM-dd_HH-mm");
            var stage = Path.Combine(Program.DataDir, "pack-tmp", stamp);
            Directory.CreateDirectory(stage);

            var sb = new StringBuilder();
            sb.AppendLine("DEADPIXEL — пакет для діагностики, " + DateTime.Now.ToString("yyyy-MM-dd HH:mm") + ", " + Environment.MachineName);
            sb.AppendLine(new string('=', 80));
            sb.AppendLine(SystemInfo.Build(app));
            sb.AppendLine(new string('=', 80));
            sb.AppendLine("ЗАКОНОМІРНОСТІ");
            sb.AppendLine(app.PatternText);
            foreach (var c in app.Crashes.OrderByDescending(c => c.Boot))
            {
                sb.AppendLine(new string('=', 80));
                sb.AppendLine(CrashAnalyzer.Describe(c));
            }
            sb.AppendLine(new string('=', 80));
            sb.AppendLine("ЗМІНИ (драйвери, оновлення, програми)");
            foreach (var x in app.Changes) sb.AppendLine(string.Format("{0:yyyy-MM-dd HH:mm}  {1,-20} {2}", x.Time, x.Kind, x.Text));
            sb.AppendLine(new string('=', 80));
            sb.AppendLine("ПОДІЇ (останні 7 днів)");
            lock (app.Events.Lock)
                foreach (var e in app.Events.Items) sb.AppendLine(string.Format("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2} {3}: {4}", e.Time, e.Category, e.Source, e.Id, e.Text));
            File.WriteAllText(Path.Combine(stage, "summary.txt"), sb.ToString(), Encoding.UTF8);

            // CSV за 7 днів, результати аналізу
            var csvDir = Directory.CreateDirectory(Path.Combine(stage, "blackbox")).FullName;
            foreach (var f in Directory.GetFiles(Program.DataDir, "*.csv").Where(f => File.GetLastWriteTime(f) > DateTime.Now.AddDays(-7)))
                CopyShared(f, Path.Combine(csvDir, Path.GetFileName(f)));
            if (Directory.Exists(DumpAnalyzer.AnalysisDir))
            {
                var aDir = Directory.CreateDirectory(Path.Combine(stage, "analysis")).FullName;
                foreach (var f in Directory.GetFiles(DumpAnalyzer.AnalysisDir, "*.txt")) File.Copy(f, Path.Combine(aDir, Path.GetFileName(f)));
            }
            // Дампи TDR, пов'язані з крашами за 30 днів (до 4 шт.)
            var lkrDir = Directory.CreateDirectory(Path.Combine(stage, "LiveKernelReports")).FullName;
            foreach (var d in app.Crashes.Where(c => c.LkrDump != "" && c.Boot > DateTime.Now.AddDays(-30)).OrderByDescending(c => c.Boot).Take(4).Select(c => c.LkrDump))
                CopyShared(d, Path.Combine(lkrDir, Path.GetFileName(d)));

            // Мінідампи читаються лише адміністратором → допоміжний процес з UAC
            var miniDir = Directory.CreateDirectory(Path.Combine(stage, "Minidump")).FullName;
            if (!CopyMinidumps(miniDir))
            {
                try
                {
                    using (var p = Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--copydumps \"" + miniDir + "\"") { UseShellExecute = true, Verb = "runas" }))
                        p.WaitForExit(60000);
                }
                catch { File.WriteAllText(Path.Combine(miniDir, "README.txt"), "Мінідампи не скопійовано: потрібні права адміністратора."); }
            }

            var packs = Directory.CreateDirectory(Path.Combine(Program.DataDir, "packs")).FullName;
            var zip = Path.Combine(packs, "DeadPixel-" + Environment.MachineName + "-" + stamp + ".zip");
            if (File.Exists(zip)) File.Delete(zip);
            ZipFile.CreateFromDirectory(stage, zip, CompressionLevel.Optimal, false);
            try { Directory.Delete(Path.Combine(Program.DataDir, "pack-tmp"), true); } catch { }
            return zip;
        }

        static void CopyShared(string src, string dst)
        {
            try
            {
                using (var i = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var o = File.Create(dst)) i.CopyTo(o);
            }
            catch { }
        }

        // Повертає false, якщо доступу немає
        public static bool CopyMinidumps(string dir)
        {
            var src = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Minidump");
            try
            {
                var files = new DirectoryInfo(src).GetFiles("*.dmp").OrderByDescending(f => f.LastWriteTime).Take(5).ToList();
                foreach (var f in files) f.CopyTo(Path.Combine(dir, f.Name), true);
                return true;
            }
            catch { return false; }
        }
    }
}
