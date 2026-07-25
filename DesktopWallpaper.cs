using System;
using System.Runtime.InteropServices;

// Windows 桌面「投影片放映」設定。
// 登錄檔 HKCU\...\Explorer\Wallpapers 下的 SlideshowDirectoryPath1 是序列化的 shell PIDL
// （base64 二進位資料），格式未公開且無法安全地手工組出；改用 Windows 8 起提供的
// 公開 COM 介面 IDesktopWallpaper，由系統自行寫入登錄檔，跨版本相容且可逆。
public static class DesktopWallpaper
{
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopWallpaper
    {
        // vtable 順序必須與 shobjidl_core.h 完全一致，勿增刪或調換
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        void GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out IntPtr wallpaper);
        void GetMonitorDevicePathAt(uint monitorIndex, out IntPtr monitorID);
        void GetMonitorDevicePathCount(out uint count);
        void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out RECT displayRect);
        void SetBackgroundColor(uint color);
        void GetBackgroundColor(out uint color);
        void SetPosition(int position);
        void GetPosition(out int position);
        void SetSlideshow([MarshalAs(UnmanagedType.Interface)] object items);
        void GetSlideshow([MarshalAs(UnmanagedType.Interface)] out object items);
        void SetSlideshowOptions(int options, uint slideshowTick);
        void GetSlideshowOptions(out int options, out uint slideshowTick);
        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
        void GetStatus(out int state);
        void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(int sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out object ppv);

    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SHCreateShellItemArrayFromShellItem(IShellItem psi, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out object ppv);

    static readonly Guid CLSID_DesktopWallpaper = new Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD");
    static Guid IID_IShellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
    static Guid IID_IShellItemArray = new Guid("B63EA76D-1F85-456F-A19C-48159EFA858B");

    // DESKTOP_WALLPAPER_POSITION
    public const int PositionFill = 4;
    // DESKTOP_SLIDESHOW_OPTIONS：0 = 依序播放、1 = DSO_SHUFFLEIMAGES 隨機
    const int OptionsInOrder = 0;

    static IDesktopWallpaper Create()
    {
        Type t = Type.GetTypeFromCLSID(CLSID_DesktopWallpaper);
        return (IDesktopWallpaper)Activator.CreateInstance(t);
    }

    // 將指定資料夾設為桌布投影片來源，tickSeconds 為切換間隔（秒）
    public static void StartSlideshow(string folder, int tickSeconds)
    {
        object si;
        SHCreateItemFromParsingName(folder, IntPtr.Zero, ref IID_IShellItem, out si);
        object arr;
        SHCreateShellItemArrayFromShellItem((IShellItem)si, ref IID_IShellItemArray, out arr);

        IDesktopWallpaper dw = Create();
        dw.SetPosition(PositionFill);
        dw.SetSlideshow(arr);
        // slideshowTick 單位為毫秒；Windows 設定介面最短為 1 分鐘，但 API 可接受更短值
        dw.SetSlideshowOptions(OptionsInOrder, (uint)(tickSeconds * 1000));

        Marshal.ReleaseComObject(arr);
        Marshal.ReleaseComObject(si);
        Marshal.ReleaseComObject(dw);
    }

    // 把同一張圖套用到「所有」螢幕。monitorID 傳 null 即代表全部，
    // 這是內建投影片放映做不到的（它會讓每個螢幕各自輪播不同影像）
    public static void SetAllMonitors(string path)
    {
        IDesktopWallpaper dw = Create();
        dw.SetPosition(PositionFill);
        dw.SetWallpaper(null, path);
        Marshal.ReleaseComObject(dw);
    }

    // 逐一讀回每個螢幕目前的桌布路徑，用來確認多螢幕是否真的同步
    public static string[] GetPerMonitorWallpapers()
    {
        IDesktopWallpaper dw = Create();
        uint count;
        dw.GetMonitorDevicePathCount(out count);
        string[] result = new string[count];
        for (uint i = 0; i < count; i++)
        {
            IntPtr idPtr;
            dw.GetMonitorDevicePathAt(i, out idPtr);
            string id = Marshal.PtrToStringUni(idPtr);
            Marshal.FreeCoTaskMem(idPtr);

            IntPtr wpPtr;
            dw.GetWallpaper(id, out wpPtr);
            result[i] = Marshal.PtrToStringUni(wpPtr);
            Marshal.FreeCoTaskMem(wpPtr);
        }
        Marshal.ReleaseComObject(dw);
        return result;
    }

    // 立即切換到下一張，讓剛存檔的最新影像馬上顯示，不必等一輪間隔
    public static void Advance()
    {
        IDesktopWallpaper dw = Create();
        try { dw.AdvanceSlideshow(null, 0); } // DSD_FORWARD
        catch { }
        Marshal.ReleaseComObject(dw);
    }

    // 還原成單張靜態桌布，投影片模式隨之結束
    public static void StopSlideshow(string wallpaperPath)
    {
        IDesktopWallpaper dw = Create();
        dw.SetPosition(PositionFill);
        dw.SetWallpaper(null, wallpaperPath);
        Marshal.ReleaseComObject(dw);
    }

    // 0 = DSS_DISABLED_BY_REMOTE_SESSION、1 = DSS_ENABLED、2 = DSS_SLIDESHOW、4 = DSS_DISABLED_BY_REMOTE_SESSION
    public static int GetStatusFlags()
    {
        IDesktopWallpaper dw = Create();
        int state;
        dw.GetStatus(out state);
        Marshal.ReleaseComObject(dw);
        return state;
    }
}
