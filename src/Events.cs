using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace CrashDoctor
{
    static class BugChecks
    {
        static readonly Dictionary<long, string[]> Map = new Dictionary<long, string[]>
        {
            { 0x0A, new[] { "IRQL_NOT_LESS_OR_EQUAL", "Драйвер звернувся до недопустимої пам'яті (драйвер або RAM)." } },
            { 0x1A, new[] { "MEMORY_MANAGEMENT", "Помилка пам'яті. Перевірити RAM, вимкнути EXPO/XMP для тесту." } },
            { 0x1E, new[] { "KMODE_EXCEPTION_NOT_HANDLED", "Необроблений виняток у драйвері." } },
            { 0x3B, new[] { "SYSTEM_SERVICE_EXCEPTION", "Виняток у системному виклику (часто драйвер)." } },
            { 0x50, new[] { "PAGE_FAULT_IN_NONPAGED_AREA", "Звернення до неіснуючої пам'яті: драйвер, RAM або диск." } },
            { 0x7E, new[] { "SYSTEM_THREAD_EXCEPTION_NOT_HANDLED", "Виняток у системному потоці (драйвер)." } },
            { 0x7F, new[] { "UNEXPECTED_KERNEL_MODE_TRAP", "Апаратна проблема CPU/RAM." } },
            { 0x9F, new[] { "DRIVER_POWER_STATE_FAILURE", "Драйвер не впорався з переходом живлення (сон/пробудження)." } },
            { 0xD1, new[] { "DRIVER_IRQL_NOT_LESS_OR_EQUAL", "Драйвер звернувся до пам'яті на високому IRQL." } },
            { 0xEF, new[] { "CRITICAL_PROCESS_DIED", "Критичний системний процес завершився." } },
            { 0x101, new[] { "CLOCK_WATCHDOG_TIMEOUT", "Ядро CPU не відповідає (PBO/Curve Optimizer/CPU)." } },
            { 0x116, new[] { "VIDEO_TDR_FAILURE", "GPU завис, і Windows не змогла перезапустити відеодрайвер." } },
            { 0x117, new[] { "VIDEO_TDR_TIMEOUT_DETECTED", "Відеодрайвер перестав відповідати (відновлено)." } },
            { 0x119, new[] { "VIDEO_SCHEDULER_INTERNAL_ERROR", "Помилка планувальника GPU." } },
            { 0x124, new[] { "WHEA_UNCORRECTABLE_ERROR", "Некоректовна апаратна помилка (CPU/RAM/PCIe)." } },
            { 0x133, new[] { "DPC_WATCHDOG_VIOLATION", "Драйвер занадто довго тримав CPU (часто GPU/NVMe/USB)." } },
            { 0x139, new[] { "KERNEL_SECURITY_CHECK_FAILURE", "Пошкодження структур ядра: драйвер або RAM." } },
            { 0x141, new[] { "VIDEO_ENGINE_TIMEOUT_DETECTED", "GPU завис, драйвер перезапущено без BSOD." } },
            { 0x144, new[] { "BUGCODE_USB3_DRIVER", "Збій USB3-контролера/пристрою." } },
            { 0x154, new[] { "UNEXPECTED_STORE_EXCEPTION", "Проблема з диском або пам'яттю." } },
            { 0x1B8, new[] { "GPU_LIVE_DUMP", "Дамп стану GPU разом із TDR." } },
        };

        public static string[] Get(long code)
        {
            string[] v;
            if (Map.TryGetValue(code, out v)) return v;
            if (code == 0) return new[] { "Без BSOD", "Раптове вимкнення: живлення, ручний ресет, БЖ або перегрів." };
            return new[] { "UNKNOWN", string.Format("Невідомий код 0x{0:X}", code) };
        }
    }

    class EvItem
    {
        public DateTime Time;
        public string Category, Source, Text;
        public int Id;
        public byte Level; // 1 критична, 2 помилка, 3 попередження
    }

    class CrashInfo
    {
        public DateTime Boot, Moment;
        public long Code;
        public string Driver = "", Dump = "", LastFg = "", LkrDump = "", MomentSource = "", DriverAtCrash = "?";
        public TimeSpan? Uptime;
        public List<Sample> Rows = new List<Sample>();
        public List<ProcEvent> Procs = new List<ProcEvent>();
        public List<EvItem> Events = new List<EvItem>();
        public Sample LastSample;
        public ProcEvent LastExit;
    }

    class EventMonitor
    {
        const string SysProviders = "@Name='nvlddmkm' or @Name='Display' or @Name='amdkmdag' or @Name='Microsoft-Windows-WHEA-Logger' or @Name='disk' or @Name='Ntfs' or @Name='stornvme' or @Name='storahci' or @Name='USBXHCI' or @Name='USBHUB3' or @Name='Microsoft-Windows-Kernel-Processor-Power'";
        const string AppProviders = "@Name='Application Error' or @Name='Application Hang'";

        public readonly object Lock = new object();
        public readonly List<EvItem> Items = new List<EvItem>();
        public int Version;
        public event Action<EvItem> NewEvent;
        readonly List<IDisposable> keep = new List<IDisposable>();

        static string Xp(string providers, int days)
        {
            var q = "*[System[Provider[" + providers + "] and (Level=1 or Level=2 or Level=3)";
            if (days > 0) q += " and TimeCreated[timediff(@SystemTime) <= " + ((long)days * 86400000L) + "]";
            return q + "]]";
        }

        public void LoadInitial(int days)
        {
            var list = new List<EvItem>();
            list.AddRange(Read("System", Xp(SysProviders, days), 300));
            list.AddRange(Read("Application", Xp(AppProviders, days), 100));
            lock (Lock)
            {
                Items.AddRange(list.OrderByDescending(e => e.Time));
                Version++;
            }
        }

        static IEnumerable<EvItem> Read(string log, string xpath, int max)
        {
            var res = new List<EvItem>();
            try
            {
                using (var r = new EventLogReader(new EventLogQuery(log, PathType.LogName, xpath) { ReverseDirection = true }))
                {
                    EventRecord rec;
                    while (res.Count < max && (rec = r.ReadEvent()) != null)
                        using (rec) res.Add(Make(rec));
                }
            }
            catch { }
            return res;
        }

        public void StartWatching()
        {
            Watch("System", Xp(SysProviders, 0));
            Watch("Application", Xp(AppProviders, 0));
            try
            {
                var lkr = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "LiveKernelReports");
                var fw = new FileSystemWatcher(lkr, "*.dmp") { IncludeSubdirectories = true };
                fw.Created += (s, e) =>
                {
                    var cat = e.FullPath.IndexOf("USB", StringComparison.OrdinalIgnoreCase) >= 0 ? "USB" : "GPU";
                    Add(new EvItem
                    {
                        Time = DateTime.Now, Category = cat, Source = "LiveKernelReports", Level = 2,
                        Text = (cat == "GPU" ? "Зависання GPU — Windows перезапустила драйвер. " : "Збій USB-контролера. ") + e.FullPath
                    }, true);
                };
                fw.EnableRaisingEvents = true;
                keep.Add(fw);
            }
            catch { }
        }

        void Watch(string log, string xpath)
        {
            try
            {
                var w = new EventLogWatcher(new EventLogQuery(log, PathType.LogName, xpath));
                w.EventRecordWritten += (s, e) =>
                {
                    if (e.EventRecord == null) return;
                    using (e.EventRecord) Add(Make(e.EventRecord), true);
                };
                w.Enabled = true;
                keep.Add(w);
            }
            catch { }
        }

        public void AddExternal(EvItem it) { Add(it, false); }

        void Add(EvItem it, bool live)
        {
            lock (Lock)
            {
                Items.Insert(0, it);
                if (Items.Count > 600) Items.RemoveAt(Items.Count - 1);
                Version++;
            }
            var h = NewEvent;
            if (live && h != null) h(it);
        }

        static string Category(string provider)
        {
            if (provider == "nvlddmkm" || provider == "Display" || provider == "amdkmdag") return "GPU";
            if (provider.Contains("WHEA")) return "WHEA";
            if (provider.Contains("Processor-Power")) return "CPU";
            if (provider.StartsWith("USB")) return "USB";
            if (provider.StartsWith("Application")) return "Програма";
            return "Диск";
        }

        public static EvItem Make(EventRecord r)
        {
            var it = new EvItem { Time = r.TimeCreated ?? DateTime.Now, Source = r.ProviderName ?? "?", Id = r.Id, Level = r.Level ?? 3 };
            it.Category = Category(it.Source);
            string text = null;
            try
            {
                if (it.Source == "Application Error" && r.Properties.Count > 3)
                    text = r.Properties[0].Value + " впала (модуль: " + r.Properties[3].Value + ")";
                else if (it.Source == "Application Hang" && r.Properties.Count > 0)
                    text = r.Properties[0].Value + " зависла і була закрита";
                else text = r.FormatDescription();
            }
            catch { }
            if (string.IsNullOrWhiteSpace(text))
                text = string.Join(" | ", r.Properties.Select(p => p.Value as string).Where(v => !string.IsNullOrWhiteSpace(v)));
            text = Regex.Replace(text ?? "", @"\s+", " ").Trim();
            it.Text = text.Length > 400 ? text.Substring(0, 400) + "…" : text;
            return it;
        }

        public static List<CrashInfo> ScanCrashes(int days)
        {
            var ms = ((long)days * 86400000L).ToString();
            var kp = ReadRaw("System", "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=41 and TimeCreated[timediff(@SystemTime) <= " + ms + "]]]");
            var wer = ReadRaw("System", "*[System[Provider[@Name='Microsoft-Windows-WER-SystemErrorReporting'] and (EventID=1001 or EventID=1019) and TimeCreated[timediff(@SystemTime) <= " + ms + "]]]");
            var res = new List<CrashInfo>();
            foreach (var k in kp)
            {
                var c = new CrashInfo { Boot = k.Item1 };
                try { c.Code = Convert.ToInt64(k.Item3[0]); } catch { }
                foreach (var w in wer.Where(x => Math.Abs((x.Item1 - k.Item1).TotalMinutes) < 5))
                {
                    // властивості подій не залежать від мови Windows (на відміну від тексту повідомлення)
                    foreach (var p in w.Item3.Select(x => Convert.ToString(x) ?? ""))
                    {
                        if (p.EndsWith(".dmp", StringComparison.OrdinalIgnoreCase)) c.Dump = p;
                        else if (p.EndsWith(".sys", StringComparison.OrdinalIgnoreCase)) c.Driver = p;
                    }
                }
                res.Add(c);
            }
            return res;
        }

        public static List<Tuple<DateTime, string, object[]>> ReadRawPublic(string log, string xpath) { return ReadRaw(log, xpath); }

        // Час кожного завантаження системи (Kernel-General 12)
        public static List<DateTime> BootTimes(int days)
        {
            return ReadRaw("System", "*[System[Provider[@Name='Microsoft-Windows-Kernel-General'] and EventID=12 and TimeCreated[timediff(@SystemTime) <= " + ((long)days * 86400000L) + "]]]")
                .Select(x => x.Item1).OrderBy(x => x).ToList();
        }

        // Усі помилки/попередження System + падіння програм у проміжку часу
        public static List<EvItem> QueryRange(DateTime from, DateTime to)
        {
            string f = from.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"), t = to.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
            var time = "TimeCreated[@SystemTime>='" + f + "' and @SystemTime<='" + t + "']";
            var res = new List<EvItem>();
            res.AddRange(Read("System", "*[System[(Level=1 or Level=2 or Level=3) and " + time + "]]", 200));
            res.AddRange(Read("Application", "*[System[Provider[" + AppProviders + "] and " + time + "]]", 100));
            return res.Where(e => !(e.Source == "Microsoft-Windows-DistributedCOM")).OrderBy(e => e.Time).ToList();
        }

        static List<Tuple<DateTime, string, object[]>> ReadRaw(string log, string xpath)
        {
            var res = new List<Tuple<DateTime, string, object[]>>();
            try
            {
                using (var r = new EventLogReader(new EventLogQuery(log, PathType.LogName, xpath) { ReverseDirection = true }))
                {
                    EventRecord rec;
                    while ((rec = r.ReadEvent()) != null)
                        using (rec)
                        {
                            string msg = "";
                            try { msg = rec.FormatDescription() ?? ""; } catch { }
                            res.Add(Tuple.Create(rec.TimeCreated ?? DateTime.MinValue, msg.Trim(), rec.Properties.Select(p => p.Value).ToArray()));
                        }
                }
            }
            catch { }
            return res;
        }
    }
}
