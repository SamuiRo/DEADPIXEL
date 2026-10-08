using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace CrashDoctor
{
    static class SystemInfo
    {
        public static string Build(TrayApp app)
        {
            var sb = new StringBuilder();
            var tips = new List<string>();
            try
            {
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT Caption,Version FROM Win32_OperatingSystem").Get())
                    sb.AppendLine("ОС:      " + o["Caption"] + " " + o["Version"]);
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT Manufacturer,Product FROM Win32_BaseBoard").Get())
                    sb.AppendLine("Плата:   " + o["Manufacturer"] + " " + o["Product"]);
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT SMBIOSBIOSVersion,ReleaseDate FROM Win32_BIOS").Get())
                {
                    var d = Date(o["ReleaseDate"]);
                    sb.AppendLine("BIOS:    " + o["SMBIOSBIOSVersion"] + " (" + (d == DateTime.MinValue ? "?" : d.ToString("yyyy-MM-dd")) + ")");
                    if (d != DateTime.MinValue && (DateTime.Now - d).TotalDays > 365)
                        tips.Add("BIOS старший за рік. Для AM5 оновлення AGESA часто покращують стабільність PCIe та пам'яті.");
                }

                sb.AppendLine();
                sb.AppendLine("Процесор:");
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed,L2CacheSize,L3CacheSize,SocketDesignation FROM Win32_Processor").Get())
                {
                    sb.AppendLine("  " + o["Name"]);
                    sb.AppendLine(string.Format("  Ядер: {0}, потоків: {1}, базова частота: {2} MHz, L2: {3} KB, L3: {4} KB, сокет: {5}",
                        o["NumberOfCores"], o["NumberOfLogicalProcessors"], o["MaxClockSpeed"], o["L2CacheSize"], o["L3CacheSize"], o["SocketDesignation"]));
                }
                sb.AppendLine("  Температура: " + app.Sampler.CpuTemp.Status);

                sb.AppendLine();
                sb.AppendLine("Пам'ять:");
                double total = 0;
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT BankLabel,DeviceLocator,Capacity,Speed,ConfiguredClockSpeed,Manufacturer,PartNumber FROM Win32_PhysicalMemory").Get())
                {
                    var cap = Convert.ToDouble(o["Capacity"]) / 1073741824.0;
                    total += cap;
                    sb.AppendLine(string.Format("  {0,-10} {1,4:0} GB  {2} MT/s (налаштовано {3})  {4} {5}", o["DeviceLocator"], cap, o["Speed"], o["ConfiguredClockSpeed"],
                        (o["Manufacturer"] ?? "").ToString().Trim(), (o["PartNumber"] ?? "").ToString().Trim()));
                }
                sb.AppendLine(string.Format("  Разом: {0:0} GB", total));

                sb.AppendLine();
                sb.AppendLine("Відеоадаптери:");
                foreach (ManagementObject o in new ManagementObjectSearcher("SELECT Name,DriverVersion,DriverDate,CurrentHorizontalResolution FROM Win32_VideoController").Get())
                {
                    var name = (string)o["Name"];
                    var dd = Date(o["DriverDate"]);
                    int age = dd == DateTime.MinValue ? -1 : (int)(DateTime.Now - dd).TotalDays;
                    bool hasDisplay = o["CurrentHorizontalResolution"] != null;
                    sb.AppendLine(string.Format("  {0,-30} драйвер {1}  від {2:yyyy-MM-dd} ({3} днів){4}", name, o["DriverVersion"], dd, age, hasDisplay ? "" : "  [без монітора]"));
                    if (name.Contains("NVIDIA") && age > 90) tips.Add("Драйвер NVIDIA старий (" + age + " днів). Оновіть до останнього з чистою інсталяцією (краще DDU → інсталятор).");
                    if (!name.Contains("NVIDIA") && !hasDisplay) tips.Add("Вбудована графіка (" + name + ") увімкнена, але без монітора. Для тесту вимкніть iGPU у BIOS — гібридна конфігурація іноді провокує TDR.");
                }

                sb.AppendLine();
                sb.AppendLine("Диски:");
                try
                {
                    var scope = new ManagementScope(@"\\.\root\Microsoft\Windows\Storage");
                    foreach (ManagementObject o in new ManagementObjectSearcher(scope, new ObjectQuery("SELECT FriendlyName,BusType,HealthStatus,Size FROM MSFT_PhysicalDisk")).Get())
                    {
                        var h = Convert.ToInt32(o["HealthStatus"]);
                        sb.AppendLine(string.Format("  {0,-26} {1,6:0} GB  {2}", o["FriendlyName"], Convert.ToDouble(o["Size"]) / 1e9, h == 0 ? "Healthy" : h == 1 ? "WARNING" : "UNHEALTHY"));
                        if (h != 0) tips.Add("Диск " + o["FriendlyName"] + " повідомляє про проблеми зі здоров'ям — зробіть резервну копію.");
                    }
                }
                catch { sb.AppendLine("  (недоступно)"); }
            }
            catch (Exception ex) { sb.AppendLine("WMI: " + ex.Message); }

            sb.AppendLine();
            sb.AppendLine("Живлення та налаштування, що впливають на стабільність:");
            sb.AppendLine("  План живлення: " + PlanName());
            var aspm = PowerCfg("SUB_PCIEXPRESS ASPM");
            sb.AppendLine("  PCIe Link State Power Management: " + (aspm == 0 ? "Вимкнено" : aspm == 1 ? "Помірне енергозбереження" : aspm == 2 ? "Максимальне енергозбереження" : "?"));
            if (aspm > 0) tips.Add("Увімкнено енергозбереження PCIe (ASPM). Краші в простої / при виході з гри часто пов'язані з переходом GPU у режим низького енергоспоживання. Вимкнути (від адміністратора): powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 && powercfg /setactive SCHEME_CURRENT");
            var minState = PowerCfg("SUB_PROCESSOR PROCTHROTTLEMIN");
            var maxState = PowerCfg("SUB_PROCESSOR PROCTHROTTLEMAX");
            sb.AppendLine(string.Format("  Стан процесора мін/макс: {0}% / {1}%", minState, maxState));
            if (maxState >= 0 && maxState < 100) tips.Add("Максимальний стан процесора менше 100% — CPU обмежено планом живлення.");
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\GraphicsDrivers"))
                {
                    var hags = k == null ? null : k.GetValue("HwSchMode");
                    sb.AppendLine("  Апаратне планування GPU (HAGS): " + (hags == null ? "за замовчуванням" : (Convert.ToInt32(hags) == 2 ? "Увімкнено" : "Вимкнено")));
                    var tdr = k == null ? null : k.GetValue("TdrDelay");
                    sb.AppendLine("  TdrDelay: " + (tdr == null ? "за замовчуванням (2 с)" : tdr + " с"));
                }
                using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\Dwm"))
                {
                    var mpo = k == null ? null : k.GetValue("OverlayTestMode");
                    sb.AppendLine("  Multiplane Overlay (MPO): " + (mpo != null && Convert.ToInt32(mpo) == 5 ? "Вимкнено" : "Увімкнено (за замовчуванням)"));
                }
            }
            catch { }

            sb.AppendLine();
            sb.AppendLine("Рекомендації:");
            if (tips.Count == 0) sb.AppendLine("  Особливих зауважень немає.");
            foreach (var t in tips) sb.AppendLine("  • " + t);
            return sb.ToString().Replace("\r\n", "\n").Replace("\n", "\r\n");
        }

        static DateTime Date(object wmi)
        {
            try { return ManagementDateTimeConverter.ToDateTime((string)wmi); } catch { return DateTime.MinValue; }
        }

        static string Run(string args)
        {
            var psi = new ProcessStartInfo("powercfg", args) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
            using (var p = Process.Start(psi)) { var o = p.StandardOutput.ReadToEnd(); p.WaitForExit(3000); return o; }
        }

        static string PlanName()
        {
            try
            {
                var m = Regex.Match(Run("/getactivescheme"), @"\((.+)\)");
                return m.Success ? m.Groups[1].Value : "?";
            }
            catch { return "?"; }
        }

        public static int PowerCfg(string setting)
        {
            try
            {
                // Текст powercfg локалізований, тому без прив'язки до слів: два останні значення 0x… — це AC і DC
                var ms = Regex.Matches(Run("/q SCHEME_CURRENT " + setting), @"0x([0-9a-fA-F]{8})\s*$", RegexOptions.Multiline);
                return ms.Count >= 2 ? Convert.ToInt32(ms[ms.Count - 2].Groups[1].Value, 16) : -1;
            }
            catch { return -1; }
        }
    }
}
