using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// GeoColor 影像的逐像素後製。放在 C# 是因為 PowerShell 逐像素跑 5500x5500 會慢到不可用。
public static class ImageOps
{
    // 夜面提亮：GeoColor 的夜側是紅外線雲層 + 靜態城市燈光，本身偏暗。
    // 這裡用「亮度加權的 gamma 提升」而非單純乘法 —— 乘法會把夜面的感測雜訊一起放大，
    // gamma 只把暗部往上拉、亮部維持原樣，日面與晨昏線因此完全不受影響。
    //
    // amount = 1.0 代表不做任何事；1.5 約等於舊版 NightLightsBrightness 的預設觀感。
    public static void NightBoost(Bitmap bmp, double amount)
    {
        if (amount <= 1.0001) return;

        Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        BitmapData bd = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int stride = bd.Stride;
        byte[] buf = new byte[stride * bmp.Height];
        Marshal.Copy(bd.Scan0, buf, 0, buf.Length);

        // 256 階查表，省下每像素一次 Math.Pow
        byte[][] lut = new byte[33][];
        for (int g = 0; g < 33; g++)
        {
            // w 由 0（全亮）到 1（全暗），對應 gamma 1.0 ~ amount
            double gamma = 1.0 + (amount - 1.0) * (g / 32.0);
            byte[] row = new byte[256];
            for (int v = 0; v < 256; v++)
                row[v] = (byte)Math.Min(255.0, Math.Round(255.0 * Math.Pow(v / 255.0, 1.0 / gamma)));
            lut[g] = row;
        }

        for (int y = 0; y < bmp.Height; y++)
        {
            int i = y * stride;
            for (int x = 0; x < bmp.Width; x++, i += 4)
            {
                byte b = buf[i], gr = buf[i + 1], r = buf[i + 2];
                // 感知亮度；閾值 0.35 以上視為日面，完全不動
                double l = (0.299 * r + 0.587 * gr + 0.114 * b) / 255.0;
                double w = 1.0 - l / 0.35;
                if (w <= 0) continue;
                if (w > 1) w = 1;
                w = w * w * (3 - 2 * w);           // smoothstep，避免在晨昏線出現硬邊
                byte[] row = lut[(int)(w * 32)];
                buf[i] = row[b]; buf[i + 1] = row[gr]; buf[i + 2] = row[r];
            }
        }

        Marshal.Copy(buf, 0, bd.Scan0, buf.Length);
        bmp.UnlockBits(bd);
    }
}
