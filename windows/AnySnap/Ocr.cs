using System.Drawing;
using System.Drawing.Imaging;
using System.Text;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace AnySnap;

/// Fallback for windows without usable UI Automation text: Windows' built-in OCR.
public static class Ocr
{
    public static string? Recognize(Bitmap bmp)
    {
        try
        {
            return RecognizeAsync(bmp).GetAwaiter().GetResult();
        }
        catch
        {
            return null;
        }
    }

    static async Task<string?> RecognizeAsync(Bitmap bmp)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine == null) return null;

        Bitmap src = bmp;
        Bitmap? scaled = null;
        uint max = OcrEngine.MaxImageDimension;
        if (bmp.Width > max || bmp.Height > max)
        {
            double s = Math.Min((double)max / bmp.Width, (double)max / bmp.Height);
            scaled = new Bitmap(bmp, new Size(Math.Max(1, (int)(bmp.Width * s)), Math.Max(1, (int)(bmp.Height * s))));
            src = scaled;
        }

        try
        {
            using var ms = new MemoryStream();
            src.Save(ms, ImageFormat.Png);
            ms.Position = 0;
            using var ras = ms.AsRandomAccessStream();
            var decoder = await BitmapDecoder.CreateAsync(ras);
            using var sb = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var result = await engine.RecognizeAsync(sb);

            bool cjk = engine.RecognizerLanguage.LanguageTag.StartsWith("zh", StringComparison.OrdinalIgnoreCase)
                    || engine.RecognizerLanguage.LanguageTag.StartsWith("ja", StringComparison.OrdinalIgnoreCase);
            var text = new StringBuilder();
            foreach (var line in result.Lines)
            {
                // OCR separates CJK characters with spaces; join them back.
                var l = cjk ? string.Concat(line.Words.Select(w => w.Text)) : line.Text;
                text.Append(l).Append('\n');
            }
            return text.ToString().Trim();
        }
        finally
        {
            scaled?.Dispose();
        }
    }
}
