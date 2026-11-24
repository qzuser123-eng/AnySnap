using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace AnySnap;

public static class ScreenCapture
{
    /// Captures one window. Uses PrintWindow (works for windows that are partly covered),
    /// falls back to copying the screen area when PrintWindow returns an empty image.
    public static Bitmap? Capture(IntPtr hwnd, out string? warning)
    {
        warning = null;
        if (Native.IsIconic(hwnd))
        {
            warning = "The window is minimized, so no screenshot was taken.";
            return null;
        }
        var frame = Native.FrameBounds(hwnd);
        Native.GetWindowRect(hwnd, out var wr);
        if (frame.Width <= 0 || frame.Height <= 0 || wr.Width <= 0 || wr.Height <= 0) return null;

        Bitmap? full = null;
        try
        {
            full = new Bitmap(wr.Width, wr.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(full))
            {
                var hdc = g.GetHdc();
                bool ok;
                try { ok = Native.PrintWindow(hwnd, hdc, Native.PW_RENDERFULLCONTENT); }
                finally { g.ReleaseHdc(hdc); }
                if (!ok) { full.Dispose(); full = null; }
            }
            if (full != null)
            {
                // Crop the invisible resize borders (GetWindowRect is larger than the visible frame).
                var crop = new Rectangle(frame.Left - wr.Left, frame.Top - wr.Top, frame.Width, frame.Height);
                crop.Intersect(new Rectangle(0, 0, full.Width, full.Height));
                if (crop.Width > 0 && crop.Height > 0 && crop.Size != full.Size)
                {
                    var c = full.Clone(crop, PixelFormat.Format32bppArgb);
                    full.Dispose();
                    full = c;
                }
                if (IsBlank(full)) { full.Dispose(); full = null; }
            }
        }
        catch
        {
            full?.Dispose();
            full = null;
        }

        if (full == null)
        {
            try
            {
                full = new Bitmap(frame.Width, frame.Height, PixelFormat.Format32bppArgb);
                using var g = Graphics.FromImage(full);
                g.CopyFromScreen(frame.Left, frame.Top, 0, 0, new Size(frame.Width, frame.Height));
                warning = "PrintWindow failed; the screenshot was copied from the screen, so overlapping windows may be visible.";
            }
            catch
            {
                full?.Dispose();
                return null;
            }
        }
        return full;
    }

    /// True if the image is a single flat colour (PrintWindow returns black for some windows).
    static bool IsBlank(Bitmap bmp)
    {
        int w = bmp.Width, h = bmp.Height;
        var first = bmp.GetPixel(w / 2, h / 2).ToArgb();
        for (int i = 1; i <= 8; i++)
        {
            for (int j = 1; j <= 8; j++)
            {
                if (bmp.GetPixel(w * i / 9, h * j / 9).ToArgb() != first) return false;
            }
        }
        return true;
    }

    /// JPEG for MCP responses: longest side at most maxSide pixels.
    public static byte[]? JpegFromFile(string path, int maxSide = 1568, long quality = 80)
    {
        try
        {
            using var src = new Bitmap(path);
            double scale = Math.Min(1.0, (double)maxSide / Math.Max(src.Width, src.Height));
            int w = Math.Max(1, (int)(src.Width * scale)), h = Math.Max(1, (int)(src.Height * scale));
            using var dst = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(dst))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.Clear(Color.White);
                g.DrawImage(src, 0, 0, w, h);
            }
            var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
            using var ps = new EncoderParameters(1);
            ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
            using var ms = new MemoryStream();
            dst.Save(ms, codec, ps);
            return ms.ToArray();
        }
        catch { return null; }
    }
}
