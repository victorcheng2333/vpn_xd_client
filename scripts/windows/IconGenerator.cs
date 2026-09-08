using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

// Windows rendering of scripts/icon.swift, with the same 1024-unit geometry and colors.
internal static class IconGenerator
{
    private static byte[] Render(int size)
    {
        // Supersampling keeps the shield and power symbol legible in Explorer's small views.
        int resolution = Math.Max(256, size);
        using (var bitmap = new Bitmap(resolution, resolution, PixelFormat.Format32bppArgb))
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TranslateTransform(0, resolution);
            graphics.ScaleTransform(resolution / 1024f, -resolution / 1024f);
            using (var background = new SolidBrush(Color.FromArgb(25, 45, 39)))
            using (var rounded = new GraphicsPath())
            {
                rounded.AddArc(66, 66, 404, 404, 180, 90);
                rounded.AddArc(554, 66, 404, 404, 270, 90);
                rounded.AddArc(554, 554, 404, 404, 0, 90);
                rounded.AddArc(66, 554, 404, 404, 90, 90);
                rounded.CloseFigure(); graphics.FillPath(background, rounded);
            }
            Color mint = Color.FromArgb(184, 230, 201);
            using (var orbit = new Pen(Color.FromArgb(31, mint), 2))
                foreach (int radius in new[] { 280, 360 }) graphics.DrawEllipse(orbit, 512 - radius, 512 - radius, radius * 2, radius * 2);
            using (var shield = new GraphicsPath())
            using (var stroke = new Pen(mint, 26) { LineJoin = LineJoin.Round })
            {
                shield.AddBezier(512, 760, 565, 722, 650, 690, 705, 682);
                shield.AddLine(705, 682, 705, 501);
                shield.AddBezier(705, 501, 705, 388, 583, 307, 512, 284);
                shield.AddBezier(512, 284, 441, 307, 319, 388, 319, 501);
                shield.AddLine(319, 501, 319, 682);
                shield.AddBezier(319, 682, 374, 690, 459, 722, 512, 760);
                shield.CloseFigure(); graphics.DrawPath(stroke, shield);
            }
            using (var power = new Pen(mint, 25) { StartCap = LineCap.Round, EndCap = LineCap.Round })
            {
                graphics.DrawArc(power, 418, 435, 188, 188, 135, 270);
                graphics.DrawLine(power, 512, 662, 512, 546);
            }
            using (var output = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            using (var scaled = Graphics.FromImage(output))
            using (var stream = new MemoryStream())
            {
                scaled.InterpolationMode = InterpolationMode.HighQualityBicubic;
                scaled.DrawImage(bitmap, new Rectangle(0, 0, size, size));
                output.Save(stream, ImageFormat.Png); return stream.ToArray();
            }
        }
    }
    private static void Main(string[] args)
    {
        string directory = args[0]; Directory.CreateDirectory(directory);
        int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 96, 128, 256 };
        var frames = new List<byte[]>(); foreach (int size in sizes) frames.Add(Render(size));
        using (var writer = new BinaryWriter(File.Create(Path.Combine(directory, "XDVPN.ico"))))
        {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
            int offset = 6 + sizes.Length * 16;
            for (int i = 0; i < sizes.Length; i++)
            {
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i])); writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((byte)0); writer.Write((byte)0); writer.Write((ushort)1); writer.Write((ushort)32);
                writer.Write(frames[i].Length); writer.Write(offset); offset += frames[i].Length;
            }
            foreach (byte[] frame in frames) writer.Write(frame);
        }
        File.WriteAllBytes(Path.Combine(directory, "XDVPN.png"), Render(1024));
    }
}
