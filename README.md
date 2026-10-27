# DEADPIXEL

[Українська](README.uk.md) · **English**

Diagnostics for crash restarts, graphics driver hangs and disk problems on Windows 10/11 — plus a security and
health audit and recipe-based PC setup.

## What's inside

| File | Purpose |
|---|---|
| `DeadPixel.exe` | Tray app with a panel: live GPU/CPU readings, a "black box", crashes with a timeline, dump analysis (WinDbg), patterns, driver/update change history, disks (SMART, stall detector), processes, a diagnostics bundle |
| `DeadPixel.ps1` / `DeadPixel.cmd` | One-off HTML/TXT report for the last N days (`DeadPixel.cmd -Days 60`) |
| `src/` | Tray app source code (C# 5, .NET Framework 4.5+) |
| `build.cmd` | Builds `DeadPixel.exe` and the module GUIs with the compiler that ships with Windows — no Visual Studio or SDK |
| `modules/` | On-demand modules — separate processes the tray only launches (see below) |

## Modules

Heavy or one-off work does not live in the tray app permanently: each module is a separate program/script in
`modules/<name>/`, launched from a tray menu item (`TrayApp.RunModule`) or directly.

### Audit — security and system health check

**GUI** — `modules/audit/AuditGui.exe` (tray item "System audit…"): an overall score 0–100, area cards, the list of checks
from most to least dangerous, and for the selected one — what it is, pros, cons, evidence and what to do.
"Fix…" opens the matching Setup recipe (where changes are visible and can be reverted), "Open in Windows" opens the right
settings window, "Scan with Defender" checks suspicious files (without deleting), "Ignore" is a deliberate choice that no
longer counts toward the score.

Areas: platform protection, Windows protection, accounts, network (who accepts connections and whether the firewall lets
them through), processes and startup (suspicious processes, Startup, Task Scheduler, services whose files any program can
replace, IFEO, WMI), programs and drivers (outdated versions via winget, unsupported programs, drivers), system health
(free space, disks, restarts, restore points), program leftovers (services, tasks, drivers, PATH, firewall, startup,
context menu, installed-program entries, folders with no program, old drivers in the driver store).

**Leftover cleanup goes through quarantine only.** The audit deletes nothing: "Clean up…" hands the selection to the Setup
engine (`Setup.ps1 -Cleanup`, with UAC). Before each action the engine re-checks that the target is still a leftover and
lies in an allowed place, then moves it to `data\quarantine\<date>`: files and folders physically, registry keys and
services as .reg, tasks as XML, firewall rules with all their parameters. "Quarantine…" (or `Setup.ps1 -Quarantine`,
`-Restore <session>`) puts everything back; `-Purge <session>` deletes for good, but not earlier than 30 days later.
Never touched: the Windows folder, the roots of Program Files/ProgramData/AppData, Microsoft folders and folders of running
programs, registry keys outside installed-program entries and context menu handlers, tasks under `\Microsoft\`.

**Schedule** — "Schedule…": the scheduled task `\DEADPIXEL\DEADPIXEL Audit` runs `AuditGui.exe --background` every N days
(no windows, low priority, with standard user rights — the exe lives in a user-writable folder, so running it elevated on a
schedule would be a hole). Creating the task asks for UAC once; without admin rights other users' processes and WMI
subscriptions are not visible, so those checks are marked as limited.
The tray looks at `data\audit\summary.ini` once a minute and notifies only about **new** critical and high findings;
clicking opens the audit on that check. Turn it off in the panel: "Settings → Notifications".
**"HTML report"** saves a page to `reports\` — it contains details about the PC, show it only to people you trust.
**winget** (program update check) queries the Microsoft catalog online; the rest of the audit works offline.

**The audit changes nothing** — it only reads the system. Most checks run without admin rights; without them other users'
and system processes and WMI subscriptions are not visible — then "Scan as administrator" appears.
A scan takes a few seconds. Reports are in `data\audit\` (`latest.json`, `history\`, `ignore.json`;
`sigcache.json` caches verified digital signatures so repeat scans are fast).

**Console** — `modules/audit/Audit.cmd` (elevated, saves the report) or directly:

```bat
powershell -File Audit.ps1                      :: all checks; exit code = number of critical and high findings
powershell -File Audit.ps1 -Area platform       :: one area (platform, windows, accounts, network, processes, software, health, leftovers)
powershell -File Audit.ps1 -Html report.html    :: the latest report as HTML
powershell -File Audit.ps1 -Schedule 3          :: automatically every 3 days; 0 turns it off
powershell -File Audit.ps1 -Check hvci,uac      :: specific checks
powershell -File Audit.ps1 -Save                :: save as the latest report (full scan only)
powershell -File Audit.ps1 -Ignore guest        :: stop counting a finding; -Unignore brings it back
powershell -File Audit.ps1 -Lang en             :: output language (uk / en; default from settings)
```

**A new check** — an entry in `modules/audit/checks/<area>.ps1` (UTF-8 with BOM):

| Field | Meaning |
|---|---|
| `Id`, `Title` | identifier (used for ignoring) and title |
| `Test` | scriptblock; returns `Ok 'value'`, `Issue <critical\|high\|medium\|low\|info> 'value' 'explanation' @(evidence) @(files)`, `Unknown '…'` or `NotApplicable '…'`; `Limited (…)` marks a result as incomplete without admin rights. The GUI offers to scan the files from the fifth argument with Defender |
| `Explain`, `Pros`, `Cons` | what it is in plain words; pros and cons of turning it on |
| `Fix` | `@{ Recipe = 'Setup recipe'; Open = 'ms-settings:…'; Steps = @('manually…') }` |
| `Admin` | `$true` — the check does not run without admin rights |
| `Prepare` | optional scriptblock run before all `Test` blocks — to start long work in parallel (like winget) |

User-facing text is written as a pair: `(T 'українською' 'in English')`.

Score: each finding takes a percentage of what is left: critical 40% (and the score is capped at 39), high 15%
(capped at 79), medium 6%, low 2%; "info" and ignored findings do not count. This way the score does not drop just because
more checks were added.

### Setup — recipe-based PC setup

A **recipe** is a group of settings for a specific task that can be **checked**, **applied** or **reverted**.
A **profile** is a set of recipes for a broader goal (`new-pc`, `stability`) plus steps that cannot be automated.

A **scenario** is a step-by-step guide in a recipe tab ("Enable ping", "ASPM in BIOS"): manual actions, commands with a ▶
button, "if the previous command succeeded / failed" conditions, parameters, restarts.

**GUI** — `modules/setup/SetupGui.exe` (tray item "PC setup…"). Profiles and recipes with a state color on the left, tabs on
the right:
- **Recommended** — current vs desired value, a hint for every setting, "Check / Apply / Revert" buttons, manual steps.
  Checking runs with user rights; UAC is requested only for "Apply" / "Revert".
- **Scenarios** — step cards with a state (○ ✓ ✕ –), command output and a "Why?" explanation; "Run all" goes step by step
  and stops at a manual action, a restart, or an error with no fallback branch. If a step needs admin rights,
  "Restart as administrator" appears at the top — one UAC for the whole session.
- Scenario **progress** (states, output, parameters) is kept in `data\setup\progress.json`. A restart step saves progress,
  adds a one-time GUI launch after sign-in (HKCU `RunOnce`) and restarts the PC (or straight into BIOS/UEFI);
  after startup the window opens on the next step. A restart is counted as done automatically once triggered.

**Console** — `modules/setup/Setup.cmd` (no arguments shows a menu):

```bat
Setup.cmd -List
Setup.cmd -Recipe disk-power            :: check only, changes nothing
Setup.cmd -Recipe disk-power -Apply     :: old values are saved in data\setup\ before the change
Setup.cmd -Recipe disk-power -Revert    :: restores exactly the values from before -Apply
Setup.cmd -ProfileName new-pc -Apply    :: all recipes of a profile
Setup.cmd -Recipe *                     :: audit the PC against all recipes
```

The check exit code = the number of deviations (0 — all as desired, 255 — launch error), so a new PC audit can be scripted.
The GUI calls the same `Setup.ps1` with `-OutFile <json>`: all logic lives in one place, the GUI only shows the result.

**A new recipe** — a file `modules/setup/recipes/<name>.ps1` (UTF-8 with BOM) returning a hashtable:

| Field | Meaning |
|---|---|
| `Title`, `Description` | title and description for the list |
| `Items` | settings (types below) |
| `Steps` | steps on the "Recommended" tab (step format below) |
| `Reboot` | `$true` if a restart is needed after applying |
| `Tabs` | scenarios: `@{ Id; Title; Description; Params; Steps }` |

A step is a string (manual action) or a hashtable:

| Field | What it does |
|---|---|
| `Text`, `Hint` | what to do; the "Why?" explanation |
| `Run` | PowerShell command for the ▶ button; output is shown under the step |
| `Expect` | regex: the step succeeds only if the output matches (otherwise only the exit code / errors count) |
| `If` | `'ok'` / `'fail'` — the step applies only if the previous command succeeded / failed; otherwise it is skipped |
| `Open` | what the "Open ↗" button opens (`devmgmt.msc`, `ms-settings:…`, `control.exe /name …`) |
| `Reboot` | `'restart'` or `'firmware'` (straight into BIOS/UEFI) |
| `Admin` | `$true` — the command needs admin rights |
| `Confirm` | confirmation text before running |

Scenario parameters: `Params = @(@{ Name = 'IP'; Title = '…'; Default = '…'; Pattern = 'regex'; Hint = '…' })`.
Write `{IP}` in `Text` and `Run`: the value is substituted into the command as a quoted string, so it cannot be "executed".

Item types (`Kind`):

| Kind | Fields | Value |
|---|---|---|
| `Power` | `Sub`, `Setting` (alias or GUID), `Power` = `AC`/`DC` | index/number in the active power plan |
| `FirewallRule` | `Name` — **not** `DisplayName`, which is localized | `'True'` / `'False'` |
| `Registry` | `Path`, `Name`, `Type` (default `DWord`) | data or `'<absent>'` (revert deletes the value) |
| `Custom` | `Get = { ... }`, `Set = { param($value) ... }` | anything that serializes to JSON |

Each item has an `Id` (the backup is matched by it), `Title`, `Desired`, `Hint` (explanation in the GUI) and optionally
`Labels = @{ 0 = '…' }` for displaying values.

**A new profile** — `modules/setup/profiles/<name>.ps1`: `@{ Title; Description; Recipes = @('…'); Steps }`.
Examples are in `recipes/` and `profiles/`.

## Language

The UI, audit, Setup recipes, reports and installer are available in Ukrainian and English.
"Settings → Language": **System** (Ukrainian if Windows is in Ukrainian, otherwise English), **Українська**, **English**;
after a change the app offers to restart. The value is stored in `data\settings.ini` (`Language=system|uk|en`).
Scripts read it from there too, or take `-Lang uk|en` (`Audit.ps1 -Lang en`, `Setup.ps1 -Lang en`, `DeadPixel.ps1 -Lang en`).
New script text is written as a pair: `T 'українською' 'in English'` (`modules/common/Lang.ps1`); in C# — `L.T("…", "…")`.

## Building

```bat
build.cmd
```

The "dead pixel" icon: the source mark is `assets/deadpixel.svg`; the Windows ICO files contain sizes 16–256 px.
After changing geometry or colors in `assets/Build-Icons.ps1`, regenerate the icons with
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File assets/Build-Icons.ps1` and run `build.cmd`.
In the tray, an orange pixel means normal state, yellow a warning, red a new unseen failure.
Frames 16–64 px are stored as 32-bit BMP, 128/256 as PNG: `System.Drawing.Icon` in .NET Framework renders PNG frames as noise.

**Shortcuts** — "Settings → Desktop shortcut / Start menu shortcut" or `DeadPixel.exe --shortcuts` (both at once).
A shortcut opens the panel; if DEADPIXEL is already running, a second launch just shows it in the running instance.

## Releases

Ready-made builds are on the [Releases](https://github.com/SamuiRo/DEADPIXEL/releases) page: the installer
`DEADPIXEL-X.Y.Z-setup.exe` (per user, no admin rights) or `DEADPIXEL-X.Y.Z-portable.zip`.

How to release a new version:
1. Change the number in `VERSION` and describe the changes in `CHANGELOG.md` under `## [X.Y.Z] - date`.
2. Commit, tag and push: `git tag vX.Y.Z` → `git push origin master --tags`.
3. GitHub Actions (`.github/workflows/build.yml`) builds the exe, installer, zip and `SHA256SUMS.txt` and publishes a release
   with the text from `CHANGELOG.md`. If the tag does not match `VERSION`, no release is created.

The same package locally: `powershell -NoProfile -File tools\Package.ps1` → `dist\`
(the installer only if [Inno Setup 6](https://jrsoftware.org/isinfo.php) is installed, otherwise just the zip).
Every commit to `master` and every GitHub PR is also built and script syntax is checked.

## Requirements

- Windows 10 1607+ or Windows 11 (.NET Framework 4.6+ is already part of the system).
- GPU data — NVIDIA only (via `nvidia-smi`); without it the app records CPU only.
- CPU temperature — if LibreHardwareMonitor is running.
- Dump analysis — WinDbg (`winget install Microsoft.WinDbg`); a button in the app installs it.

## Command-line switches

`--show` opens the panel, `--settings` the settings, `--page=Диски` a specific tab (the internal tab key; with the English UI the caption works too: `--page=Disks`).
`--shortcuts` creates shortcuts on the desktop and in the Start menu.
Internal (launched by the app itself with UAC): `--analyze <dump>`, `--smart`, `--copydumps <dir>`.

## Data and privacy

Everything the app collects lives in `data/` next to the exe (or in `%LOCALAPPDATA%\DeadPixel` if that folder is not
writable), reports in `reports/`. Both folders are in `.gitignore`: they contain your program names, disk serial numbers
and PC name. Nothing is sent over the network, except downloading Microsoft symbols during dump analysis and the winget
update check in the audit.
