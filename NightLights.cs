using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// 將 NASA Black Marble 夜間燈光圖混合到全圓盤衛星影像的夜面（EarthDesk 式模擬效果）
public static class NightLights
{
    // disk: 正方形全圓盤衛星影像 (32bppArgb)、lights: 等距圓柱投影夜燈圖 (32bppArgb)
    // subLonDeg: 衛星星下點經度、sunDeclRad: 太陽赤緯(弧度)、subsolarLonDeg: 太陽直射點經度
    public static void Blend(Bitmap disk, Bitmap lights, double subLonDeg, double sunDeclRad, double subsolarLonDeg, double brightness)
    {
        int size = disk.Width;
        const double R = 6371.0;   // 地球半徑 (km)
        const double D = 42164.0;  // 地球同步軌道半徑 (km)
        double amax = Math.Asin(R / D); // 從衛星看地球圓盤的角半徑，對應影像邊緣
        double subLon = subLonDeg * Math.PI / 180.0;
        double sunLon = subsolarLonDeg * Math.PI / 180.0;
        double sinDecl = Math.Sin(sunDeclRad), cosDecl = Math.Cos(sunDeclRad);

        BitmapData dd = disk.LockBits(new Rectangle(0, 0, disk.Width, disk.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        BitmapData ld = lights.LockBits(new Rectangle(0, 0, lights.Width, lights.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int dStride = dd.Stride, lStride = ld.Stride;
        byte[] dBuf = new byte[dStride * disk.Height];
        byte[] lBuf = new byte[lStride * lights.Height];
        Marshal.Copy(dd.Scan0, dBuf, 0, dBuf.Length);
        Marshal.Copy(ld.Scan0, lBuf, 0, lBuf.Length);
        int lw = lights.Width, lh = lights.Height;

        for (int y = 0; y < size; y++)
        {
            double py = 1.0 - 2.0 * (y + 0.5) / size;
            for (int x = 0; x < size; x++)
            {
                double px = 2.0 * (x + 0.5) / size - 1.0;
                if (px * px + py * py > 1.0) continue;

                // 衛星影像是從同步軌道看的透視投影（非正射），故用射線與球面求交點反推經緯度。
                // 衛星位於 (D,0,0)，+Z 為北極，影像掃描角與像素位置成線性
                double ux = -1.0, uy = Math.Tan(px * amax), uz = Math.Tan(py * amax);
                double norm = Math.Sqrt(ux * ux + uy * uy + uz * uz);
                ux /= norm; uy /= norm; uz /= norm;
                double b = D * ux;
                double disc = b * b - (D * D - R * R);
                if (disc < 0) continue; // 視線落在地球外（圓盤最邊緣）
                double t = -b - Math.Sqrt(disc); // 取近側交點
                double gx = D + t * ux, gy = t * uy, gz = t * uz;

                double lat = Math.Asin(gz / R);
                double lon = subLon + Math.Atan2(gy, gx);

                // 太陽高度角餘弦 mu：>0 白天不疊燈光，0 ~ -0.12（約日落後至天文暮光）平滑淡入
                double mu = Math.Sin(lat) * sinDecl + Math.Cos(lat) * cosDecl * Math.Cos(lon - sunLon);
                double f = -mu / 0.12;
                if (f <= 0) continue;
                if (f > 1) f = 1;
                f = f * f * (3 - 2 * f); // smoothstep 讓暮光帶過渡自然

                // 等距圓柱投影雙線性取樣，經度需環繞、緯度夾住邊界
                double fx = (lon * 180.0 / Math.PI + 180.0) / 360.0;
                fx = fx - Math.Floor(fx);
                double sx = fx * lw - 0.5;
                double sy = (90.0 - lat * 180.0 / Math.PI) / 180.0 * lh - 0.5;
                int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
                double wx = sx - x0, wy = sy - y0;
                int x0m = ((x0 % lw) + lw) % lw;
                int x1m = ((x0 + 1) % lw + lw) % lw;
                if (y0 < 0) y0 = 0;
                int y1 = y0 + 1 < lh ? y0 + 1 : lh - 1;
                if (y0 > lh - 1) y0 = lh - 1;

                int i00 = y0 * lStride + x0m * 4, i10 = y0 * lStride + x1m * 4;
                int i01 = y1 * lStride + x0m * 4, i11 = y1 * lStride + x1m * 4;
                double scale = f * brightness;
                int di = y * dStride + x * 4;
                for (int c = 0; c < 3; c++)
                {
                    double lv = (lBuf[i00 + c] * (1 - wx) + lBuf[i10 + c] * wx) * (1 - wy)
                              + (lBuf[i01 + c] * (1 - wx) + lBuf[i11 + c] * wx) * wy;
                    int v = dBuf[di + c] + (int)(lv * scale);
                    dBuf[di + c] = (byte)(v > 255 ? 255 : v);
                }
            }
        }
        Marshal.Copy(dBuf, 0, dd.Scan0, dBuf.Length);
        disk.UnlockBits(dd);
        lights.UnlockBits(ld);
    }
}
