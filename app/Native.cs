// Native helpers for the Smart Transfer app. Compiled at start-up by Add-Type
// (Windows PowerShell 5.1 uses the C# 5 compiler, so no newer syntax here).

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace IPhoneTransferApp
{
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        [PreserveSig] int BindToHandler(IntPtr pbc, [In] ref Guid bhid, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
        [PreserveSig] int GetParent(out IShellItem ppsi);
        [PreserveSig] int GetDisplayName(uint sigdnName, out IntPtr ppszName);
        [PreserveSig] int GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        [PreserveSig] int Compare(IShellItem psi, uint hint, out int piOrder);
    }

    // Method order must match shobjidl.h exactly.
    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOperation
    {
        uint Advise(IntPtr pfops);
        void Unadvise(uint dwCookie);
        void SetOperationFlags(uint dwOperationFlags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string pszMessage);
        void SetProgressDialog(IntPtr popd);
        void SetProperties(IntPtr pproparray);
        void SetOwnerWindow(IntPtr hwndOwner);
        void ApplyPropertiesToItem(IShellItem psiItem);
        void ApplyPropertiesToItems(IntPtr punkItems);
        void RenameItem(IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
        void RenameItems(IntPtr pUnkItems, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        void MoveItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
        void MoveItems(IntPtr punkItems, IShellItem psiDestinationFolder);
        void CopyItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszCopyName, IntPtr pfopsItem);
        void CopyItems(IntPtr punkItems, IShellItem psiDestinationFolder);
        void DeleteItem(IShellItem psiItem, IntPtr pfopsItem);
        void DeleteItems(IntPtr punkItems);
        uint NewItem(IShellItem psiDestinationFolder, uint dwFileAttributes, [MarshalAs(UnmanagedType.LPWStr)] string pszName, [MarshalAs(UnmanagedType.LPWStr)] string pszTemplateName, IntPtr pfopsItem);
        void PerformOperations();
        [return: MarshalAs(UnmanagedType.Bool)]
        bool GetAnyOperationsAborted();
    }

    public static class Native
    {
        static readonly Guid IID_IShellItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        static readonly Guid CLSID_FileOperation = new Guid("3ad05575-8857-4850-9277-11b85bdb8e09");

        const uint SFGAO_CANDELETE = 0x20;
        const uint FOF_SILENT = 0x4;
        const uint FOF_NOCONFIRMATION = 0x10;
        const uint FOF_ALLOWUNDO = 0x40;
        const uint FOF_NOERRORUI = 0x400;
        const uint FOF_WANTNUKEWARNING = 0x4000;
        const uint FOFX_EARLYFAILURE = 0x00100000;

        const uint ES_CONTINUOUS = 0x80000000;
        const uint ES_SYSTEM_REQUIRED = 0x00000001;

        [DllImport("shell32.dll", PreserveSig = false)]
        static extern IShellItem SHCreateItemFromIDList(IntPtr pidl, [In] ref Guid riid);

        [DllImport("shell32.dll", PreserveSig = false)]
        static extern IntPtr SHGetIDListFromObject([MarshalAs(UnmanagedType.IUnknown)] object punk);

        [DllImport("ole32.dll")]
        static extern void CoTaskMemFree(IntPtr p);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);

        [DllImport("kernel32.dll")]
        static extern uint SetThreadExecutionState(uint esFlags);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

        // Gives the window its own taskbar button and icon instead of PowerShell's.
        public static void SetAppId(string appId)
        {
            try { SetCurrentProcessExplicitAppUserModelID(appId); } catch (Exception) { }
        }

        public static IShellItem ItemFromObject(object folderItem)
        {
            IntPtr pidl = SHGetIDListFromObject(folderItem);
            try
            {
                Guid iid = IID_IShellItem;
                return SHCreateItemFromIDList(pidl, ref iid);
            }
            finally { CoTaskMemFree(pidl); }
        }

        // Bytes free for the current user, or -1 when the path cannot be asked.
        public static long GetFreeBytes(string path)
        {
            ulong free, total, totalFree;
            if (!GetDiskFreeSpaceEx(path, out free, out total, out totalFree)) return -1;
            return (long)free;
        }

        public static long GetTotalBytes(string path)
        {
            ulong free, total, totalFree;
            if (!GetDiskFreeSpaceEx(path, out free, out total, out totalFree)) return -1;
            return (long)total;
        }

        // Stops the PC from going to sleep while a long copy runs. Applies to the calling
        // thread, so call it from the thread doing the work, and switch it off again.
        public static void KeepAwake(bool on)
        {
            if (on) SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
            else SetThreadExecutionState(ES_CONTINUOUS);
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
            public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION info);

        static bool TryGetFileId(string path, out string id)
        {
            id = null;
            try
            {
                using (System.IO.FileStream fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read,
                           System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
                {
                    BY_HANDLE_FILE_INFORMATION info;
                    if (!GetFileInformationByHandle(fs.SafeFileHandle, out info)) return false;
                    id = string.Format("{0:X8}-{1:X8}{2:X8}", info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow);
                    return true;
                }
            }
            catch (Exception) { return false; }
        }

        // True when two paths lead to the very same file on disk - also through junctions,
        // SUBST drives, mapped drives, UNC paths and hard links. Unknown counts as "same",
        // because the caller uses this to refuse a delete.
        public static bool IsSameFile(string a, string b)
        {
            if (string.Equals(System.IO.Path.GetFullPath(a), System.IO.Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase)) return true;
            string ia, ib;
            if (!TryGetFileId(a, out ia) || !TryGetFileId(b, out ib)) return true;
            return ia == ib;
        }

        public static bool CanDelete(object folderItem)
        {
            IShellItem item = ItemFromObject(folderItem);
            try
            {
                uint attributes;
                if (item.GetAttributes(SFGAO_CANDELETE, out attributes) < 0) return false;
                return (attributes & SFGAO_CANDELETE) != 0;
            }
            finally { Marshal.ReleaseComObject(item); }
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern IShellItem SHCreateItemFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string pszPath, IntPtr pbc, [In] ref Guid riid);

        // Deletes one shell item without any dialog. Throws when the shell refuses or aborts.
        // allowUndo sends ordinary files to the Recycle Bin; a phone has no Recycle Bin.
        public static void DeleteItem(object folderItem, bool allowUndo)
        {
            Delete(ItemFromObject(folderItem), allowUndo);
        }

        // The same for a file on the PC, by its path.
        public static void DeletePath(string path, bool allowUndo)
        {
            Guid iid = IID_IShellItem;
            Delete(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid), allowUndo);
        }

        // Several files or folders in one go, without dialogs - except Windows' own warning when
        // one is too big for the Recycle Bin and would be destroyed instead. Items that fail are
        // left alone: the caller looks at what is still there.
        public static void DeletePaths(string[] paths, bool allowUndo)
        {
            IFileOperation op = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_FileOperation));
            System.Collections.Generic.List<IShellItem> items = new System.Collections.Generic.List<IShellItem>();
            try
            {
                uint flags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI;
                if (allowUndo) flags |= FOF_ALLOWUNDO | FOF_WANTNUKEWARNING;
                op.SetOperationFlags(flags);
                Guid iid = IID_IShellItem;
                foreach (string path in paths)
                {
                    IShellItem item;
                    try { item = SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid); }
                    catch (Exception) { continue; }
                    items.Add(item);
                    op.DeleteItem(item, IntPtr.Zero);
                }
                if (items.Count > 0) { try { op.PerformOperations(); } catch (Exception) { } }
            }
            finally
            {
                Marshal.ReleaseComObject(op);
                foreach (IShellItem item in items) Marshal.ReleaseComObject(item);
            }
        }

        static void Delete(IShellItem item, bool allowUndo)
        {
            IFileOperation op = null;
            try
            {
                op = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_FileOperation));
                uint flags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOFX_EARLYFAILURE;
                if (allowUndo) flags |= FOF_ALLOWUNDO;
                op.SetOperationFlags(flags);
                op.DeleteItem(item, IntPtr.Zero);
                op.PerformOperations();
                if (op.GetAnyOperationsAborted()) throw new InvalidOperationException("Windows refused or cancelled the delete.");
            }
            finally
            {
                if (op != null) Marshal.ReleaseComObject(op);
                Marshal.ReleaseComObject(item);
            }
        }
    }

    // The byte stream Explorer itself reads when it copies a file off the phone.
    public sealed class ItemStream : IDisposable
    {
        static readonly Guid BHID_Stream = new Guid("1CEBB3AB-7C10-499a-A417-92CA16C4CB83");
        static readonly Guid IID_IStream = new Guid("0000000c-0000-0000-C000-000000000046");

        IStream _stream;
        IntPtr _pRead = IntPtr.Zero;
        public long Length = -1;

        public static ItemStream Open(object folderItem)
        {
            IShellItem item = Native.ItemFromObject(folderItem);
            try
            {
                Guid bhid = BHID_Stream;
                Guid iid = IID_IStream;
                object o;
                int hr = item.BindToHandler(IntPtr.Zero, ref bhid, ref iid, out o);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                ItemStream s = new ItemStream();
                s._stream = (IStream)o;
                s._pRead = Marshal.AllocHGlobal(8);
                try
                {
                    System.Runtime.InteropServices.ComTypes.STATSTG st;
                    s._stream.Stat(out st, 1 /* STATFLAG_NONAME */);
                    s.Length = st.cbSize;
                }
                catch (Exception) { s.Length = -1; }
                return s;
            }
            finally { Marshal.ReleaseComObject(item); }
        }

        public int Read(byte[] buffer, int count)
        {
            Marshal.WriteInt32(_pRead, 0);
            _stream.Read(buffer, count, _pRead);
            return Marshal.ReadInt32(_pRead);
        }

        public void Dispose()
        {
            if (_stream != null) { try { Marshal.ReleaseComObject(_stream); } catch (Exception) { } _stream = null; }
            if (_pRead != IntPtr.Zero) { Marshal.FreeHGlobal(_pRead); _pRead = IntPtr.Zero; }
        }
    }

    // One row in the folder lists. Change notification lets the window update in place.
    public class Row : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Set<T>(ref T field, T value, string name)
        {
            if (object.Equals(field, value)) return;
            field = value;
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }

        string _name = ""; public string Name { get { return _name; } set { Set(ref _name, value, "Name"); } }
        bool _selected; public bool Selected { get { return _selected; } set { Set(ref _selected, value, "Selected"); } }
        bool _canSelect = true; public bool CanSelect { get { return _canSelect; } set { Set(ref _canSelect, value, "CanSelect"); } }
        string _dates = ""; public string Dates { get { return _dates; } set { Set(ref _dates, value, "Dates"); } }
        string _files = ""; public string Files { get { return _files; } set { Set(ref _files, value, "Files"); } }
        string _photos = ""; public string Photos { get { return _photos; } set { Set(ref _photos, value, "Photos"); } }
        string _videos = ""; public string Videos { get { return _videos; } set { Set(ref _videos, value, "Videos"); } }
        string _other = ""; public string Other { get { return _other; } set { Set(ref _other, value, "Other"); } }
        string _size = ""; public string Size { get { return _size; } set { Set(ref _size, value, "Size"); } }
        string _status = ""; public string Status { get { return _status; } set { Set(ref _status, value, "Status"); } }
        string _statusColor = "#64748B"; public string StatusColor { get { return _statusColor; } set { Set(ref _statusColor, value, "StatusColor"); } }
        string _note = ""; public string Note { get { return _note; } set { Set(ref _note, value, "Note"); } }
        string _phone = ""; public string Phone { get { return _phone; } set { Set(ref _phone, value, "Phone"); } }
        string _laptop = ""; public string Laptop { get { return _laptop; } set { Set(ref _laptop, value, "Laptop"); } }
        double _percent; public double Percent { get { return _percent; } set { Set(ref _percent, value, "Percent"); } }
        string _types = ""; public string Types { get { return _types; } set { Set(ref _types, value, "Types"); } }

        // Plain numbers for the window's own arithmetic (not shown directly).
        public long Bytes;
        public long FileCount;
        public long BytesToCopy;
        public long FilesToCopy;
        public long PresentFiles;
        public bool Scanned;
        public bool Recommended;
        public bool Verified;
        public string Sort = "";
    }
}
