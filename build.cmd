@echo off
:: Builds DeadPixel.exe with the C# compiler that ships with Windows (.NET Framework 4.x)
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /optimize+ /codepage:65001 /win32manifest:"%~dp0src\app.manifest" ^
  /out:"%~dp0DeadPixel.exe" ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll /r:System.Management.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ^
  "%~dp0src\*.cs"
