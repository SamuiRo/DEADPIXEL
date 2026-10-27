using System;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace DeadPixel
{
    // Ярлики DeadPixel.exe на робочому столі та в меню «Пуск» (через WScript.Shell — без додаткових бібліотек)
    static class Shortcuts
    {
        public static string Desktop { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DEADPIXEL.lnk"); } }
        public static string StartMenu { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DEADPIXEL.lnk"); } }

        // Ярлик вважається нашим, лише якщо веде на цей exe: старий ярлик з іншої папки перезапишемо
        public static bool Exists(string lnk)
        {
            if (!File.Exists(lnk)) return false;
            try { return string.Equals(Target(lnk), Application.ExecutablePath, StringComparison.OrdinalIgnoreCase); }
            catch { return true; }
        }

        public static void Set(string lnk, bool on)
        {
            if (!on) { if (File.Exists(lnk)) File.Delete(lnk); return; }
            var exe = Application.ExecutablePath;
            var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            try
            {
                var sc = Call(shell, "CreateShortcut", lnk);
                Put(sc, "TargetPath", exe);
                Put(sc, "Arguments", "--show");
                Put(sc, "WorkingDirectory", Path.GetDirectoryName(exe));
                Put(sc, "IconLocation", exe + ",0");
                Put(sc, "Description", L.T("DEADPIXEL — моніторинг і діагностика збоїв", "DEADPIXEL — crash monitoring and diagnostics"));
                Call(sc, "Save");
            }
            finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
        }

        static string Target(string lnk)
        {
            var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            try { return (string)Get(Call(shell, "CreateShortcut", lnk), "TargetPath"); }
            finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
        }

        static object Call(object o, string name, params object[] args) { return o.GetType().InvokeMember(name, BindingFlags.InvokeMethod, null, o, args); }
        static object Get(object o, string name) { return o.GetType().InvokeMember(name, BindingFlags.GetProperty, null, o, null); }
        static void Put(object o, string name, object v) { o.GetType().InvokeMember(name, BindingFlags.SetProperty, null, o, new[] { v }); }
    }
}
