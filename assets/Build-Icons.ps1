# Rebuild the Windows ICO files from the same 16-unit geometry as deadpixel.svg.
# No external libraries required. The small frames snap to physical pixels.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class DeadPixelIconAssets
{
    static float P(int n, int size) { return (float)Math.Round(n * size / 16.0); }

    public static Bitmap Render(int size, Color accent)
    {
        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float edge = size - 1, diameter = size * 6f / 16;
            using (var path = new GraphicsPath())
            using (var background = new SolidBrush(Color.FromArgb(32, 35, 41)))
            {
                path.AddArc(0, 0, diameter, diameter, 180, 90);
                path.AddArc(edge - diameter, 0, diameter, diameter, 270, 90);
                path.AddArc(edge - diameter, edge - diameter, diameter, diameter, 0, 90);
                path.AddArc(0, edge - diameter, diameter, diameter, 90, 90);
                path.CloseFigure();
                g.FillPath(background, path);
            }
            g.SmoothingMode = SmoothingMode.None;
            using (var white = new SolidBrush(Color.FromArgb(245, 244, 240)))
            using (var pixel = new SolidBrush(accent))
            {
                g.FillRectangle(white, P(3,size), P(5,size), P(8,size)-P(3,size), P(13,size)-P(5,size));
                g.FillRectangle(white, P(8,size), P(8,size), P(11,size)-P(8,size), P(13,size)-P(8,size));
                g.FillRectangle(pixel, P(10,size), P(2,size), P(13,size)-P(10,size), P(5,size)-P(2,size));
            }
        }
        return bmp;
    }

    // Classic 32-bit DIB frame: BITMAPINFOHEADER (double height) + bottom-up BGRA + AND mask.
    // System.Drawing.Icon in .NET Framework misreads PNG frames as DIB and draws noise, so the sizes the
    // tray and window frames use stay DIB; 128/256 (Explorer only) are PNG to keep the files small.
    static byte[] Dib(Bitmap bmp)
    {
        int size = bmp.Width, maskStride = (size + 31) / 32 * 4;
        var data = bmp.LockBits(new Rectangle(0, 0, size, size), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var pixels = new byte[size * size * 4];
        for (int y = 0; y < size; y++)
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, pixels, (size - 1 - y) * size * 4, size * 4);
        bmp.UnlockBits(data);
        var mask = new byte[maskStride * size];
        for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
                if (pixels[(y * size + x) * 4 + 3] == 0) mask[y * maskStride + x / 8] |= (byte)(0x80 >> (x % 8));
        using (var stream = new MemoryStream())
        using (var w = new BinaryWriter(stream))
        {
            w.Write(40); w.Write(size); w.Write(size * 2); w.Write((ushort)1); w.Write((ushort)32);
            w.Write(0); w.Write(pixels.Length + mask.Length); w.Write(0); w.Write(0); w.Write(0); w.Write(0);
            w.Write(pixels); w.Write(mask);
            return stream.ToArray();
        }
    }

    public static void Write(string path, Color accent)
    {
        int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
        var frames = new byte[sizes.Length][];
        for (int i = 0; i < sizes.Length; i++)
            using (var bmp = Render(sizes[i], accent))
            using (var stream = new MemoryStream())
            {
                if (sizes[i] <= 64) { frames[i] = Dib(bmp); continue; }
                bmp.Save(stream, ImageFormat.Png);
                frames[i] = stream.ToArray();
            }
        using (var writer = new BinaryWriter(File.Create(path)))
        {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
            int offset = 6 + 16 * sizes.Length;
            for (int i = 0; i < sizes.Length; i++)
            {
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)32);
                writer.Write(frames[i].Length); writer.Write(offset);
                offset += frames[i].Length;
            }
            foreach (var frame in frames) writer.Write(frame);
        }
    }
}
'@

[DeadPixelIconAssets]::Write((Join-Path $PSScriptRoot 'deadpixel.ico'), [System.Drawing.Color]::FromArgb(255, 121, 47))
[DeadPixelIconAssets]::Write((Join-Path $PSScriptRoot 'deadpixel-warning.ico'), [System.Drawing.Color]::FromArgb(250, 204, 21))
[DeadPixelIconAssets]::Write((Join-Path $PSScriptRoot 'deadpixel-alert.ico'), [System.Drawing.Color]::FromArgb(239, 68, 68))
$preview = [DeadPixelIconAssets]::Render(256, [System.Drawing.Color]::FromArgb(255, 121, 47))
try { $preview.Save((Join-Path $PSScriptRoot 'deadpixel.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
finally { $preview.Dispose() }
