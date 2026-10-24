// Native helpers for Smart Memory. Compiled at start-up by Add-Type
// (Windows PowerShell 5.1 uses the C# 5 compiler, so no newer syntax here).
//
// Everything here works without administrator rights, and so only on this user's own apps:
// Windows itself, services and other users' programs cannot even be opened.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace SmartMemory
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        // Total and available memory (RAM), and the commit limit and what is left of it, in bytes.
        public static long[] Status()
        {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            if (!GlobalMemoryStatusEx(m)) return new long[] { -1, -1, -1, -1 };
            return new long[] { (long)m.ullTotalPhys, (long)m.ullAvailPhys, (long)m.ullTotalPageFile, (long)m.ullAvailPageFile };
        }

        [DllImport("ntdll.dll")]
        static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returnLength);

        // The memory each process uses on its own (its "private working set") - the number Task
        // Manager shows - for every process at once, by process id. One quick call, no
        // administrator rights needed.
        public static Dictionary<int, long> PrivateWorkingSets()
        {
            Dictionary<int, long> result = new Dictionary<int, long>();
            foreach (KeyValuePair<int, long[]> kv in ProcessTable()) result[kv.Key] = kv.Value[0];
            return result;
        }

        // Per process id: { private working set, the id of the process that started it }.
        public static Dictionary<int, long[]> ProcessTable()
        {
            const int SystemProcessInformation = 5;
            Dictionary<int, long[]> result = new Dictionary<int, long[]>();
            int size = 1024 * 1024;
            for (int attempt = 0; attempt < 5; attempt++)
            {
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    int needed;
                    int status = NtQuerySystemInformation(SystemProcessInformation, buffer, size, out needed);
                    if (status == unchecked((int)0xC0000004)) { size = Math.Max(size * 2, needed + 65536); continue; }   // buffer too small
                    if (status != 0) return result;
                    // SYSTEM_PROCESS_INFORMATION: WorkingSetPrivateSize at 8; UniqueProcessId and
                    // InheritedFromUniqueProcessId at 80 and 88 (64-bit) or 68 and 72 (32-bit).
                    int pidOffset = IntPtr.Size == 8 ? 80 : 68;
                    int parentOffset = IntPtr.Size == 8 ? 88 : 72;
                    long offset = 0;
                    while (true)
                    {
                        IntPtr entry = new IntPtr(buffer.ToInt64() + offset);
                        long privateBytes = Marshal.ReadInt64(entry, 8);
                        int pid = Marshal.ReadIntPtr(entry, pidOffset).ToInt32();
                        int parent = Marshal.ReadIntPtr(entry, parentOffset).ToInt32();
                        result[pid] = new long[] { privateBytes, parent };
                        int next = Marshal.ReadInt32(entry, 0);
                        if (next == 0) break;
                        offset += next;
                    }
                    return result;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            return result;
        }

        const uint PROCESS_SET_QUOTA = 0x0100;
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("psapi.dll")]
        static extern bool EmptyWorkingSet(IntPtr process);

        // Asks one process to give back the memory it is not using right now. Its pages go to
        // Windows' standby list and come back the moment the app needs them again.
        public static bool Trim(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return false;
            try { return EmptyWorkingSet(h); }
            finally { CloseHandle(h); }
        }

        delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")]
        static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
        [DllImport("user32.dll")]
        static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")]
        static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetWindowTextLength(IntPtr hwnd);
        [DllImport("user32.dll")]
        static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

        const uint GW_OWNER = 4;
        const uint WM_CLOSE = 0x0010;

        // The windows a person would see on the taskbar for these processes: visible, top-level,
        // not owned by another window, and with a title.
        static List<IntPtr> AppWindows(int[] pids)
        {
            HashSet<int> set = new HashSet<int>(pids);
            List<IntPtr> found = new List<IntPtr>();
            EnumWindows(delegate (IntPtr hwnd, IntPtr lParam)
            {
                int pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (set.Contains(pid) && IsWindowVisible(hwnd) && GetWindow(hwnd, GW_OWNER) == IntPtr.Zero && GetWindowTextLength(hwnd) > 0) found.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static int WindowCount(int[] pids) { return AppWindows(pids).Count; }

        // Closes every window of an app the way its X button does: the app gets the chance to
        // ask about unsaved work. Returns how many windows were asked to close.
        public static int CloseWindows(int[] pids)
        {
            List<IntPtr> windows = AppWindows(pids);
            foreach (IntPtr hwnd in windows) PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            return windows.Count;
        }
    }

    // One app in the list of apps that can be closed (all its processes together).
    public class AppRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Changed(string name) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        bool _selected;
        public bool Selected { get { return _selected; } set { if (_selected == value) return; _selected = value; Changed("Selected"); } }
        string _status = "";
        public string Status { get { return _status; } set { if (_status == value) return; _status = value; Changed("Status"); } }
        string _statusColor = "#64748B";
        public string StatusColor { get { return _statusColor; } set { if (_statusColor == value) return; _statusColor = value; Changed("StatusColor"); } }

        public string Name { get; set; }
        public string Detail { get; set; }
        public string MemoryText { get; set; }
        public double BarWidth { get; set; }
        public object Icon { get; set; }
        public string Path { get; set; }
        public long Bytes;
        public int[] Pids = new int[0];
        public int Windows;
        public DateTime CloseStarted;
        public bool Forced;
    }

    // One app that can start with Windows. Enabled is bound to the tick box.
    public class StartupRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Changed(string name) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        bool _enabled;
        public bool Enabled { get { return _enabled; } set { if (_enabled == value) return; _enabled = value; Changed("Enabled"); } }

        public string Name { get; set; }
        public string Detail { get; set; }
        public string Badge { get; set; }
        public object Icon { get; set; }
        public bool WasEnabled;
        public bool NeedsAdmin;
        public string Hive = "HKCU";          // where its on/off switch lives: HKCU or HKLM
        public string ApprovedKey = "";       // ...\Explorer\StartupApproved\Run, Run32 or StartupFolder
        public string ValueName = "";
        public string Path = "";
    }
}
