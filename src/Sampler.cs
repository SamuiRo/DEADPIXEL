using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DeadPixel
{
    class Sample
    {
        public DateTime Time;
        public string Fg = "";
        // GPU
        public double GpuTemp = double.NaN, GpuPower = double.NaN, GpuClock = double.NaN, MemClock = double.NaN,
                      GpuUtil = double.NaN, VramMb = double.NaN, Fan = double.NaN;
        public string PState = "", PcieGen = "", Reasons = "";
        // CPU / система
        public double CpuPct = double.NaN, CpuMaxCore = double.NaN, CpuMhz = double.NaN, CpuTemp = double.NaN, RamPct = double.NaN;
        public double RamUsedGb = double.NaN, RamTotalGb = double.NaN;
    }

    class ProcEvent
    {
        public DateTime Time;
        public string Kind, Name; // start | exit | fg
        public int Pid;
        public long RamMb;
    }

    // Збирає телеметрію з інтервалом і пише "чорну скриньку" у data\blackbox-ДАТА.csv
    class Sampler
    {
        public const int MaxSamples = 600;
        public const string Header = "time,foreground,gpu_temp,gpu_power_w,gpu_clock,gpu_memclock,pstate,pcie_gen,gpu_util,vram_mb,gpu_fan,gpu_reasons,cpu_pct,cpu_max_core,cpu_mhz,cpu_temp,ram_pct";
        // Старі драйвери (до ~R530) знають поле лише як clocks_throttle_reasons.active
        string GpuQuery = "temperature.gpu,power.draw,clocks.gr,clocks.mem,pstate,pcie.link.gen.current,utilization.gpu,memory.used,fan.speed,clocks_event_reasons.active";

        public readonly object Lock = new object();
        readonly List<Sample> samples = new List<Sample>();
        public volatile Sample Last;
        public string GpuName = "GPU", Driver = "?";
        public volatile string Status = L.T("запуск…", "starting…");
        public readonly CpuTempSource CpuTemp = new CpuTempSource();
        public readonly StallDetector Stalls = new StallDetector();

        readonly Settings settings;
        volatile string[] gpuCells;   // останній рядок від nvidia-smi
        Process smi;
        int smiInterval;
        volatile bool stopping;
        FileStream fs;
        string fsDate;

        PerformanceCounter cpuUtil, cpuPerf, cpuFreq;
        PerformanceCounter[] coreUtil = new PerformanceCounter[0];

        public Sampler(Settings s) { settings = s; }

        public void Start()
        {
            Cleanup();
            new Thread(SmiLoop) { IsBackground = true, Name = "nvidia-smi" }.Start();
            new Thread(SampleLoop) { IsBackground = true, Name = "sampler" }.Start();
        }

        public void Stop()
        {
            stopping = true;
            KillSmi();
            try { if (fs != null) fs.Dispose(); } catch { }
            try { if (pfs != null) pfs.Dispose(); } catch { }
        }

        public void Cleanup()
        {
            try
            {
                foreach (var f in Directory.GetFiles(Program.DataDir, "*.csv"))
                    if (File.GetLastWriteTime(f) < DateTime.Now.AddDays(-settings.RetentionDays)) File.Delete(f);
            }
            catch { }
        }

        void KillSmi()
        {
            try { if (smi != null && !smi.HasExited) smi.Kill(); } catch { }
        }

        public List<Sample> Snapshot()
        {
            lock (Lock) return new List<Sample>(samples);
        }

        // ---------------------------------------------------------- GPU (nvidia-smi у режимі потоку)
        void SmiLoop()
        {
            bool found = true;
            try
            {
                var info = RunOnce("nvidia-smi", "--query-gpu=name,driver_version --format=csv,noheader").Split(',');
                if (info.Length >= 2) { GpuName = info[0].Trim(); Driver = info[1].Trim(); }
                var probe = RunOnce("nvidia-smi", "--query-gpu=clocks_event_reasons.active --format=csv,noheader");
                if (!probe.StartsWith("0x")) GpuQuery = GpuQuery.Replace("clocks_event_reasons", "clocks_throttle_reasons");
            }
            catch { found = false; Status = L.T("nvidia-smi не знайдено (не NVIDIA або драйвер без nvidia-smi) — пишу лише CPU", "nvidia-smi not found (not NVIDIA or a driver without nvidia-smi) — recording CPU only"); }
            while (!stopping)
            {
                try
                {
                    smiInterval = settings.IntervalSec;
                    var psi = new ProcessStartInfo("nvidia-smi", "--query-gpu=" + GpuQuery + " --format=csv,noheader,nounits -lms " + (smiInterval * 1000))
                    { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
                    using (smi = Process.Start(psi))
                    {
                        found = true;
                        Native.KillWithUs(smi);
                        string line;
                        while (!stopping && (line = smi.StandardOutput.ReadLine()) != null)
                        {
                            var p = line.Split(',');
                            if (p.Length >= 10) gpuCells = p.Select(x => x.Trim()).ToArray();
                        }
                    }
                }
                catch (Exception ex) { found = false; Status = "nvidia-smi: " + ex.Message; }
                if (stopping || smiInterval != settings.IntervalSec) continue; // перезапуск із новим інтервалом
                gpuCells = null; // не видаємо застарілі дані GPU за свіжі, поки nvidia-smi не запрацює знову
                // Без NVIDIA не шукаємо nvidia-smi кожні 5 с: перевіряємо раз на 5 хв (раптом драйвер поставили)
                Thread.Sleep(found ? 5000 : 300000);
            }
        }

        public void IntervalChanged() { KillSmi(); } // SmiLoop перезапуститься з новим інтервалом

        // ---------------------------------------------------------- основний цикл
        void SampleLoop()
        {
            InitCounters();
            var sw = Stopwatch.StartNew();
            long next = 0;
            while (!stopping)
            {
                try { Tick(); } catch (Exception ex) { Status = L.T("помилка: ", "error: ") + ex.Message; }
                next += settings.IntervalSec * 1000L;
                long wait = next - sw.ElapsedMilliseconds;
                if (wait < 0) { next = sw.ElapsedMilliseconds; wait = 0; }
                Thread.Sleep((int)wait);
            }
        }

        void InitCounters()
        {
            try
            {
                cpuUtil = new PerformanceCounter("Processor Information", "% Processor Utility", "_Total");
                cpuPerf = new PerformanceCounter("Processor Information", "% Processor Performance", "_Total");
                cpuFreq = new PerformanceCounter("Processor Information", "Processor Frequency", "_Total");
                var names = new PerformanceCounterCategory("Processor Information").GetInstanceNames()
                    .Where(n => !n.Contains("_Total")).OrderBy(n => n).ToArray();
                coreUtil = names.Select(n => new PerformanceCounter("Processor Information", "% Processor Utility", n)).ToArray();
                cpuUtil.NextValue(); cpuPerf.NextValue();
                foreach (var c in coreUtil) c.NextValue();
            }
            catch (Exception ex) { Status = L.T("лічильники CPU: ", "CPU counters: ") + ex.Message; }
        }

        static double P(string s)
        {
            double d;
            return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : double.NaN;
        }

        static double Clamp(double v) { return double.IsNaN(v) ? v : Math.Max(0, Math.Min(100, v)); }

        void Tick()
        {
            var s = new Sample { Time = DateTime.Now, Fg = Native.ForegroundProcess() };
            var g = gpuCells;
            if (g != null)
            {
                s.GpuTemp = P(g[0]); s.GpuPower = P(g[1]); s.GpuClock = P(g[2]); s.MemClock = P(g[3]); s.PState = g[4];
                s.PcieGen = g[5]; s.GpuUtil = P(g[6]); s.VramMb = P(g[7]); s.Fan = P(g[8]); s.Reasons = g[9];
            }
            if (cpuUtil != null)
            {
                s.CpuPct = Clamp(cpuUtil.NextValue());
                // реальна частота = номінальна × % продуктивності (так рахує Диспетчер завдань)
                s.CpuMhz = cpuFreq.NextValue() * cpuPerf.NextValue() / 100.0;
                double max = 0;
                foreach (var c in coreUtil) max = Math.Max(max, c.NextValue());
                s.CpuMaxCore = Clamp(max);
            }
            s.CpuTemp = CpuTemp.Read();
            var mem = new Native.MEMORYSTATUSEX();
            if (Native.GlobalMemoryStatusEx(mem))
            {
                s.RamPct = mem.dwMemoryLoad;
                s.RamTotalGb = mem.ullTotalPhys / 1073741824.0;
                s.RamUsedGb = (mem.ullTotalPhys - mem.ullAvailPhys) / 1073741824.0;
            }
            lock (Lock)
            {
                samples.Add(s);
                if (samples.Count > MaxSamples) samples.RemoveAt(0);
            }
            Last = s;
            Write(s);
            // Знімок усіх процесів — найдорожча частина тіку, тож не частіше ніж раз на ~4 с
            if (++procTick * settings.IntervalSec >= 4) { procTick = 0; try { TrackProcesses(s); } catch { } }
            try { Stalls.Sample(s.Time); } catch { }
            Status = g != null ? L.T("запис іде", "recording") : L.T("запис іде (без даних GPU)", "recording (no GPU data)");
        }

        static string N(double v, string f) { return double.IsNaN(v) ? "" : v.ToString(f, CultureInfo.InvariantCulture); }

        void Write(Sample s)
        {
            var date = s.Time.ToString("yyyy-MM-dd");
            if (fs == null || fsDate != date)
            {
                if (fs != null) fs.Dispose();
                var path = Path.Combine(Program.DataDir, "blackbox-" + date + ".csv");
                bool isNew = !File.Exists(path);
                // WriteThrough — щоб рядки гарантовано були на диску навіть при BSOD
                fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite, 4096, FileOptions.WriteThrough);
                fsDate = date;
                if (isNew) WriteRaw(Header + "\r\n");
                Cleanup();
            }
            var line = string.Join(",", new[]
            {
                s.Time.ToString("yyyy-MM-dd HH:mm:ss"), s.Fg.Replace(",", " "),
                N(s.GpuTemp, "0"), N(s.GpuPower, "0.0"), N(s.GpuClock, "0"), N(s.MemClock, "0"), s.PState, s.PcieGen,
                N(s.GpuUtil, "0"), N(s.VramMb, "0"), N(s.Fan, "0"), s.Reasons,
                N(s.CpuPct, "0"), N(s.CpuMaxCore, "0"), N(s.CpuMhz, "0"), N(s.CpuTemp, "0.0"), N(s.RamPct, "0")
            });
            WriteRaw(line + "\r\n");
        }

        void WriteRaw(string text)
        {
            var b = Encoding.UTF8.GetBytes(text);
            fs.Write(b, 0, b.Length);
            fs.Flush(true);
        }

        static string RunOnce(string exe, string args)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
            using (var p = Process.Start(psi)) { var s = p.StandardOutput.ReadToEnd(); p.WaitForExit(5000); return s.Trim(); }
        }

        // ---------------------------------------------------------- журнал процесів
        // Пишемо запуск/закриття "важких" процесів (ігри тощо) і зміну активного вікна у data\procs-ДАТА.csv
        public const string ProcHeader = "time,event,name,pid,ram_mb";
        const long HeavyBytes = 400L * 1048576, HeavyFgBytes = 150L * 1048576;
        class Tracked { public string Name; public long MaxWs; }
        readonly Dictionary<int, Tracked> heavy = new Dictionary<int, Tracked>();
        bool procsPrimed;
        int procTick = 100; // перший тік одразу знімає список процесів
        string lastFg = "";
        FileStream pfs;
        string pfsDate;

        void TrackProcesses(Sample s)
        {
            int fgPid = Native.ForegroundPid();
            var seen = new HashSet<int>();
            var events = new List<string>();
            foreach (var p in Process.GetProcesses())
            {
                using (p)
                {
                    long ws;
                    try { ws = p.WorkingSet64; } catch { continue; }
                    seen.Add(p.Id);
                    Tracked t;
                    if (heavy.TryGetValue(p.Id, out t)) { if (ws > t.MaxWs) t.MaxWs = ws; continue; }
                    if (ws >= HeavyBytes || (p.Id == fgPid && ws >= HeavyFgBytes))
                    {
                        heavy[p.Id] = new Tracked { Name = p.ProcessName, MaxWs = ws };
                        if (procsPrimed) events.Add(ProcLine(s.Time, "start", p.ProcessName, p.Id, ws));
                    }
                }
            }
            foreach (var id in heavy.Keys.Where(k => !seen.Contains(k)).ToList())
            {
                events.Add(ProcLine(s.Time, "exit", heavy[id].Name, id, heavy[id].MaxWs));
                heavy.Remove(id);
            }
            if (s.Fg != lastFg && procsPrimed) events.Add(ProcLine(s.Time, "fg", s.Fg, fgPid, 0));
            lastFg = s.Fg;
            procsPrimed = true;
            if (events.Count == 0) return;

            var date = s.Time.ToString("yyyy-MM-dd");
            if (pfs == null || pfsDate != date)
            {
                if (pfs != null) pfs.Dispose();
                var path = Path.Combine(Program.DataDir, "procs-" + date + ".csv");
                bool isNew = !File.Exists(path);
                pfs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite, 4096, FileOptions.WriteThrough);
                pfsDate = date;
                if (isNew) events.Insert(0, ProcHeader);
            }
            var b = Encoding.UTF8.GetBytes(string.Join("\r\n", events) + "\r\n");
            pfs.Write(b, 0, b.Length);
            pfs.Flush(true);
        }

        static string ProcLine(DateTime t, string ev, string name, int pid, long ws)
        {
            return t.ToString("yyyy-MM-dd HH:mm:ss") + "," + ev + "," + (name ?? "").Replace(",", " ") + "," + pid + "," + (ws / 1048576);
        }

        // ---------------------------------------------------------- читання записів
        static readonly string[] BlackboxPrefixes = { "gpu-", "blackbox-" };

        // Сирі рядки з CSV-файлів (за префіксом) у діапазоні часу
        public static List<string> ReadRange(string[] prefixes, DateTime from, DateTime to)
        {
            var result = new List<string>();
            for (var d = from.Date; d <= to.Date; d = d.AddDays(1))
                foreach (var prefix in prefixes)
                {
                    var path = Path.Combine(Program.DataDir, prefix + d.ToString("yyyy-MM-dd") + ".csv");
                    if (!File.Exists(path)) continue;
                    try
                    {
                        using (var sr = new StreamReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)))
                        {
                            string line;
                            while ((line = sr.ReadLine()) != null)
                            {
                                DateTime t;
                                if (!TryTime(line, out t)) continue;
                                if (t >= from && t <= to) result.Add(line);
                            }
                        }
                    }
                    catch { }
                }
            result.Sort(StringComparer.Ordinal);
            return result;
        }

        public static bool TryTime(string line, out DateTime t)
        {
            t = DateTime.MinValue;
            return line != null && line.Length >= 19 && DateTime.TryParseExact(line.Substring(0, 19), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out t);
        }

        // Останні рядки "чорної скриньки" перед заданим моментом (у межах 15 хв)
        public static List<string> ReadBefore(DateTime before, int count)
        {
            var result = ReadRange(BlackboxPrefixes, before.AddMinutes(-15), before.AddSeconds(-1));
            return result.Skip(Math.Max(0, result.Count - count)).ToList();
        }

        public static List<Sample> ReadSamples(DateTime from, DateTime to)
        {
            var res = new List<Sample>();
            foreach (var l in ReadRange(BlackboxPrefixes, from, to))
            {
                var s = ParseLine(l);
                if (s != null) res.Add(s);
            }
            return res;
        }

        public static List<ProcEvent> ReadProcEvents(DateTime from, DateTime to)
        {
            var res = new List<ProcEvent>();
            foreach (var l in ReadRange(new[] { "procs-" }, from, to))
            {
                var c = l.Split(',');
                if (c.Length < 5) continue;
                DateTime t;
                TryTime(l, out t);
                int pid; long ram;
                int.TryParse(c[3], out pid); long.TryParse(c[4], out ram);
                res.Add(new ProcEvent { Time = t, Kind = c[1], Name = c[2], Pid = pid, RamMb = ram });
            }
            return res;
        }

        // Рядок чорної скриньки → Sample (старий формат gpu-*.csv має ті самі перші 12 колонок)
        public static Sample ParseLine(string line)
        {
            DateTime t;
            if (!TryTime(line, out t)) return null;
            var c = line.Split(',');
            if (c.Length < 12) return null;
            var s = new Sample
            {
                Time = t, Fg = c[1], GpuTemp = P(c[2]), GpuPower = P(c[3]), GpuClock = P(c[4]), MemClock = P(c[5]), PState = c[6],
                PcieGen = c[7], GpuUtil = P(c[8]), VramMb = P(c[9]), Fan = P(c[10]), Reasons = c[11]
            };
            if (c.Length >= 17) { s.CpuPct = P(c[12]); s.CpuMaxCore = P(c[13]); s.CpuMhz = P(c[14]); s.CpuTemp = P(c[15]); s.RamPct = P(c[16]); }
            return s;
        }
        public static string DecodeReasons(string hex)
        {
            long v;
            if (string.IsNullOrEmpty(hex) || !long.TryParse(hex.Replace("0x", ""), NumberStyles.HexNumber, null, out v)) return "—";
            if (v == 0) return L.T("немає", "none");
            var r = new List<string>();
            if ((v & 0x1) != 0) r.Add("Idle");
            if ((v & 0x2) != 0) r.Add("AppClocks");
            if ((v & 0x4) != 0) r.Add("PowerCap");
            if ((v & 0x8) != 0) r.Add("HW SLOWDOWN");
            if ((v & 0x10) != 0) r.Add("Sync");
            if ((v & 0x20) != 0) r.Add("SW Thermal");
            if ((v & 0x40) != 0) r.Add("HW THERMAL");
            if ((v & 0x80) != 0) r.Add("POWER BRAKE");
            if ((v & 0x100) != 0) r.Add("DisplayClk");
            if ((v & ~0x1FFL) != 0) r.Add(L.T("інше 0x", "other 0x") + (v & ~0x1FFL).ToString("X")); // нові біти драйвера — без них плитка була б порожня
            return string.Join(", ", r);
        }

        public static bool ReasonsCritical(string hex)
        {
            long v;
            return !string.IsNullOrEmpty(hex) && long.TryParse(hex.Replace("0x", ""), NumberStyles.HexNumber, null, out v) && (v & (0x8 | 0x40 | 0x80)) != 0;
        }
    }

    // Температура CPU: Windows не віддає її без драйвера, тому беремо з LibreHardwareMonitor / OpenHardwareMonitor, якщо запущені
    class CpuTempSource
    {
        string ns;
        DateTime nextProbe = DateTime.MinValue;
        public volatile string Status = L.T("не знайдено — запустіть LibreHardwareMonitor", "not found — start LibreHardwareMonitor");

        public double Read()
        {
            if (ns == null)
            {
                if (DateTime.Now < nextProbe) return double.NaN;
                nextProbe = DateTime.Now.AddSeconds(60);
                foreach (var cand in new[] { @"root\LibreHardwareMonitor", @"root\OpenHardwareMonitor" })
                {
                    var v = Query(cand);
                    if (!double.IsNaN(v)) { ns = cand; Status = L.T("з ", "from ") + cand.Substring(5); return v; }
                }
                return double.NaN;
            }
            var r = Query(ns);
            if (double.IsNaN(r)) { ns = null; Status = L.T("джерело зникло — LibreHardwareMonitor закрито?", "source lost — was LibreHardwareMonitor closed?"); }
            return r;
        }

        static double Query(string scope)
        {
            try
            {
                double best = double.NaN; int bestRank = -1;
                using (var s = new ManagementObjectSearcher(scope, "SELECT Name,Identifier,Value FROM Sensor WHERE SensorType='Temperature'"))
                    foreach (ManagementObject o in s.Get())
                    {
                        var id = (o["Identifier"] as string ?? "").ToLowerInvariant();
                        if (!id.Contains("cpu")) continue;
                        var name = (o["Name"] as string ?? "").ToLowerInvariant();
                        int rank = name.Contains("tctl") || name.Contains("package") ? 3 : name.Contains("tdie") ? 2 : name.Contains("core") ? 1 : 0;
                        if (rank > bestRank) { bestRank = rank; best = Convert.ToDouble(o["Value"]); }
                    }
                return best;
            }
            catch { return double.NaN; }
        }
    }

    // Топ процесів за CPU/RAM — рахується лише коли відкрита вкладка "Процеси"
    class ProcSampler
    {
        readonly Dictionary<int, TimeSpan> prev = new Dictionary<int, TimeSpan>();
        readonly HashSet<int> denied = new HashSet<int>();
        DateTime prevTime = DateTime.MinValue;

        public class Row { public string Name; public int Pid; public double Cpu; public double RamMb; }

        public List<Row> Sample()
        {
            var now = DateTime.Now;
            double elapsedMs = prevTime == DateTime.MinValue ? 0 : (now - prevTime).TotalMilliseconds;
            var rows = new List<Row>();
            var seen = new HashSet<int>();
            foreach (var p in Process.GetProcesses())
            {
                using (p)
                {
                    seen.Add(p.Id);
                    var r = new Row { Name = p.ProcessName, Pid = p.Id, Cpu = double.NaN };
                    try { r.RamMb = p.WorkingSet64 / 1048576.0; } catch { }
                    if (!denied.Contains(p.Id) && p.Id != 0)
                    {
                        try
                        {
                            var t = p.TotalProcessorTime;
                            TimeSpan old;
                            if (elapsedMs > 0 && prev.TryGetValue(p.Id, out old))
                                r.Cpu = (t - old).TotalMilliseconds / elapsedMs / Environment.ProcessorCount * 100.0;
                            prev[p.Id] = t;
                        }
                        catch { denied.Add(p.Id); }
                    }
                    rows.Add(r);
                }
            }
            foreach (var id in prev.Keys.Where(k => !seen.Contains(k)).ToList()) prev.Remove(id);
            denied.RemoveWhere(id => !seen.Contains(id));
            prevTime = now;
            return rows;
        }
    }

    static class Native
    {
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
        [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
        [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr process);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        public static int ForegroundPid()
        {
            try { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return (int)pid; } catch { return 0; }
        }

        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, uint flags, StringBuilder name, ref uint size);
        const uint ProcessQueryLimited = 0x1000;
        static uint fgPid;
        static string fgName = "";

        // Назва без Process.GetProcessById: у .NET Framework ProcessName робить знімок усіх процесів системи
        public static string ForegroundProcess()
        {
            try
            {
                uint pid;
                GetWindowThreadProcessId(GetForegroundWindow(), out pid);
                if (pid == 0) return "";
                if (pid == fgPid) return fgName;
                var h = OpenProcess(ProcessQueryLimited, false, pid);
                if (h == IntPtr.Zero) return "";
                try
                {
                    var sb = new StringBuilder(1024);
                    uint size = (uint)sb.Capacity;
                    if (!QueryFullProcessImageName(h, 0, sb, ref size)) return "";
                    fgPid = pid;
                    return fgName = Path.GetFileNameWithoutExtension(sb.ToString());
                }
                finally { CloseHandle(h); }
            }
            catch { return ""; }
        }

        // ---------------------------------------------------------- дочірні процеси вмирають разом з нами
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int size);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        static IntPtr job;

        // Якщо DEADPIXEL впаде або його вб'ють, система сама закриє nvidia-smi (інакше він працює вічно)
        public static void KillWithUs(Process p)
        {
            try
            {
                if (job == IntPtr.Zero)
                {
                    var j = CreateJobObject(IntPtr.Zero, null);
                    var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { LimitFlags = 0x2000 }; // KILL_ON_JOB_CLOSE
                    if (!SetInformationJobObject(j, 9, ref info, Marshal.SizeOf(info))) { CloseHandle(j); return; }
                    job = j;
                }
                AssignProcessToJobObject(job, p.Handle);
            }
            catch { }
        }
    }
}
