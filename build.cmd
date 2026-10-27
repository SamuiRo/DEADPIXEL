@echo off
:: Builds DeadPixel.exe and module GUIs with the C# compiler that ships with Windows (.NET Framework 4.x)
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
set COMMON=/nologo /target:winexe /optimize+ /codepage:65001 /win32manifest:"%~dp0src\app.manifest" /win32icon:"%~dp0assets\deadpixel.ico"

"%CSC%" %COMMON% /out:"%~dp0DeadPixel.exe" ^
  /resource:"%~dp0assets\deadpixel.ico",DeadPixel.Icon /resource:"%~dp0assets\deadpixel-warning.ico",DeadPixel.Icon.Warning /resource:"%~dp0assets\deadpixel-alert.ico",DeadPixel.Icon.Alert ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll /r:System.Management.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ^
  "%~dp0src\*.cs" || exit /b 1

:: Setup module GUI: shares only the theme with the tray app
"%CSC%" %COMMON% /out:"%~dp0modules\setup\SetupGui.exe" ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll /r:System.Web.Extensions.dll ^
  "%~dp0src\Theme.cs" "%~dp0modules\setup\gui\*.cs" || exit /b 1
