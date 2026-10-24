// The heavy lifting of Smart Cleanup. Compiled at start-up by Add-Type together with Native.cs
// (Windows PowerShell 5.1 uses the C# 5 compiler, so no newer syntax here). Each job runs on
// its own thread; the window reads the public progress fields a few times a second.
//
//   Analyzer   walks the chosen folders once and sorts what it finds into suggestions
//   Cleaner    removes what was picked - checking every file again just before it goes
//   Organizer  sorts the loose files of a folder into sub-folders, and can undo that
//
// The rules that protect your files:
//   - nothing in Windows, program folders, app data, hidden system folders or software
//     projects (.git, node_modules ...) is ever suggested
//   - files that only live in the cloud (OneDrive "online-only") are never opened or counted
//   - duplicates are proven byte for byte (SHA-256); one copy of each always stays, and
//     both are read again right before the extra copy is removed
//   - a file that changed after the analysis is left alone
//   - removed files go to the Recycle Bin; only temporary files and the Recycle Bin itself
//     are gone for good

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace SmartCleanup
{
    // One suggested file or folder. Selected is bound to a tick box in the window.
    public class Item : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Changed(string name) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        bool _selected;
        public bool Selected { get { return _selected; } set { if (_selected == value) return; _selected = value; Changed("Selected"); } }
        string _status = "";
        public string Status { get { return _status; } set { if (_status == value) return; _status = value; Changed("Status"); } }

        public string Category { get; set; }
        public string Path { get; set; }
        public string Name { get; set; }
        public string Folder { get; set; }
        public long Size { get; set; }
        public string SizeText { get; set; }
        public DateTime Modified { get; set; }
        public string DateText { get; set; }
        public string Reason { get; set; }
        public bool IsFolder { get; set; }
        public bool IsRecycleBin { get; set; }
        public bool Permanent { get; set; }     // no Recycle Bin for it: temporary files, drives without one
        public string KeepPath { get; set; }    // duplicates: the copy that stays
        public string Hash { get; set; }
    }

    public class Category
    {
        public string Key = "";
        public string Title = "";
        public string Text = "";
        public string Icon = "";
        public bool Recommended;
        public bool CanToggleAll = true;      // false: too personal to tick all at once (very large files)
        public bool Permanent;
        public List<Item> Items = new List<Item>();

        public long TotalBytes { get { long n = 0; foreach (Item i in Items) n += i.Size; return n; } }
        public long SelectedBytes { get { long n = 0; foreach (Item i in Items) if (i.Selected) n += i.Size; return n; } }
        public int SelectedCount { get { int n = 0; foreach (Item i in Items) if (i.Selected) n++; return n; } }
    }

    // Where the space goes: one bar per folder.
    public class Usage
    {
        public string Name { get; set; }
        public string Path { get; set; }
        public long Bytes { get; set; }
        public long Files { get; set; }
        public bool System { get; set; }
    }

    public static class Fmt
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public static string Bytes(double bytes)
        {
            if (bytes < 1024) return ((long)bytes).ToString(Inv) + " B";
            string[] units = { "KB", "MB", "GB", "TB" };
            double v = bytes;
            for (int i = 0; i < units.Length; i++)
            {
                v /= 1024;
                if (v < 1024 || i == units.Length - 1) return v.ToString("N1", Inv) + " " + units[i];
            }
            return "";
        }

        public static string Age(DateTime when)
        {
            double days = (DateTime.Now - when).TotalDays;
            if (days < 60) return Plural((int)Math.Max(1, days), "day");
            if (days < 730) return Plural((int)(days / 30.4), "month");
            return Plural((int)(days / 365.25), "year");
        }

        static string Plural(int n, string unit) { return n.ToString(Inv) + " " + unit + (n == 1 ? "" : "s"); }

        public static string Date(DateTime when) { return when.ToString("d MMM yyyy", Inv); }
    }

    static class Hasher
    {
        public static string Full(string path, ref long counter, Func<bool> cancelled)
        {
            byte[] buffer = new byte[1024 * 1024];
            using (SHA256 sha = SHA256.Create())
            using (FileStream s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.SequentialScan))
            {
                int n;
                while ((n = s.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (cancelled()) throw new OperationCanceledException();
                    sha.TransformBlock(buffer, 0, n, null, 0);
                    counter += n;
                }
                sha.TransformFinalBlock(buffer, 0, 0);
                return BitConverter.ToString(sha.Hash).Replace("-", "");
            }
        }

        // The first and last 64 KB: cheap, and different files almost always differ there.
        public static string Quick(string path, long size)
        {
            const int part = 64 * 1024;
            using (SHA256 sha = SHA256.Create())
            using (FileStream s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                byte[] buffer = new byte[part];
                int n = s.Read(buffer, 0, part);
                sha.TransformBlock(buffer, 0, n, null, 0);
                if (size > 2 * part)
                {
                    s.Seek(-part, SeekOrigin.End);
                    n = s.Read(buffer, 0, part);
                    sha.TransformBlock(buffer, 0, n, null, 0);
                }
                sha.TransformFinalBlock(buffer, 0, 0);
                return BitConverter.ToString(sha.Hash).Replace("-", "");
            }
        }
    }

    public static class RecycleBin
    {
        [StructLayout(LayoutKind.Sequential)]
        struct Info64 { public int cbSize; public long i64Size; public long i64NumItems; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct Info32 { public int cbSize; public long i64Size; public long i64NumItems; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
        static extern int Query64(string root, ref Info64 info);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
        static extern int Query32(string root, ref Info32 info);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHEmptyRecycleBinW")]
        static extern int Empty(IntPtr hwnd, string root, uint flags);

        // Bytes and items in one drive's Recycle Bin, or -1 when it cannot be asked.
        public static long[] Size(string root)
        {
            if (IntPtr.Size == 8)
            {
                Info64 i = new Info64(); i.cbSize = Marshal.SizeOf(typeof(Info64));
                if (Query64(root, ref i) != 0) return new long[] { -1, -1 };
                return new long[] { i.i64Size, i.i64NumItems };
            }
            Info32 j = new Info32(); j.cbSize = Marshal.SizeOf(typeof(Info32));
            if (Query32(root, ref j) != 0) return new long[] { -1, -1 };
            return new long[] { j.i64Size, j.i64NumItems };
        }

        public static void EmptyBin(string root)
        {
            const uint SHERB_NOCONFIRMATION = 1, SHERB_NOPROGRESSUI = 2, SHERB_NOSOUND = 4;
            Empty(IntPtr.Zero, root, SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
        }
    }

    public class Analyzer
    {
        // what to look at (set before Start)
        public List<string> Roots = new List<string>();
        public string Downloads = "";
        public string Desktop = "";
        public List<string> TempRoots = new List<string>();       // temp folders to offer (only for the system drive)
        public List<string> RecycleDrives = new List<string>();   // drives whose Recycle Bin is offered
        public List<string> ProtectedRoots = new List<string>();  // never suggested: Windows, programs, app data
        public List<string> PermanentDrives = new List<string>(); // drives without a Recycle Bin (USB, network)
        public List<string> KeepFolders = new List<string>();     // folders never offered as empty (the user's own folders)

        // live progress
        public volatile string Phase = "";
        public volatile string Current = "";
        public long Files, Bytes, Folders, Denied, HashDone, HashTotal;
        public volatile bool Cancel, Done;
        public string Error = "";

        // results
        public List<Usage> Usage = new List<Usage>();
        public List<Category> Categories = new List<Category>();
        public long OnlineOnlyBytes;
        public long OnlineOnlyFiles;

        const long DupeMin = 256L * 1024;
        const long LargeMin = 500L * 1024 * 1024;
        const FileAttributes HiddenSystem = FileAttributes.Hidden | FileAttributes.System;
        const FileAttributes OnlineOnly = (FileAttributes)0x00400000 | (FileAttributes)0x00040000 | FileAttributes.Offline;

        static readonly HashSet<string> ProtectedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "node_modules", "__pycache__", "venv", "site-packages", "bower_components", "vendor", "packages",
            "System Volume Information", "Recovery", "Windows.old", "PerfLogs", "MSOCache", "Config.Msi", "OneDriveTemp" };
        static readonly HashSet<string> KeepEmptyNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "Camera Roll", "Saved Pictures", "Screenshots", "Captures", "Custom Office Templates", "My Shapes",
            "OneNote Notebooks", "Feedback", "Zoom", "WindowsPowerShell" };
        static readonly HashSet<string> Installers = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            ".exe", ".msi", ".msix", ".msixbundle", ".appx", ".appxbundle", ".iso", ".dmg", ".pkg", ".apk" };
        static readonly HashSet<string> Partial = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            ".crdownload", ".part", ".partial", ".download", ".opdownload" };
        // Endings that mark a copy: "(1)", " - Copy", "_copy", and "_1" / "_12" as copy tools add -
        // but not the 4-digit counter of a camera name like IMG_1001.
        static readonly Regex CopyName = new Regex(@"(\(\d+\)|\s-\s[Cc]opy(\s\(\d+\))?|[ _-][Cc]opy|_\d{1,2})$");

        class Cand { public string Path; public long Size; public DateTime Modified; }

        Dictionary<string, List<Cand>> bySize = new Dictionary<string, List<Cand>>();
        List<Cand> large = new List<Cand>();
        List<Cand> oldDownloads = new List<Cand>();
        List<string> emptyDirs = new List<string>();
        HashSet<string> claimed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, Category> byKey = new Dictionary<string, Category>();
        DateTime now = DateTime.Now;

        public void Start()
        {
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        bool Cancelled() { return Cancel; }

        void Run()
        {
            try
            {
                MakeCategories();
                Phase = "Looking at every folder";
                foreach (string root in Roots)
                {
                    DirectoryInfo dir = new DirectoryInfo(root);
                    if (!dir.Exists) continue;
                    if (Roots.Count > 1)
                    {
                        Usage u = new Usage { Name = dir.Name, Path = dir.FullName };
                        Usage.Add(u);
                        Walk(dir, IsProtected(dir, true), u, null, true);
                    }
                    else Walk(dir, false, null, dir, true);
                }
                Phase = "Looking at the temporary files";
                foreach (string temp in TempRoots) WalkTemp(new DirectoryInfo(temp));
                Phase = "Looking at the Recycle Bin";
                foreach (string drive in RecycleDrives) AddRecycleBin(drive);
                Phase = "Finding duplicate files";
                FindDuplicates();
                Phase = "Putting it together";
                Finish();
                Phase = "Done";
            }
            catch (OperationCanceledException) { Phase = "Stopped"; }
            catch (Exception e) { Error = e.Message; }
            finally { Done = true; }
        }

        void MakeCategories()
        {
            Add(new Category { Key = "duplicates", Title = "Duplicate files", Icon = "\uE8C8", Recommended = true,
                Text = "Exact copies of files you already have - checked byte for byte. One copy of each always stays." });
            Add(new Category { Key = "junk", Title = "Leftover junk", Icon = "\uE8CD", Recommended = true,
                Text = "Downloads that never finished, temporary and lock files programs left behind, picture preview caches." });
            Add(new Category { Key = "temp", Title = "Temporary files", Icon = "\uE916", Recommended = true, Permanent = true,
                Text = "Files programs left in the Windows temp folders more than 2 days ago. Removed for good - nothing needs them." });
            Add(new Category { Key = "installers", Title = "Old installers", Icon = "\uE896", Recommended = true,
                Text = "Setup files in Downloads older than a month. The programs stay installed, and you can download them again." });
            Add(new Category { Key = "empty", Title = "Empty folders", Icon = "\uF12B", Recommended = true,
                Text = "Folders with nothing in them at all." });
            Add(new Category { Key = "downloads", Title = "Old downloads", Icon = "\uE787",
                Text = "Files in Downloads nobody touched for more than 3 months. Have a look before removing them." });
            Add(new Category { Key = "large", Title = "Very large files", Icon = "\uEDA2", CanToggleAll = false,
                Text = "Your biggest files (500 MB and more). Only remove what you are sure you no longer need." });
            Add(new Category { Key = "recycle", Title = "Recycle Bin", Icon = "\uE74D", Permanent = true,
                Text = "Files you deleted earlier. Emptying it gives their space back - they cannot be put back afterwards." });
        }

        void Add(Category c) { Categories.Add(c); byKey[c.Key] = c; }

        bool StartsWithFolder(string path, string folder)
        {
            if (string.IsNullOrEmpty(folder)) return false;
            string f = folder.TrimEnd('\\') + "\\";
            return path.StartsWith(f, StringComparison.OrdinalIgnoreCase) || path.Equals(folder.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }

        bool IsProtected(DirectoryInfo d, bool isRoot)
        {
            string name = d.Name;
            if (!isRoot)
            {
                if (name.StartsWith(".") || name.StartsWith("$")) return true;
                if (ProtectedNames.Contains(name)) return true;
                if ((d.Attributes & HiddenSystem) == HiddenSystem) return true;
            }
            foreach (string r in ProtectedRoots) if (StartsWithFolder(d.FullName, r)) return true;
            return false;
        }

        // Returns true when the folder holds anything (or might: unreadable, protected, linked).
        bool Walk(DirectoryInfo dir, bool isProtected, Usage bucket, DirectoryInfo bucketParent, bool isRoot)
        {
            if (Cancel) throw new OperationCanceledException();
            Folders++;
            Current = dir.FullName;
            FileSystemInfo[] entries;
            try { entries = dir.GetFileSystemInfos(); }
            catch (Exception) { Denied++; return true; }
            bool content = false;
            Usage rootFiles = null;
            foreach (FileSystemInfo e in entries)
            {
                FileAttributes a;
                try { a = e.Attributes; } catch (Exception) { content = true; continue; }
                if ((a & FileAttributes.Directory) != 0)
                {
                    if ((a & FileAttributes.ReparsePoint) != 0) { content = true; continue; }
                    DirectoryInfo sub = (DirectoryInfo)e;
                    bool prot = isProtected || IsProtected(sub, false);
                    Usage b = bucket;
                    if (bucketParent != null && isRoot)
                    {
                        b = new Usage { Name = sub.Name, Path = sub.FullName, System = prot };
                        Usage.Add(b);
                    }
                    if (Walk(sub, prot, b, null, false)) content = true;
                    continue;
                }
                content = true;
                FileInfo f = (FileInfo)e;
                long len;
                try { len = f.Length; } catch (Exception) { continue; }
                if ((a & OnlineOnly) != 0) { OnlineOnlyFiles++; OnlineOnlyBytes += len; continue; }
                Files++;
                Bytes += len;
                Usage target = bucket;
                if (target == null && bucketParent != null)
                {
                    if (rootFiles == null) { rootFiles = new Usage { Name = "Files directly in " + dir.Name, Path = dir.FullName }; Usage.Add(rootFiles); }
                    target = rootFiles;
                }
                if (target != null) { target.Bytes += len; target.Files++; }
                if (isProtected || (a & HiddenSystem) == HiddenSystem) continue;
                Consider(f, len);
            }
            if (!content)
            {
                // Empty. A protected or well-known folder still counts as something, so the
                // folder around it is never offered as empty either.
                if (isProtected || isRoot || KeepEmptyNames.Contains(dir.Name) || IsKeepFolder(dir.FullName)) return true;
                emptyDirs.Add(dir.FullName);
            }
            return content;
        }

        bool IsKeepFolder(string path)
        {
            foreach (string k in KeepFolders)
            {
                if (path.Equals(k.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return true;
                // the folders right inside the user profile (Contacts, Links, Saved Games ...)
                string parent = System.IO.Path.GetDirectoryName(path);
                if (parent != null && parent.Equals(k.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) && k.EndsWith("\\")) return true;
            }
            return false;
        }

        void Consider(FileInfo f, long len)
        {
            string name = f.Name;
            string ext = f.Extension;
            DateTime mod = f.LastWriteTime;
            double age = (now - mod).TotalDays;
            string junk = null;
            if (name.StartsWith("~$") && len < 1024 * 1024 && age > 1) junk = "Lock file an Office program left behind";
            else if (Partial.Contains(ext) && age > 7) junk = "Download that never finished";
            else if (ext.Equals(".tmp", StringComparison.OrdinalIgnoreCase) && age > 7) junk = "Temporary file";
            else if (name.Equals("Thumbs.db", StringComparison.OrdinalIgnoreCase) || name.Equals("ehthumbs.db", StringComparison.OrdinalIgnoreCase)) junk = "Picture preview cache - Windows makes it again when needed";
            if (junk != null) { AddItem("junk", f.FullName, len, mod, junk); return; }

            bool inDownloads = StartsWithFolder(f.FullName, Downloads);
            if (inDownloads && Installers.Contains(ext) && age > 30) { AddItem("installers", f.FullName, len, mod, "Setup file, downloaded " + Fmt.Age(mod) + " ago"); return; }

            Cand c = new Cand { Path = f.FullName, Size = len, Modified = mod };
            if (len >= DupeMin)
            {
                string key = System.IO.Path.GetPathRoot(f.FullName).ToUpperInvariant() + "|" + len.ToString(CultureInfo.InvariantCulture);
                List<Cand> list;
                if (!bySize.TryGetValue(key, out list)) { list = new List<Cand>(); bySize[key] = list; }
                list.Add(c);
            }
            if (len >= LargeMin) large.Add(c);
            if (inDownloads && age > 90) oldDownloads.Add(c);
        }

        Item AddItem(string category, string path, long size, DateTime modified, string reason)
        {
            Category cat = byKey[category];
            Item i = new Item
            {
                Category = category, Path = path, Name = System.IO.Path.GetFileName(path), Folder = System.IO.Path.GetDirectoryName(path),
                Size = size, SizeText = Fmt.Bytes(size), Modified = modified, DateText = Fmt.Date(modified), Reason = reason,
                Selected = cat.Recommended, Permanent = cat.Permanent || OnPermanentDrive(path)
            };
            cat.Items.Add(i);
            claimed.Add(path);
            return i;
        }

        bool OnPermanentDrive(string path)
        {
            foreach (string d in PermanentDrives) if (StartsWithFolder(path, d)) return true;
            return false;
        }

        void WalkTemp(DirectoryInfo dir)
        {
            if (Cancel) throw new OperationCanceledException();
            Current = dir.FullName;
            FileSystemInfo[] entries;
            try { entries = dir.GetFileSystemInfos(); }
            catch (Exception) { return; }
            foreach (FileSystemInfo e in entries)
            {
                FileAttributes a;
                try { a = e.Attributes; } catch (Exception) { continue; }
                if ((a & FileAttributes.ReparsePoint) != 0) continue;
                if ((a & FileAttributes.Directory) != 0) { WalkTemp((DirectoryInfo)e); continue; }
                FileInfo f = (FileInfo)e;
                try
                {
                    if ((now - f.LastWriteTime).TotalDays < 2) continue;   // a program may still be using it
                    Files++;
                    Bytes += f.Length;
                    Item i = AddItem("temp", f.FullName, f.Length, f.LastWriteTime, "Left in " + dir.FullName);
                    i.Permanent = true;
                }
                catch (Exception) { }
            }
        }

        void AddRecycleBin(string drive)
        {
            long[] s = RecycleBin.Size(drive);
            if (s[0] <= 0) return;
            Item i = AddItem("recycle", drive, s[0], now, s[1].ToString("N0", CultureInfo.InvariantCulture) + " items you deleted earlier");
            i.Name = "Recycle Bin on " + drive.TrimEnd('\\');
            i.Folder = drive;
            i.DateText = "";
            i.IsRecycleBin = true;
            i.Permanent = true;
        }

        void FindDuplicates()
        {
            // Same drive and same size first (free), then the first and last 64 KB, then the
            // whole file. Only files that match completely count as duplicates.
            List<List<Cand>> sameQuick = new List<List<Cand>>();
            foreach (List<Cand> group in bySize.Values)
            {
                if (Cancel) throw new OperationCanceledException();
                List<Cand> open = group.FindAll(c => !claimed.Contains(c.Path));
                if (open.Count < 2) continue;
                Dictionary<string, List<Cand>> byQuick = new Dictionary<string, List<Cand>>();
                foreach (Cand c in open)
                {
                    Current = c.Path;
                    string q;
                    try { q = Hasher.Quick(c.Path, c.Size); } catch (Exception) { continue; }
                    List<Cand> l;
                    if (!byQuick.TryGetValue(q, out l)) { l = new List<Cand>(); byQuick[q] = l; }
                    l.Add(c);
                }
                foreach (List<Cand> l in byQuick.Values) if (l.Count > 1) sameQuick.Add(l);
            }
            HashTotal = 0;
            foreach (List<Cand> l in sameQuick) foreach (Cand c in l) HashTotal += c.Size;

            int groupNo = 0;
            foreach (List<Cand> l in sameQuick)
            {
                Dictionary<string, List<Cand>> byFull = new Dictionary<string, List<Cand>>();
                foreach (Cand c in l)
                {
                    Current = c.Path;
                    string h;
                    long before = HashDone;
                    try { h = Hasher.Full(c.Path, ref HashDone, Cancelled); }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception) { HashDone = before + c.Size; continue; }
                    List<Cand> same;
                    if (!byFull.TryGetValue(h, out same)) { same = new List<Cand>(); byFull[h] = same; }
                    same.Add(c);
                }
                foreach (KeyValuePair<string, List<Cand>> kv in byFull)
                {
                    if (kv.Value.Count < 2) continue;
                    groupNo++;
                    List<Cand> copies = kv.Value;
                    copies.Sort(CompareKeep);
                    Cand keep = copies[0];
                    claimed.Add(keep.Path);   // the copy that stays is never offered anywhere else
                    for (int i = 1; i < copies.Count; i++)
                    {
                        Item item = AddItem("duplicates", copies[i].Path, copies[i].Size, copies[i].Modified, "Same as " + keep.Path);
                        item.KeepPath = keep.Path;
                        item.Hash = kv.Key;
                    }
                }
            }
        }

        // Which copy stays: not the one in Downloads or on the Desktop, not the one named
        // "copy" or "(1)", then the oldest, then the one with the shorter path.
        int KeepScore(Cand c)
        {
            int s = 0;
            if (StartsWithFolder(c.Path, Downloads)) s += 4;
            if (StartsWithFolder(c.Path, Desktop)) s += 2;
            if (CopyName.IsMatch(System.IO.Path.GetFileNameWithoutExtension(c.Path))) s += 3;
            return s;
        }

        int CompareKeep(Cand a, Cand b)
        {
            int d = KeepScore(a).CompareTo(KeepScore(b));
            if (d != 0) return d;
            d = a.Modified.CompareTo(b.Modified);
            if (d != 0) return d;
            return a.Path.Length.CompareTo(b.Path.Length);
        }

        void Finish()
        {
            large.Sort((a, b) => b.Size.CompareTo(a.Size));
            int n = 0;
            foreach (Cand c in large)
            {
                if (claimed.Contains(c.Path)) continue;
                AddItem("large", c.Path, c.Size, c.Modified, "Last changed " + Fmt.Date(c.Modified));
                if (++n >= 100) break;
            }
            oldDownloads.Sort((a, b) => b.Size.CompareTo(a.Size));
            foreach (Cand c in oldDownloads)
            {
                if (claimed.Contains(c.Path)) continue;
                AddItem("downloads", c.Path, c.Size, c.Modified, "Not touched for " + Fmt.Age(c.Modified));
            }
            // Only the outermost of nested empty folders: removing it removes the ones inside.
            HashSet<string> set = new HashSet<string>(emptyDirs, StringComparer.OrdinalIgnoreCase);
            foreach (string d in emptyDirs)
            {
                string parent = System.IO.Path.GetDirectoryName(d);
                if (parent != null && set.Contains(parent)) continue;
                Item i = AddItem("empty", d, 0, now, "Empty folder");
                i.IsFolder = true;
                try { i.Modified = Directory.GetLastWriteTime(d); i.DateText = Fmt.Date(i.Modified); } catch (Exception) { }
            }
            foreach (Category c in Categories) c.Items.Sort((a, b) => b.Size.CompareTo(a.Size));
            Usage.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
        }
    }

    public class Cleaner
    {
        public List<Item> Items = new List<Item>();
        public bool NoRecycle;                 // test runs: remove the test files for good
        public volatile bool Cancel, Done;
        public volatile string Current = "";
        public long DoneCount, DoneBytes, Total, TotalBytes;
        public long Recycled, Freed;           // bytes: now in the Recycle Bin / gone for good
        public string Error = "";
        // per category: removed, bytes, kept because they changed, failed
        public Dictionary<string, long[]> Results = new Dictionary<string, long[]>();

        public void Start()
        {
            foreach (Item i in Items) { Total++; TotalBytes += i.Size; }
            Thread t = new Thread(Run);
            t.SetApartmentState(ApartmentState.STA);   // the shell's delete wants a single-threaded apartment
            t.IsBackground = true;
            t.Start();
        }

        bool Cancelled() { return Cancel; }

        long[] R(string category)
        {
            long[] r;
            if (!Results.TryGetValue(category, out r)) { r = new long[4]; Results[category] = r; }
            return r;
        }

        void Run()
        {
            try
            {
                // 1. The Recycle Bin first - so what is removed next can still be put back.
                foreach (Item i in Items)
                {
                    if (!i.IsRecycleBin) continue;
                    if (Cancel) throw new OperationCanceledException();
                    Current = i.Name;
                    long before = RecycleBin.Size(i.Path)[0];
                    RecycleBin.EmptyBin(i.Path);
                    long after = RecycleBin.Size(i.Path)[0];
                    long gone = Math.Max(0, before - Math.Max(0, after));
                    Freed += gone;
                    long[] r = R(i.Category); r[0]++; r[1] += gone;
                    i.Status = "Emptied";
                    Step(i);
                }
                // 2. Files, checked one by one, then removed in small batches.
                List<Item> batch = new List<Item>();
                Dictionary<string, string> keeperHash = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (Item i in Items)
                {
                    if (i.IsRecycleBin || i.IsFolder) continue;
                    if (Cancel) throw new OperationCanceledException();
                    Current = i.Path;
                    string why = Check(i, keeperHash);
                    if (why != null)
                    {
                        i.Status = "Kept: " + why;
                        R(i.Category)[2]++;
                        Step(i);
                        continue;
                    }
                    if (i.Permanent)
                    {
                        try { File.Delete(i.Path); } catch (Exception) { }
                        Settle(i, false);
                        continue;
                    }
                    batch.Add(i);
                    if (batch.Count >= 50) Flush(batch);
                }
                Flush(batch);
                // 3. Empty folders last: the files above may just have emptied more of them.
                foreach (Item i in Items)
                {
                    if (!i.IsFolder) continue;
                    if (Cancel) throw new OperationCanceledException();
                    Current = i.Path;
                    if (!Directory.Exists(i.Path)) { i.Status = "Already gone"; Step(i); continue; }
                    if (HasFiles(i.Path)) { i.Status = "Kept: not empty any more"; R(i.Category)[2]++; Step(i); continue; }
                    batch.Add(i);
                }
                Flush(batch);
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Error = e.Message; }
            finally { Done = true; }
        }

        // Why this file must stay, or null when it can go.
        string Check(Item i, Dictionary<string, string> keeperHash)
        {
            FileInfo f = new FileInfo(i.Path);
            if (!f.Exists) return "it is not there any more";
            if (f.Length != i.Size) return "it changed since the analysis";
            if (Math.Abs((f.LastWriteTime - i.Modified).TotalSeconds) > 2) return "it changed since the analysis";
            if (i.Category != "duplicates") return null;
            // A duplicate goes only while its twin is still there and both still match exactly.
            FileInfo keep = new FileInfo(i.KeepPath);
            if (!keep.Exists || keep.Length != i.Size) return "the copy that stays is not there any more";
            try
            {
                long ignore = 0;
                string kh;
                if (!keeperHash.TryGetValue(i.KeepPath, out kh)) { kh = Hasher.Full(i.KeepPath, ref ignore, Cancelled); keeperHash[i.KeepPath] = kh; }
                if (kh != i.Hash) return "the copy that stays changed";
                if (Hasher.Full(i.Path, ref ignore, Cancelled) != i.Hash) return "it changed since the analysis";
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { return "it could not be read"; }
            return null;
        }

        static bool HasFiles(string dir)
        {
            try { foreach (string f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)) return true; return false; }
            catch (Exception) { return true; }
        }

        void Flush(List<Item> batch)
        {
            if (batch.Count == 0) return;
            string[] paths = new string[batch.Count];
            for (int n = 0; n < batch.Count; n++) paths[n] = batch[n].Path;
            IPhoneTransferApp.Native.DeletePaths(paths, !NoRecycle);
            foreach (Item i in batch) Settle(i, !NoRecycle);
            batch.Clear();
        }

        void Settle(Item i, bool recycled)
        {
            bool gone = i.IsFolder ? !Directory.Exists(i.Path) : !File.Exists(i.Path);
            long[] r = R(i.Category);
            if (gone)
            {
                r[0]++; r[1] += i.Size;
                if (recycled) Recycled += i.Size; else Freed += i.Size;
                i.Status = recycled ? "In the Recycle Bin" : "Removed";
            }
            else { r[3]++; i.Status = "Could not be removed (in use?)"; }
            Step(i);
        }

        void Step(Item i) { DoneCount++; DoneBytes += i.Size; }
    }

    public class Move
    {
        public string From { get; set; }
        public string Group { get; set; }
        public string To { get; set; }
        public long Size { get; set; }
    }

    public class Group
    {
        public string Name { get; set; }
        public string Icon { get; set; }
        public long Files { get; set; }
        public long Bytes { get; set; }
        public string Examples { get; set; }
    }

    public class Organizer
    {
        public string Folder = "";
        public string Mode = "Type";            // Type, Date, TypeDate
        public List<Move> Moves = new List<Move>();
        public List<Group> Groups = new List<Group>();
        public int Skipped;
        public volatile bool Done;
        public volatile string Current = "";
        public long MovedCount, Failed;
        public string LogPath = "";
        public string Error = "";

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly string[][] Kinds = {
            new[] { "Pictures", "\uEB9F", ".jpg .jpeg .png .gif .bmp .heic .heif .webp .tif .tiff .raw .dng .cr2 .cr3 .nef .arw .svg .ico .psd .avif" },
            new[] { "Videos", "\uE714", ".mp4 .mov .avi .mkv .wmv .m4v .webm .3gp .flv .mpg .mpeg .mts" },
            new[] { "Music", "\uE8D6", ".mp3 .wav .flac .aac .m4a .ogg .wma .opus .mid" },
            new[] { "Documents", "\uE8A5", ".pdf .doc .docx .odt .rtf .txt .md .xls .xlsx .ods .csv .ppt .pptx .odp .pages .numbers .key .epub .one .xps" },
            new[] { "Archives", "\uE7B8", ".zip .rar .7z .tar .gz .bz2 .xz .tgz .cab" },
            new[] { "Installers", "\uE896", ".exe .msi .msix .msixbundle .appx .appxbundle .iso .dmg .pkg .apk" },
            new[] { "Code", "\uE943", ".py .js .ts .html .htm .css .json .xml .ps1 .psm1 .sh .bat .cmd .c .cpp .h .cs .java .go .rs .ipynb .sql .yml .yaml .toml" } };
        static readonly HashSet<string> Leave = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            ".lnk", ".url", ".ini", ".crdownload", ".part", ".partial", ".download", ".opdownload", ".tmp" };

        static string[] KindOf(string ext)
        {
            foreach (string[] k in Kinds) if ((" " + k[2] + " ").IndexOf(" " + ext.ToLowerInvariant() + " ", StringComparison.Ordinal) >= 0) return k;
            return new[] { "Other", "\uE7C3", "" };
        }

        // What would go where. Only the files directly in the folder are moved: folders inside
        // it are left as they are, and so are shortcuts, hidden files and unfinished downloads.
        public static Organizer Plan(string folder, string mode)
        {
            Organizer o = new Organizer { Folder = folder, Mode = mode };
            Dictionary<string, Group> groups = new Dictionary<string, Group>(StringComparer.OrdinalIgnoreCase);
            foreach (FileInfo f in new DirectoryInfo(folder).GetFiles())
            {
                if ((f.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0 || Leave.Contains(f.Extension) || f.Name.StartsWith("~$")) { o.Skipped++; continue; }
                string[] kind = KindOf(f.Extension);
                DateTime when = f.LastWriteTime;
                string year = when.ToString("yyyy", Inv);
                string month = when.ToString("MM MMMM", Inv);
                string group;
                if (mode == "Date") group = year + "\\" + month;
                else if (mode == "TypeDate") group = kind[0] + "\\" + year;
                else group = kind[0];
                o.Moves.Add(new Move { From = f.FullName, Group = group, To = Path.Combine(folder, group, f.Name), Size = f.Length });
                Group g;
                if (!groups.TryGetValue(group, out g)) { g = new Group { Name = group, Icon = mode == "Date" ? "\uE787" : kind[1], Examples = "" }; groups[group] = g; }
                g.Files++; g.Bytes += f.Length;
                if (g.Files <= 3) g.Examples += (g.Examples.Length > 0 ? ", " : "") + f.Name;
            }
            o.Groups.AddRange(groups.Values);
            if (mode == "Date") o.Groups.Sort((a, b) => string.Compare(b.Name, a.Name, StringComparison.Ordinal));
            else o.Groups.Sort((a, b) => b.Files.CompareTo(a.Files));
            return o;
        }

        static string FreeName(string path)
        {
            if (!File.Exists(path) && !Directory.Exists(path)) return path;
            string dir = Path.GetDirectoryName(path), stem = Path.GetFileNameWithoutExtension(path), ext = Path.GetExtension(path);
            for (int n = 1; ; n++)
            {
                string p = Path.Combine(dir, stem + "_" + n.ToString(Inv) + ext);
                if (!File.Exists(p) && !Directory.Exists(p)) return p;
            }
        }

        public void Start(string logPath)
        {
            LogPath = logPath;
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        // Every move is written down first ("from|to", one per line) so it can be undone.
        void Run()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
                try { File.SetAttributes(Path.GetDirectoryName(LogPath), FileAttributes.Directory | FileAttributes.Hidden); } catch (Exception) { }
                using (StreamWriter log = new StreamWriter(LogPath, false, new UTF8Encoding(false)))
                {
                    log.AutoFlush = true;
                    foreach (Move m in Moves)
                    {
                        Current = Path.GetFileName(m.From);
                        try
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(m.To));
                            string target = FreeName(m.To);
                            File.Move(m.From, target);
                            m.To = target;
                            log.WriteLine(m.From + "|" + target);
                            MovedCount++;
                        }
                        catch (Exception) { Failed++; }
                    }
                }
            }
            catch (Exception e) { Error = e.Message; }
            finally { Done = true; }
        }

        // Puts every file back where it was (or next to it, if something new took its name) and
        // removes the folders the sorting made, when they are empty again.
        public static Organizer Undo(string logPath)
        {
            Organizer o = new Organizer { LogPath = logPath };
            Thread t = new Thread(o.RunUndo);
            t.IsBackground = true;
            t.Start();
            return o;
        }

        void RunUndo()
        {
            try
            {
                string[] lines = File.ReadAllLines(LogPath, Encoding.UTF8);
                HashSet<string> made = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                for (int n = lines.Length - 1; n >= 0; n--)
                {
                    string[] parts = lines[n].Split('|');
                    if (parts.Length != 2) continue;
                    string from = parts[0], to = parts[1];
                    Current = Path.GetFileName(from);
                    if (!File.Exists(to)) { Failed++; continue; }
                    try
                    {
                        File.Move(to, FreeName(from));
                        MovedCount++;
                        for (string d = Path.GetDirectoryName(to); d != null && d.Length > Path.GetDirectoryName(from).Length; d = Path.GetDirectoryName(d)) made.Add(d);
                    }
                    catch (Exception) { Failed++; }
                }
                List<string> dirs = new List<string>(made);
                dirs.Sort((a, b) => b.Length.CompareTo(a.Length));
                foreach (string d in dirs)
                {
                    try { if (Directory.Exists(d) && Directory.GetFileSystemEntries(d).Length == 0) Directory.Delete(d); } catch (Exception) { }
                }
                File.Move(LogPath, LogPath + ".undone");
            }
            catch (Exception e) { Error = e.Message; }
            finally { Done = true; }
        }
    }
}
