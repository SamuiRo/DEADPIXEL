@echo off
:: Builds DeadPixel.exe and module GUIs with the C# compiler that ships with Windows (.NET Framework 4.x)
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
set /p VERSION=<"%~dp0VERSION"
set COMMON=/nologo /target:winexe /optimize+ /codepage:65001 /win32manifest:"%~dp0src\app.manifest" /win32icon:"%~dp0assets\deadpixel.ico"

:: Version from the VERSION file goes into every exe (file Properties, window title)
if not exist "%~dp0obj" mkdir "%~dp0obj"
set INFO=%~dp0obj\AssemblyInfo.cs
> "%INFO%" echo [assembly: System.Reflection.AssemblyTitle("DEADPIXEL")]
>>"%INFO%" echo [assembly: System.Reflection.AssemblyProduct("DEADPIXEL")]
>>"%INFO%" echo [assembly: System.Reflection.AssemblyCopyright("Copyright (c) 2026 StarLith, MIT License")]
>>"%INFO%" echo [assembly: System.Reflection.AssemblyVersion("%VERSION%.0")]
>>"%INFO%" echo [assembly: System.Reflection.AssemblyFileVersion("%VERSION%.0")]
>>"%INFO%" echo [assembly: System.Reflection.AssemblyInformationalVersion("%VERSION%")]

"%CSC%" %COMMON% /out:"%~dp0DeadPixel.exe" ^
  /resource:"%~dp0assets\deadpixel.ico",DeadPixel.Icon /resource:"%~dp0assets\deadpixel-warning.ico",DeadPixel.Icon.Warning /resource:"%~dp0assets\deadpixel-alert.ico",DeadPixel.Icon.Alert ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll /r:System.Management.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ^
  "%INFO%" "%~dp0src\*.cs" || exit /b 1

:: Setup module GUI: shares only the theme with the tray app
"%CSC%" %COMMON% /out:"%~dp0modules\setup\SetupGui.exe" ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll /r:System.Web.Extensions.dll ^
  "%INFO%" "%~dp0src\Theme.cs" "%~dp0modules\setup\gui\*.cs" || exit /b 1
