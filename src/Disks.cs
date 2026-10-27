using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace DeadPixel
{
    // ================================================================ модель
    class DiskInfo
    {
        public int Number;
        public string Model = "", Serial = "", Media = "", Bus = "", Letters = "", Health = "";
        public double SizeGb;
        // SMART / лічильники надійності (заповнюються з кешу smart.ini; -1 = невідомо)
        public long Temp = -1, PowerOnHours = -1, Reallocated = -1, Pending = -1, Uncorrectable = -1, Crc = -1,
                    StartStop = -1, LoadCycles = -1, Wear = -1, SpinRetry = -1, ReadLatencyMax = -1;
        public bool IsHdd { get { return Media == "HDD"; } }
        public string Label { get { return L.T("Диск ", "Disk ") + Number + (Letters != "" ? " (" + Letters + ")" : "") ; } }
    }

    class DiskEvent
    {
        public DateTime Time;
        public string Kind;   // reset | retry | error | lostwrite | stall
        public int Disk = -1; // -1 — невідомо
        public string Text = "", Letter = "", Port = "";
        public double Seconds;
        public string LaneKey = "", LaneName = "";
    }

    // ================================================================ детектор зависань
    // Зависання = у черзі диска є запити, але за інтервал не завершилось жодного.
    class StallDetector
    {
        class Counter { public string Instance; public int Disk; public string Letters; public PerformanceCounter Queue, Transfers; public DateTime? Start; }
        readonly List<Counter> counters = new List<Counter>();
        DateTime nextRefresh = DateTime.MinValue, lastSample = DateTime.MinValue;
        FileStream fs;
        string fsDate;
        public event Action<DiskEvent> StallDetected;
        public volatile string Live = ""; // поточне зависання (для UI)
        public const string Header = "start,end,seconds,disk,letters";

        void Refresh()
        {
            nextRefresh = DateTime.Now.AddSeconds(60);
            string[] names;
            try { names = new PerformanceCounterCategory("PhysicalDisk").GetInstanceNames(); } catch { return; }
            var wanted = names.Where(n => n != "_Total" && Regex.IsMatch(n, @"^\d+")).ToList();
            counters.RemoveAll(c => !wanted.Contains(c.Instance));
            foreach (var n in wanted.Where(n => counters.All(c => c.Instance != n)))
            {
                try
                {
                    var c = new Counter
                    {
                        Instance = n, Disk = int.Parse(Regex.Match(n, @"^\d+").Value), Letters = n.Substring(n.IndexOf(' ') + 1).Trim(),
                        Queue = new PerformanceCounter("PhysicalDisk", "Current Disk Queue Length", n),
                        Transfers = new PerformanceCounter("PhysicalDisk", "Disk Transfers/sec", n)
                    };
                    c.Transfers.NextValue();
                    counters.Add(c);
                }
                catch { }
            }
        }

        public void Sample(DateTime now)
        {
            if (now >= nextRefresh) Refresh();
            var live = new List<string>();
            foreach (var c in counters)
            {
                float q, tps;
                try { q = c.Queue.NextValue(); tps = c.Transfers.NextValue(); } catch { continue; }
                bool stuck = q >= 1 && tps < 0.5f;
                if (stuck)
                {
                    if (!c.Start.HasValue) c.Start = lastSample == DateTime.MinValue ? now : lastSample;
                    live.Add(string.Format(L.T("Диск {0} ({1}) не відповідає {2:0} с", "Disk {0} ({1}) not responding for {2:0} s"), c.Disk, c.Letters, (now - c.Start.Value).TotalSeconds));
                }
                else if (c.Start.HasValue)
                {
                    var secs = (now - c.Start.Value).TotalSeconds;
                    if (secs >= 4)
                    {
                        var ev = new DiskEvent { Time = c.Start.Value, Kind = "stall", Disk = c.Disk, Letter = c.Letters, Seconds = secs,
                            Text = string.Format(L.T("Диск {0} ({1}) не відповідав {2:0} с — запити стояли в черзі без жодної завершеної операції", "Disk {0} ({1}) did not respond for {2:0} s — requests were queued with no operation completing"), c.Disk, c.Letters, secs) };
                        Write(ev, now);
                        var h = StallDetected;
                        if (h != null) h(ev);
                    }
                    c.Start = null;
                }
            }
            Live = string.Join("; ", live);
            lastSample = now;
        }

        void Write(DiskEvent e, DateTime end)
        {
            try
            {
                var date = e.Time.ToString("yyyy-MM-dd");
                if (fs == null || fsDate != date)
                {
                    if (fs != null) fs.Dispose();
                    var path = Path.Combine(Program.DataDir, "disk-stalls-" + date + ".csv");
                    bool isNew = !File.Exists(path);
                    fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite, 4096, FileOptions.WriteThrough);
                    fsDate = date;
                    if (isNew) { var hb = Encoding.UTF8.GetBytes(Header + "\r\n"); fs.Write(hb, 0, hb.Length); }
                }
                var b = Encoding.UTF8.GetBytes(string.Format(CultureInfo.InvariantCulture, "{0:yyyy-MM-dd HH:mm:ss},{1:yyyy-MM-dd HH:mm:ss},{2:0},{3},{4}\r\n", e.Time, end, e.Seconds, e.Disk, e.Letter));
                fs.Write(b, 0, b.Length);
                fs.Flush(true);
            }
            catch { }
        }

        public static List<DiskEvent> ReadStalls(DateTime from, DateTime to)
        {
            var res = new List<DiskEvent>();
            foreach (var l in Sampler.ReadRange(new[] { "disk-stalls-" }, from, to))
            {
                var c = l.Split(',');
                if (c.Length < 5) continue;
                DateTime t; double secs; int disk;
                Sampler.TryTime(l, out t);
                double.TryParse(c[2], NumberStyles.Float, CultureInfo.InvariantCulture, out secs);
                int.TryParse(c[3], out disk);
                res.Add(new DiskEvent { Time = t, Kind = "stall", Disk = disk, Letter = c[4], Seconds = secs,
                    Text = string.Format(L.T("не відповідав {0:0} с (виявлено DEADPIXEL)", "did not respond for {0:0} s (detected by DEADPIXEL)"), secs) });
            }
            return res;
        }
    }

    // ================================================================ інвентар, SMART, події
    static class DiskMonitor
    {
        public static string SmartPath { get { return Path.Combine(Program.DataDir, "smart.ini"); } }

        public static List<DiskInfo> Inventory()
        {
            var list = new List<DiskInfo>();
            try
            {
                var scope = new ManagementScope(@"\\.\root\Microsoft\Windows\Storage");
                foreach (ManagementObject o in new ManagementObjectSearcher(scope, new ObjectQuery("SELECT DeviceId,FriendlyName,SerialNumber,MediaType,BusType,HealthStatus,Size FROM MSFT_PhysicalDisk")).Get())
                {
                    int n;
                    if (!int.TryParse(Convert.ToString(o["DeviceId"]), out n)) continue;
                    var media = Convert.ToInt32(o["MediaType"]);
                    var bus = Convert.ToInt32(o["BusType"]);
                    var h = Convert.ToInt32(o["HealthStatus"]);
                    list.Add(new DiskInfo
                    {
                        Number = n, Model = Convert.ToString(o["FriendlyName"]).Trim(), Serial = (Convert.ToString(o["SerialNumber"]) ?? "").Trim().TrimEnd('.'),
                        Media = media == 3 ? "HDD" : media == 4 ? "SSD" : media == 5 ? "SCM" : "?",
                        Bus = bus == 11 ? "SATA" : bus == 17 ? "NVMe" : bus == 7 ? "USB" : bus == 8 ? "RAID" : bus == 10 ? "SAS" : bus.ToString(),
                        Health = h == 0 ? "Healthy" : h == 1 ? "Warning" : h == 2 ? "Unhealthy" : "?",
                        SizeGb = Convert.ToDouble(o["Size"]) / 1e9
                    });
                }
                foreach (ManagementObject o in new ManagementObjectSearcher(scope, new ObjectQuery("SELECT DiskNumber,DriveLetter FROM MSFT_Partition")).Get())
                {
                    var letter = Convert.ToChar(Convert.ToUInt16(o["DriveLetter"]));
                    if (letter == '\0') continue;
                    var d = list.FirstOrDefault(x => x.Number == Convert.ToInt32(o["DiskNumber"]));
                    if (d != null) d.Letters = (d.Letters == "" ? "" : d.Letters + " ") + letter + ":";
                }
            }
            catch { }
            ApplySmartCache(list);
            return list.OrderBy(d => d.Number).ToList();
        }

        public static DateTime SmartTime { get { return File.Exists(SmartPath) ? File.GetLastWriteTime(SmartPath) : DateTime.MinValue; } }

        static void ApplySmartCache(List<DiskInfo> list)
        {
            if (!File.Exists(SmartPath)) return;
            DiskInfo cur = null;
            foreach (var line in File.ReadAllLines(SmartPath))
            {
                var m = Regex.Match(line, @"^\[serial=(.*)\]$");
                if (m.Success) { cur = list.FirstOrDefault(d => d.Serial == m.Groups[1].Value); continue; }
                if (cur == null) continue;
                int i = line.IndexOf('=');
                if (i < 1) continue;
                long v;
                if (!long.TryParse(line.Substring(i + 1), out v)) continue;
                var f = typeof(DiskInfo).GetField(line.Substring(0, i));
                if (f != null && f.FieldType == typeof(long)) f.SetValue(cur, v);
            }
        }

        // Виконується в окремому процесі з правами адміністратора (--smart)
        public static void WriteSmartCache()
        {
            var sb = new StringBuilder();
            var pnpByIndex = new Dictionary<int, string>();
            try
            {
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT Index,PNPDeviceID FROM Win32_DiskDrive").Get())
                    pnpByIndex[Convert.ToInt32(o["Index"])] = Convert.ToString(o["PNPDeviceID"]).ToUpperInvariant();
            }
            catch { }
            var attrs = new Dictionary<string, Dictionary<int, long>>(); // PNP id → SMART raw
            try
            {
                foreach (ManagementObject o in new ManagementObjectSearcher(@"root\wmi", "SELECT InstanceName,VendorSpecific FROM MSStorageDriver_FailurePredictData").Get())
                {
                    var key = Regex.Replace(Convert.ToString(o["InstanceName"]).ToUpperInvariant(), @"_\d+$", "");
                    var v = (byte[])o["VendorSpecific"];
                    var d = new Dictionary<int, long>();
                    for (int i = 2; i + 11 < v.Length; i += 12)
                    {
                        if (v[i] == 0 || d.ContainsKey(v[i])) continue;
                        long raw = 0;
                        for (int b = 0; b < 6; b++) raw |= (long)v[i + 5 + b] << (8 * b);
                        d[v[i]] = raw;
                    }
                    attrs[key] = d;
                }
            }
            catch { }
            try
            {
                var scope = new ManagementScope(@"\\.\root\Microsoft\Windows\Storage");
                foreach (ManagementObject pd in new ManagementObjectSearcher(scope, new ObjectQuery("SELECT * FROM MSFT_PhysicalDisk")).Get())
                {
                    int n;
                    if (!int.TryParse(Convert.ToString(pd["DeviceId"]), out n)) continue;
                    sb.AppendLine("[serial=" + (Convert.ToString(pd["SerialNumber"]) ?? "").Trim().TrimEnd('.') + "]");
                    try
                    {
                        foreach (ManagementObject rc in pd.GetRelated("MSFT_StorageReliabilityCounter"))
                        {
                            W(sb, "Temp", rc["Temperature"]);
                            W(sb, "PowerOnHours", rc["PowerOnHours"]);
                            W(sb, "StartStop", rc["StartStopCycleCount"]);
                            W(sb, "LoadCycles", rc["LoadUnloadCycleCount"]);
                            W(sb, "Wear", rc["Wear"]);
                            W(sb, "ReadLatencyMax", rc["ReadLatencyMax"]);
                        }
                    }
                    catch { }
                    string pnp;
                    Dictionary<int, long> a;
                    if (pnpByIndex.TryGetValue(n, out pnp) && attrs.TryGetValue(pnp, out a))
                    {
                        // атрибути SMART точніші (лічильник LoadUnload у Windows 16-бітний і переповнюється)
                        foreach (var kv in new Dictionary<int, string> { { 5, "Reallocated" }, { 197, "Pending" }, { 198, "Uncorrectable" }, { 199, "Crc" }, { 4, "StartStop" }, { 193, "LoadCycles" }, { 9, "PowerOnHours" }, { 10, "SpinRetry" } })
                            if (a.ContainsKey(kv.Key)) sb.AppendLine(kv.Value + "=" + a[kv.Key]);
                        if (a.ContainsKey(194)) sb.AppendLine("Temp=" + (a[194] & 0xFF));
                    }
                }
            }
            catch (Exception ex) { sb.AppendLine("; error " + ex.Message); }
            File.WriteAllText(SmartPath, sb.ToString());
        }

        static void W(StringBuilder sb, string key, object v)
        {
            if (v == null) return;
            try { sb.AppendLine(key + "=" + Convert.ToInt64(v)); } catch { }
        }

        public static string RefreshSmartElevated()
        {
            try
            {
                using (var p = Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--smart") { UseShellExecute = true, Verb = "runas" }))
                    p.WaitForExit(60000);
                return null;
            }
            catch (Exception ex) { return ex.Message; }
        }

        // Події дисків із журналу System (через службові поля — не залежить від мови Windows)
        public static List<DiskEvent> LoadEvents(int days, List<DiskInfo> disks)
        {
            var res = new List<DiskEvent>();
            var xp = "*[System[Provider[@Name='storahci' or @Name='stornvme' or @Name='disk' or @Name='Ntfs'] and (EventID=129 or EventID=153 or EventID=154 or EventID=7 or EventID=11 or EventID=51 or EventID=50 or EventID=55 or EventID=98 or EventID=140)"
                   + " and TimeCreated[timediff(@SystemTime) <= " + ((long)days * 86400000L) + "]]]";
            try
            {
                using (var r = new EventLogReader(new EventLogQuery("System", PathType.LogName, xp) { ReverseDirection = true }))
                {
                    EventRecord rec;
                    int n = 0;
                    while (n++ < 5000 && (rec = r.ReadEvent()) != null)
                        using (rec)
                        {
                            var e = new DiskEvent { Time = rec.TimeCreated ?? DateTime.MinValue };
                            var props = rec.Properties.Select(p => p.Value as string ?? "").ToArray();
                            var prov = rec.ProviderName;
                            if (prov == "storahci" || prov == "stornvme")
                            {
                                e.Kind = "reset";
                                var pm = Regex.Match(props.Length > 0 ? props[0] : "", @"RaidPort(\d+)");
                                e.Port = pm.Success ? "RaidPort" + pm.Groups[1].Value : prov;
                                e.Text = L.T("Скидання диска контролером (", "Disk reset by the controller (") + e.Port + ")";
                            }
                            else if (prov == "disk")
                            {
                                e.Kind = rec.Id == 153 ? "retry" : "error";
                                var m = Regex.Match(props.Length > 0 ? props[0] : "", @"Harddisk(\d+)");
                                if (m.Success) e.Disk = int.Parse(m.Groups[1].Value);
                                e.Text = rec.Id == 153 ? L.T("Операцію повторено (диск не відповів вчасно)", "Operation retried (the disk did not respond in time)") : rec.Id == 51 ? L.T("Помилка під час підкачки сторінок", "Error during paging") :
                                         rec.Id == 7 ? L.T("Пошкоджений блок", "Bad block") : rec.Id == 11 ? L.T("Помилка контролера", "Controller error") : L.T("Апаратна помилка вводу-виводу", "Hardware I/O error");
                            }
                            else
                            {
                                e.Kind = rec.Id == 50 || rec.Id == 140 ? "lostwrite" : "error";
                                var path = props.FirstOrDefault(p => Regex.IsMatch(p, @"^[A-Za-z]:")) ?? "";
                                e.Letter = path.Length >= 2 ? path.Substring(0, 2).ToUpperInvariant() : "";
                                e.Text = (rec.Id == 50 || rec.Id == 140 ? L.T("Не вдалося записати дані (втрата запису): ", "Data could not be written (lost write): ") : rec.Id == 98 ? L.T("Том потребує перевірки (chkdsk): ", "The volume needs checking (chkdsk): ") : L.T("Пошкодження файлової системи: ", "File system corruption: ")) + path;
                                var d = disks.FirstOrDefault(x => e.Letter != "" && x.Letters.Contains(e.Letter));
                                if (d != null) e.Disk = d.Number;
                            }
                            res.Add(e);
                        }
                }
            }
            catch { }
            // Скидання контролера не містить номера диска — беремо з повтору в ту саму секунду
            foreach (var e in res.Where(x => x.Kind == "reset"))
            {
                var near = res.FirstOrDefault(x => x.Kind == "retry" && x.Disk >= 0 && Math.Abs((x.Time - e.Time).TotalSeconds) <= 3);
                if (near != null) e.Disk = near.Disk;
            }
            foreach (var e in res.Where(x => x.Letter == "" && x.Disk >= 0))
            {
                var d = disks.FirstOrDefault(x => x.Number == e.Disk);
                if (d != null) e.Letter = d.Letters;
            }
            AssignLanes(res, disks);
            return res.OrderBy(e => e.Time).ToList();
        }

        // Рядок графіка для кожної події: диск; або контролер (якщо скидання без номера диска); або літера відсутнього тому
        public static void AssignLanes(List<DiskEvent> events, List<DiskInfo> disks)
        {
            var portDisks = events.Where(e => e.Kind == "reset" && e.Disk >= 0).GroupBy(e => e.Port)
                                  .ToDictionary(g => g.Key, g => g.Select(e => e.Disk).Distinct().OrderBy(n => n).ToList());
            foreach (var e in events)
            {
                if (e.Disk >= 0)
                {
                    var d = disks.FirstOrDefault(x => x.Number == e.Disk);
                    e.LaneKey = "d" + e.Disk;
                    e.LaneName = d != null ? d.Label + " " + d.Media : string.Format(L.T("Диск {0} (відсутній)", "Disk {0} (absent)"), e.Disk);
                }
                else if (e.Kind == "reset")
                {
                    List<int> nums;
                    e.LaneKey = "p" + e.Port;
                    e.LaneName = e.Port + (portDisks.TryGetValue(e.Port, out nums) ? L.T(" → диски ", " → disks ") + string.Join(", ", nums) : "");
                }
                else if (e.Letter != "") { e.LaneKey = "l" + e.Letter; e.LaneName = e.Letter + L.T(" (відсутній)", " (absent)"); }
                else { e.LaneKey = "x"; e.LaneName = L.T("Невідомий диск", "Unknown disk"); }
            }
        }

        public static string Summary(List<DiskInfo> disks, List<DiskEvent> events, int days)
        {
            var sb = new StringBuilder();
            var now = DateTime.Now;
            sb.AppendLine(string.Format(L.T("Зведення за {0} дн.:", "Summary for {0} days:"), days));
            foreach (var d in disks)
            {
                var ev = events.Where(e => e.Disk == d.Number).ToList();
                var stalls = ev.Where(e => e.Kind == "stall").ToList();
                sb.AppendLine(string.Format(L.T("  {0,-22} скидань: {1,3} (24 год: {2}) · повторів: {3,3} · зависань: {4,3}{5} · помилок: {6} · втрат запису: {7}", "  {0,-22} resets: {1,3} (24 h: {2}) · retries: {3,3} · stalls: {4,3}{5} · errors: {6} · lost writes: {7}"),
                    d.Label, ev.Count(e => e.Kind == "reset"), ev.Count(e => e.Kind == "reset" && e.Time > now.AddDays(-1)), ev.Count(e => e.Kind == "retry"),
                    stalls.Count, stalls.Count > 0 ? string.Format(L.T(" (найдовше {0:0} с)", " (longest {0:0} s)"), stalls.Max(s => s.Seconds)) : "",
                    ev.Count(e => e.Kind == "error"), ev.Count(e => e.Kind == "lostwrite")));
            }
            var ports = events.Where(e => e.Kind == "reset" && e.Disk < 0).GroupBy(e => e.LaneName).ToList();
            foreach (var g in ports)
                sb.AppendLine(string.Format(L.T("  {0,-22} скидань без визначеного диска: {1} (Windows не записала, якого саме)", "  {0,-22} resets without an identified disk: {1} (Windows did not record which one)"), g.Key, g.Count()));
            var orphan = events.Where(e => e.Kind != "reset" && (e.Disk < 0 || disks.All(d => d.Number != e.Disk))).ToList();
            if (orphan.Count > 0)
            {
                sb.AppendLine(L.T("  Диски, яких зараз немає в системі (зовнішні/USB):", "  Disks not currently present (external/USB):"));
                foreach (var g in orphan.GroupBy(e => e.LaneName))
                    sb.AppendLine(string.Format(L.T("    {0,-22} подій: {1} (останнє {2:yyyy-MM-dd HH:mm})", "    {0,-22} events: {1} (last {2:yyyy-MM-dd HH:mm})"), g.Key, g.Count(), g.Max(e => e.Time)));
            }
            var lost = events.Where(e => e.Kind == "lostwrite").ToList();
            if (lost.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine(L.T("УВАГА — втрачені записи (файли могли пошкодитися):", "WARNING — lost writes (files may be damaged):"));
                foreach (var g in lost.GroupBy(e => e.Text).Take(15)) sb.AppendLine(string.Format("  {0:yyyy-MM-dd HH:mm}  {1}", g.Max(e => e.Time), g.Key));
            }

            sb.AppendLine();
            sb.AppendLine(L.T("Налаштування живлення дисків:", "Disk power settings:"));
            var idle = SystemInfo.PowerCfg("SUB_DISK DISKIDLE");
            var lpm = SystemInfo.PowerCfg("SUB_DISK 0b2d69d7-a2a1-449c-9680-f91c70521c60");
            sb.AppendLine(L.T("  Зупинка HDD при простої: ", "  HDD idle spin-down: ") + (idle < 0 ? "?" : idle == 0 ? L.T("ніколи", "never") : (idle / 60) + L.T(" хв", " min")));
            sb.AppendLine(L.T("  Енергозбереження з'єднання SATA (AHCI LPM): ", "  SATA link power management (AHCI LPM): ") + (lpm < 0 ? L.T("за замовчуванням (налаштування приховане)", "default (setting hidden)") : lpm == 0 ? L.T("вимкнено (Active)", "off (Active)") : lpm == 1 ? "HIPM" : lpm == 2 ? "HIPM+DIPM" : lpm == 3 ? "DIPM" : L.T("найнижче споживання", "lowest power")));

            var tips = new List<string>();
            int resets = events.Count(e => e.Kind == "reset");
            var hddResets = disks.Where(d => d.IsHdd && events.Any(e => e.Kind == "reset" && e.Disk == d.Number)).ToList();
            if (resets > 0 && lpm != 0) tips.Add(L.T("Є скидання дисків, а енергозбереження SATA не вимкнене — вимкніть AHCI LPM (рецепт «Диски без енергозбереження» у Сетапі ПК).", "There are disk resets while SATA power saving is on — disable AHCI LPM (the «Disks without power saving» recipe in PC setup)."));
            if (resets > 0 && idle > 0 && hddResets.Count > 0) tips.Add(string.Format(L.T("HDD засинають через {0} хв — пробудження може не встигати за тайм-аутом. Збільште час або вимкніть зупинку.", "HDDs spin down after {0} min — waking up may not beat the timeout. Increase the time or disable spin-down."), idle / 60));
            if (hddResets.Count >= 2) tips.Add(L.T("Скидання на кількох HDD одночасно → імовірна спільна причина: контролер, драйвер, живлення (спільний кабель SATA). Спробуйте інший порт/контролер і окремі кабелі живлення.", "Resets on several HDDs at once → likely a common cause: controller, driver or power (shared SATA power cable). Try another port/controller and separate power cables."));
            foreach (var d in disks)
            {
                if (d.Reallocated > 0 || d.Pending > 0 || d.Uncorrectable > 0) tips.Add(d.Label + L.T(": є пошкоджені/нестабільні сектори — зробіть резервну копію, диск деградує.", ": has bad/unstable sectors — make a backup, the disk is degrading."));
                if (d.Crc > 0) tips.Add(d.Label + string.Format(L.T(": помилки передачі по кабелю SATA (CRC = {0}) — замініть кабель даних SATA.", ": SATA cable transfer errors (CRC = {0}) — replace the SATA data cable."), d.Crc));
                if (d.IsHdd && d.LoadCycles > 250000) tips.Add(d.Label + ": " + d.LoadCycles.ToString("N0") + L.T(" паркувань головок — близько до ресурсу (~300 000 для настільних дисків).", " head load cycles — close to the rated limit (~300,000 for desktop drives)."));
                if (d.IsHdd && d.Temp > 50) tips.Add(d.Label + L.T(": висока температура ", ": high temperature ") + d.Temp + " °C.");
                if (d.Wear > 80) tips.Add(d.Label + L.T(": знос SSD ", ": SSD wear ") + d.Wear + "%.");
                if (d.Health != "Healthy" && d.Health != "?") tips.Add(d.Label + string.Format(L.T(": Windows повідомляє стан «{0}».", ": Windows reports health \"{0}\"."), d.Health));
            }
            if (SmartTime == DateTime.MinValue) tips.Add(L.T("SMART ще не зчитано — натисніть «Оновити SMART».", "SMART has not been read yet — click \"Refresh SMART\"."));
            sb.AppendLine();
            sb.AppendLine(L.T("Рекомендації:", "Recommendations:"));
            if (tips.Count == 0) sb.AppendLine(L.T("  Проблем не виявлено.", "  No problems found."));
            foreach (var t in tips) sb.AppendLine("  • " + t);
            return sb.ToString().Replace("\r\n", "\n").Replace("\n", "\r\n");
        }
    }

    // ================================================================ графік зависань
    class DiskChart : Control
    {
        readonly Func<Theme> theme;
        List<DiskInfo> disks = new List<DiskInfo>();
        List<DiskEvent> events = new List<DiskEvent>();
        int days = 7, mouseX = -1, mouseY = -1;
        Font small;

        public DiskChart(Func<Theme> theme)
        {
            this.theme = theme;
            DoubleBuffered = true;
            SetStyle(ControlStyles.ResizeRedraw | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            MouseMove += (s, e) => { mouseX = e.X; mouseY = e.Y; Invalidate(); };
            MouseLeave += (s, e) => { mouseX = -1; Invalidate(); };
        }

        public void SetData(List<DiskInfo> d, List<DiskEvent> e, int days) { disks = d; events = e; this.days = days; Invalidate(); }

        static Color KindColor(string k, Theme t)
        {
            switch (k)
            {
                case "reset": return t.Danger;
                case "retry": return Color.FromArgb(234, 140, 30);
                case "stall": return Color.FromArgb(168, 85, 247);
                case "lostwrite": return Color.FromArgb(220, 38, 127);
                default: return Color.FromArgb(150, 40, 40);
            }
        }

        List<Tuple<string, string>> Lanes()
        {
            var lanes = disks.Select(d => Tuple.Create(d.Label + " " + d.Media, "d" + d.Number)).ToList();
            foreach (var e in events.Where(e => e.LaneKey != "").GroupBy(e => e.LaneKey).Select(g => g.First()))
                if (lanes.All(l => l.Item2 != e.LaneKey)) lanes.Add(Tuple.Create(e.LaneName, e.LaneKey));
            return lanes;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = theme();
            var g = e.Graphics;
            g.Clear(t.Surface);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (small == null) small = new Font(Font.FontFamily, 7.5f);
            var to = DateTime.Now;
            var from = to.AddDays(-days);
            var lanes = Lanes();
            const int labelW = 170, histH = 46;
            var area = new Rectangle(labelW, 28, Width - labelW - 12, Math.Max(20, Height - 28 - histH - 24));
            int laneH = lanes.Count == 0 ? area.Height : Math.Max(14, area.Height / lanes.Count);
            Func<DateTime, float> X = d => area.Left + (float)((d - from).TotalSeconds / (to - from).TotalSeconds) * area.Width;

            // легенда
            float lx = 12;
            foreach (var k in new[] { "reset", "retry", "stall", "error", "lostwrite" })
            {
                var name = k == "reset" ? L.T("● скидання", "● reset") : k == "retry" ? L.T("● повтор", "● retry") : k == "stall" ? L.T("▬ зависання (тривалість)", "▬ stall (duration)") : k == "error" ? L.T("● помилка", "● error") : L.T("● втрата запису", "● lost write");
                TextRenderer.DrawText(g, name, small, new Point((int)lx, 6), KindColor(k, t));
                lx += TextRenderer.MeasureText(name, small).Width + 10;
            }

            using (var grid = new Pen(t.Grid))
            {
                // вертикальні лінії: дні (або години для 1 доби)
                var step = days <= 1 ? TimeSpan.FromHours(3) : TimeSpan.FromDays(days > 14 ? 5 : 1);
                var tick = days <= 1 ? from.Date.AddHours(Math.Ceiling(from.TimeOfDay.TotalHours / 3) * 3) : from.Date.AddDays(1);
                for (; tick < to; tick += step)
                {
                    float x = X(tick);
                    g.DrawLine(grid, x, area.Top, x, area.Bottom + histH + 4);
                    var lbl = days <= 1 ? tick.ToString("HH:mm") : tick.ToString("dd.MM");
                    TextRenderer.DrawText(g, lbl, small, new Point((int)x + 2, area.Bottom + histH + 6), t.Muted);
                }
                for (int i = 0; i < lanes.Count; i++)
                {
                    int y = area.Top + i * laneH;
                    g.DrawLine(grid, area.Left, y + laneH, area.Right, y + laneH);
                    TextRenderer.DrawText(g, lanes[i].Item1, small, new Rectangle(8, y, labelW - 12, laneH), t.Fg, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                }
            }

            var visible = events.Where(ev => ev.Time >= from).ToList();
            foreach (var ev in visible)
            {
                int li = lanes.FindIndex(l => l.Item2 == ev.LaneKey);
                if (li < 0) continue;
                float x = X(ev.Time), cy = area.Top + li * laneH + laneH / 2f;
                using (var b = new SolidBrush(Color.FromArgb(200, KindColor(ev.Kind, t))))
                {
                    if (ev.Kind == "stall")
                    {
                        float w = Math.Max(3, (float)(ev.Seconds / (to - from).TotalSeconds * area.Width));
                        g.FillRectangle(b, x, cy - 4, w, 8);
                    }
                    else
                    {
                        float r = ev.Kind == "reset" ? 4.5f : 3f;
                        float dy = ev.Kind == "retry" ? -5 : ev.Kind == "reset" ? 0 : 5;
                        g.FillEllipse(b, x - r, cy + dy - r, r * 2, r * 2);
                    }
                }
            }

            // гістограма проблем за днями/годинами
            var hist = new Rectangle(area.Left, area.Bottom + 4, area.Width, histH);
            var bucket = days <= 1 ? TimeSpan.FromHours(1) : TimeSpan.FromDays(1);
            var groups = visible.Where(ev => ev.Kind == "reset" || ev.Kind == "stall" || ev.Kind == "error")
                                .GroupBy(ev => new DateTime(ev.Time.Ticks / bucket.Ticks * bucket.Ticks)).ToList();
            int max = groups.Count == 0 ? 1 : groups.Max(gr => gr.Count());
            using (var b = new SolidBrush(Color.FromArgb(160, t.Danger)))
                foreach (var gr in groups)
                {
                    float x1 = X(gr.Key), x2 = X(gr.Key + bucket);
                    float h = gr.Count() / (float)max * (histH - 12);
                    g.FillRectangle(b, x1 + 1, hist.Bottom - h, Math.Max(2, x2 - x1 - 2), h);
                }
            TextRenderer.DrawText(g, (days <= 1 ? L.T("проблем за годину", "problems per hour") : L.T("проблем за день", "problems per day")) + L.T(" (макс ", " (max ") + max + ")", small, new Point(8, hist.Top + 4), t.Muted);

            if (lanes.Count == 0 || visible.Count == 0)
                TextRenderer.DrawText(g, L.T("За обраний період проблем із дисками не зафіксовано.", "No disk problems recorded in the selected period."), Font, area, t.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);

            // підказка
            if (mouseX >= area.Left && mouseX <= area.Right && mouseY >= area.Top && mouseY <= hist.Bottom)
            {
                var time = from.AddSeconds((mouseX - area.Left) / (double)area.Width * (to - from).TotalSeconds);
                var tol = TimeSpan.FromSeconds((to - from).TotalSeconds / area.Width * 4);
                var near = visible.Where(ev => Math.Abs((ev.Time - time).TotalSeconds) <= tol.TotalSeconds).OrderBy(ev => ev.Time).Take(8).ToList();
                using (var pen = new Pen(t.Muted) { DashStyle = DashStyle.Dot }) g.DrawLine(pen, mouseX, area.Top, mouseX, hist.Bottom);
                var lines = new List<string> { time.ToString("yyyy-MM-dd HH:mm") };
                lines.AddRange(near.Select(ev => string.Format("{0:HH:mm:ss} {1}: {2}", ev.Time, ev.Disk >= 0 ? L.T("Диск ", "Disk ") + ev.Disk : ev.Letter, ev.Text.Length > 80 ? ev.Text.Substring(0, 80) + "…" : ev.Text)));
                var text = string.Join("\n", lines);
                var sz = TextRenderer.MeasureText(text, small);
                int bx = mouseX + 12 + sz.Width + 12 > Width ? mouseX - sz.Width - 20 : mouseX + 12;
                var box = new Rectangle(bx, area.Top + 4, sz.Width + 10, sz.Height + 8);
                using (var b = new SolidBrush(t.Bg)) g.FillRectangle(b, box);
                using (var p = new Pen(t.Border)) g.DrawRectangle(p, box);
                TextRenderer.DrawText(g, text, small, new Point(box.X + 5, box.Y + 4), t.Fg);
            }
        }
    }
}
