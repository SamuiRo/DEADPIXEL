using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadPixel
{
    // Видалення DEADPIXEL. Встановлена версія має деінсталятор Inno Setup (unins000.exe поруч з exe).
    // Portable-версія — одна папка, але сліди лишаються і поза нею: автозапуск, ярлики, завдання Планувальника,
    // резервна папка даних у %LOCALAPPDATA%. RemoveTraces прибирає їх; чужу копію DEADPIXEL (з іншої папки) не чіпає.
    static class Uninstaller
    {
        const string TaskFolder = "DEADPIXEL";
        const string TaskName = "DEADPIXEL Audit";

        static string InnoUninstaller { get { return Path.Combine(Program.BaseDir, "unins000.exe"); } }
        public static bool IsInstalled { get { return File.Exists(InnoUninstaller); } }
        static string LocalData { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeadPixel"); } }

        // Запис стосується цієї копії програми, якщо згадує її папку
        static bool Ours(object value)
        {
            var s = value as string;
            return s != null && s.IndexOf(Program.BaseDir.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) >= 0;
        }

        // Прибирає сліди поза папкою програми. Повертає те, що прибрати не вдалося (порожній список — усе чисто).
        public static List<string> RemoveTraces(bool allowElevation)
        {
            var failed = new List<string>();
            foreach (var pair in new[] { new[] { @"Software\Microsoft\Windows\CurrentVersion\Run", "DeadPixel" },
                                         new[] { @"Software\Microsoft\Windows\CurrentVersion\RunOnce", "DeadPixelSetup" } })
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(pair[0], true))
                        if (k != null && Ours(k.GetValue(pair[1]))) k.DeleteValue(pair[1], false);
                }
                catch (Exception ex) { failed.Add(@"HKCU\" + pair[0] + @"\" + pair[1] + ": " + ex.Message); }

            foreach (var lnk in new[] { Shortcuts.Desktop, Shortcuts.StartMenu })
                try { if (Shortcuts.Exists(lnk)) File.Delete(lnk); }
                catch (Exception ex) { failed.Add(lnk + ": " + ex.Message); }

            var task = RemoveTask(allowElevation);
            if (task != null) failed.Add(task);
            return failed;
        }

        // Розклад аудиту: завдання \DEADPIXEL\DEADPIXEL Audit і сама папка \DEADPIXEL (schtasks папок не видаляє)
        static string RemoveTask(bool allowElevation)
        {
            object svc = null;
            try
            {
                svc = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service"));
                Call(svc, "Connect");
                object folder;
                try { folder = Call(svc, "GetFolder", "\\" + TaskFolder); }
                catch { return null; } // папки немає — розклад не вмикали
                object task = null;
                try { task = Call(folder, "GetTask", TaskName); } catch { }
                if (task != null)
                {
                    bool ours = true; // не вдалося прочитати дію — завдання з нашим іменем усе одно наше
                    try
                    {
                        var actions = Get(Get(task, "Definition"), "Actions");
                        if ((int)Get(actions, "Count") > 0) ours = Ours(Get(GetItem(actions, 1), "Path"));
                    }
                    catch { }
                    if (!ours) return null; // розклад іншої копії DEADPIXEL
                    try { Call(folder, "DeleteTask", TaskName, 0); }
                    catch
                    {
                        // Завдання від ранніх збірок створене з правами адміністратора — видалити можна лише з ними
                        if (!allowElevation || !DeleteTaskElevated())
                            return L.T("завдання Планувальника «\\DEADPIXEL\\DEADPIXEL Audit» (потрібні права адміністратора)",
                                       "the scheduled task \"\\DEADPIXEL\\DEADPIXEL Audit\" (needs administrator rights)");
                    }
                }
                try { Call(Call(svc, "GetFolder", "\\"), "DeleteFolder", TaskFolder, 0); } catch { } // не порожня або немає прав — лишаємо
                return null;
            }
            catch (Exception ex) { return L.T("Планувальник завдань: ", "Task Scheduler: ") + (ex.InnerException ?? ex).Message; }
            finally { if (svc != null) try { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(svc); } catch { } }
        }

        static bool DeleteTaskElevated()
        {
            try
            {
                var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Delete /TN \"\\" + TaskFolder + "\\" + TaskName + "\" /F")
                    { Verb = "runas", UseShellExecute = true, WindowStyle = ProcessWindowStyle.Hidden };
                using (var p = Process.Start(psi)) { p.WaitForExit(30000); return p.HasExited && p.ExitCode == 0; }
            }
            catch { return false; } // користувач відхилив UAC
        }

        static bool HasFiles(string dir)
        {
            try { return Directory.Exists(dir) && Directory.GetFileSystemEntries(dir).Length > 0; } catch { return false; }
        }

        // Кнопка «Видалити DEADPIXEL…» у налаштуваннях
        public static void Run(TrayApp app, IWin32Window owner)
        {
            if (IsInstalled)
            {
                // Деінсталятор сам перепитає, прибере файли, автозапуск, ярлики й розклад
                if (MessageBox.Show(owner, L.T("Запустити деінсталятор DEADPIXEL? Програма закриється.", "Start the DEADPIXEL uninstaller? The program will close."),
                                    "DEADPIXEL", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
                try { Process.Start(InnoUninstaller); }
                catch (Exception ex) { MessageBox.Show(owner, ex.Message, "DEADPIXEL"); return; }
                app.ExitThread();
                return;
            }

            var q = L.T("Це portable-версія: програма живе в одній папці, а поза нею лишає тільки дрібні сліди.\n\nЗараз буде прибрано:\n• автозапуск разом із Windows;\n• ярлики на робочому столі та в меню «Пуск»;\n• розклад аудиту в Планувальнику завдань.\n\nПісля цього DEADPIXEL закриється, і папку програми можна буде видалити.\n\nЗміни, які ви внесли рецептами «Сетапу ПК», лишаються в системі. Якщо хочете їх відкотити — зробіть це до видалення.\n\nПродовжити?",
                        "This is the portable version: the program lives in one folder and leaves only small traces outside it.\n\nThis will remove:\n• start with Windows;\n• the desktop and Start menu shortcuts;\n• the audit schedule in Task Scheduler.\n\nDEADPIXEL will then close and the program folder can be deleted.\n\nChanges you made with \"PC setup\" recipes stay in the system. If you want to revert them, do it before uninstalling.\n\nContinue?");
            if (MessageBox.Show(owner, q, L.T("Видалити DEADPIXEL", "Remove DEADPIXEL"), MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;

            var dataDirs = new[] { Path.Combine(Program.BaseDir, "data"), Path.Combine(Program.BaseDir, "reports"), LocalData };
            bool deleteData = false;
            if (Array.Exists(dataDirs, HasFiles))
            {
                bool quarantine = HasFiles(Path.Combine(Program.BaseDir, @"data\quarantine")) || HasFiles(Path.Combine(LocalData, "quarantine"));
                var dq = L.T("Видалити також зібрані дані (чорна скринька, звіти, налаштування, резервні копії рецептів)?",
                             "Also delete collected data (black box, reports, settings, recipe backups)?")
                       + (quarantine ? L.T("\n\nУВАГА: у карантині є прибрані хвости. Разом із даними вони зникнуть назавжди — відновити їх буде неможливо.",
                                           "\n\nWARNING: the quarantine holds cleaned-up leftovers. They will be gone for good with the data — restoring them will be impossible.") : "")
                       + L.T("\n\n«Ні» — дані лишаться в папці програми.", "\n\n\"No\" keeps the data in the program folder.");
                deleteData = MessageBox.Show(owner, dq, L.T("Видалити DEADPIXEL", "Remove DEADPIXEL"), MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
            }

            app.Sampler.Stop(); // відпускає файли чорної скриньки
            var failed = RemoveTraces(true);
            if (deleteData)
                foreach (var d in dataDirs)
                    try { if (Directory.Exists(d)) Directory.Delete(d, true); }
                    catch (Exception ex) { failed.Add(d + ": " + ex.Message); }

            var done = failed.Count == 0
                ? L.T("Сліди DEADPIXEL прибрано.", "DEADPIXEL traces removed.")
                : L.T("Прибрано не все:\n• ", "Not everything was removed:\n• ") + string.Join("\n• ", failed);
            MessageBox.Show(owner, done + L.T("\n\nЛишилося видалити папку програми:\n", "\n\nWhat remains is to delete the program folder:\n") + Program.BaseDir.TrimEnd('\\')
                            + L.T("\n\nВона зараз відкриється у Провіднику.", "\n\nIt will now open in Explorer."),
                            L.T("Видалити DEADPIXEL", "Remove DEADPIXEL"), MessageBoxButtons.OK, failed.Count == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            try { Process.Start("explorer.exe", "/select,\"" + Program.BaseDir.TrimEnd('\\') + "\""); } catch { }
            app.ExitThread();
        }

        static object Call(object o, string name, params object[] args) { return o.GetType().InvokeMember(name, BindingFlags.InvokeMethod, null, o, args); }
        static object Get(object o, string name) { return o.GetType().InvokeMember(name, BindingFlags.GetProperty, null, o, null); }
        static object GetItem(object o, int index) { return o.GetType().InvokeMember("Item", BindingFlags.GetProperty, null, o, new object[] { index }); }
    }
}
