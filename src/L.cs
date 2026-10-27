using System;
using System.Globalization;
using System.IO;
using System.Linq;

namespace DeadPixel
{
    // Мова інтерфейсу. Тексти лежать парами просто в коді: L.T("українською", "English") — так переклад не відстає
    // від оригіналу і його перевіряє компілятор. Мова обирається один раз під час запуску (зміна — після перезапуску).
    static class L
    {
        public static bool En { get; private set; }
        public static string Code { get { return En ? "en" : "uk"; } }

        public static string T(string uk, string en) { return En ? en : uk; }

        // setting: system | uk | en. «system» — українська, якщо такою є мова Windows, інакше англійська
        public static void Init(string setting)
        {
            if (setting == "en") En = true;
            else if (setting == "uk") En = false;
            else En = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName != "uk";
        }

        // Для модулів: та сама настройка з data\settings.ini. Файл є, а рядка Language немає — це оновлення
        // з версії, яка була лише українською: лишаємо українську, щоб інтерфейс не змінився раптово
        public static string ReadSetting(params string[] iniCandidates)
        {
            foreach (var ini in iniCandidates)
            {
                try
                {
                    if (!File.Exists(ini)) continue;
                    var line = File.ReadAllLines(ini).FirstOrDefault(l => l.StartsWith("Language="));
                    return line != null ? line.Substring(9).Trim() : "uk";
                }
                catch { }
            }
            return "system";
        }
    }
}
