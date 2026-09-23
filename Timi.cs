// Timi.exe - the thing that gets pinned to the taskbar.
//
// A .lnk pointing straight at powershell.exe would work, but it would also be
// a PowerShell icon running a PowerShell window: the pin's identity, its
// tooltip and its Alt+Tab entry would all say "Windows PowerShell", and a
// console window would flash on every click. This is a WinExe - no console, no
// flash - carrying Timi.ico as its own Win32 icon, so the launcher is a real
// application rather than a decorated script.
//
// It does one thing: ask Task Scheduler to run the "Timi" task, which is
// registered with RunLevel Highest and is therefore the promptless route to an
// elevated Windows Terminal. Everything else - restore-vs-seed, single window,
// drive maps - lives in Launch-Timi.ps1, which that task runs.
//
// If the task is missing (never installed, or removed), it falls back to
// launching the script through UAC directly. That path prompts, which is worse
// but is far better than a launcher that silently does nothing.
//
// Build: Install-Timi.ps1 compiles this with csc.exe. There is no project file
// on purpose - one source file and one framework compiler that ships with
// Windows means this still builds on a machine with no SDK installed.

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Timi")]
[assembly: AssemblyProduct("Timi")]
[assembly: AssemblyDescription("Agent terminal launcher")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class TimiLauncher
{
    private const string TaskName = "Timi";

    [STAThread]
    private static int Main(string[] argv)
    {
        // /pin is the first-run taskbar request, driven by Install-Timi.ps1.
        // It has to happen from inside this exe rather than from the installer
        // script: TaskbarManager pins THE CALLING APP, so a PowerShell host
        // calling it would offer to pin PowerShell.
        if (argv.Length > 0 && string.Equals(argv[0], "/pin", StringComparison.OrdinalIgnoreCase))
        {
            return RequestTaskbarPin() ? 0 : 1;
        }

        // /install exists so the setup's UAC prompt says "Timi.exe" instead of
        // "Windows PowerShell". A consent dialog naming a host process for a
        // script the user did not obviously ask for is a dialog people decline,
        // and declining it is indistinguishable from setup failing.
        if (argv.Length > 0 && string.Equals(argv[0], "/install", StringComparison.OrdinalIgnoreCase))
        {
            return RunInstaller();
        }

        // /shortcut writes a .lnk that WScript.Shell cannot: one carrying an
        // explicit AppUserModelID. See WriteShortcut for what that property
        // buys and, since the split, what it deliberately no longer does.
        if (argv.Length > 1 && string.Equals(argv[0], "/shortcut", StringComparison.OrdinalIgnoreCase))
        {
            return WriteShortcut(argv[1], argv.Length > 2 ? argv[2] : null) ? 0 : 1;
        }

        if (RunTask())
        {
            return 0;
        }
        return RunScriptElevated() ? 0 : 1;
    }


    // --- shortcut writing ------------------------------------------------
    //
    // Windows groups taskbar buttons by AppUserModelID, and a pinned shortcut
    // collects the windows whose AUMID matches its own. Timi.exe launches and
    // exits, and the window that appears belongs to Windows Terminal - a
    // packaged app with its own fixed AUMID - so by default the pin and the
    // window are two different identities and the taskbar shows two buttons:
    // the icon you clicked, and a separate Windows Terminal one for the window
    // it produced.
    //
    // Stamping the Terminal's AUMID onto Timi's shortcut merged them: the
    // button kept Timi's icon (it comes from the shortcut) and the Terminal
    // windows attached to it. The side effect was that ANY Terminal window
    // grouped there - the user's own shells included - and that was the last
    // thread tying Timi to the Terminal the user opens themselves.
    //
    // Timi runs its own portable copy of the Terminal now, so the shortcut
    // carries Timi's OWN id (Zeino.Timi) and collects nothing that is not
    // Timi's. It does not collect Timi's window either: an explicit AUMID is
    // per-process and is not inherited, and the scheduled task that carries
    // the elevation breaks the shortcut-to-process chain that would otherwise
    // pass it down. Two buttons is the accepted price of the separation.
    //
    // WScript.Shell cannot write this property, which is why the installer
    // calls back into this exe instead of creating shortcuts itself.
    private static readonly Guid PKEY_AppUserModel_ID_fmtid =
        new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private const uint PKEY_AppUserModel_ID_pid = 5;
    private const ushort VT_LPWSTR = 31;

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant
    {
        public ushort vt;
        public ushort r1, r2, r3;
        public IntPtr p1, p2;
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int cch, IntPtr fd, uint flags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int cch, out int icon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int icon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string rel, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("0000010B-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid classID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
     Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        void GetCount(out uint props);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    private static bool WriteShortcut(string lnkPath, string aumid)
    {
        var exe = Assembly.GetExecutingAssembly().Location;
        var dir = Path.GetDirectoryName(exe);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(lnkPath));
            var link = (IShellLinkW)new ShellLink();
            link.SetPath(exe);
            link.SetWorkingDirectory(dir);
            link.SetDescription("Timi - agent terminal");
            link.SetIconLocation(Path.Combine(dir, "Timi.ico"), 0);

            if (!string.IsNullOrEmpty(aumid))
            {
                var store = (IPropertyStore)link;
                var key = new PropertyKey { fmtid = PKEY_AppUserModel_ID_fmtid, pid = PKEY_AppUserModel_ID_pid };
                var value = new PropVariant { vt = VT_LPWSTR, p1 = Marshal.StringToCoTaskMemUni(aumid) };
                try
                {
                    store.SetValue(ref key, ref value);
                    store.Commit();
                }
                finally
                {
                    Marshal.FreeCoTaskMem(value.p1);
                }
            }

            ((IPersistFile)link).Save(lnkPath, true);
            Marshal.ReleaseComObject(link);
            return true;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Timi: could not write " + lnkPath + ": " + ex.Message);
            return false;
        }
    }

    private static int RunInstaller()
    {
        var here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        var script = Path.Combine(here, "Install-Timi.ps1");
        var log = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Timi", "install.log");
        Directory.CreateDirectory(Path.GetDirectoryName(log));
        var command = "& '" + script + "' *>&1 | Tee-Object -FilePath '" + log + "'";
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -Command \"" + command.Replace("\"", "`\"") + "\"")
        {
            UseShellExecute = false,
            WorkingDirectory = here
        };
        using (var p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    // The supported way to pin - Windows.UI.Shell.TaskbarManager, which shows
    // the system's own consent dialog - is not reachable from this file any
    // more, and would not work if it were. Both halves of that:
    //
    //   * It was MEASURED on this machine and refused. IsSupported=True,
    //     IsPinningAllowed=False, no dialog, no exception - and no policy
    //     behind it either: a full sweep of HKLM/HKCU Policies and
    //     PolicyManager found no pinning value, and it still refused after the
    //     taskbar layout policy was removed and gpupdate run. It is the
    //     long-standing desktop-app limitation (WindowsAppSDK #1648): the API
    //     works from packaged apps only. Install-Timi.ps1 stopped calling
    //     /pin because of that and pins through the sign-in layout XML.
    //   * Reaching it costs this file the property its header claims - that
    //     one source file plus the in-box csc.exe builds on a machine with no
    //     SDK. `using Windows.UI.Shell` needs Windows.winmd from the Windows
    //     Kits UnionMetadata folder, which is not installed here, so the build
    //     failed with CS0234 the moment anything touched this source.
    //
    // The mode is kept, and answers honestly, so a caller that still asks gets
    // false and falls back to the layout route instead of hanging on a dialog
    // that will never appear.
    private static bool RequestTaskbarPin()
    {
        PinLog("skipped: TaskbarManager refuses for unpackaged apps on this build " +
               "(measured IsPinningAllowed=False); pinning goes through the layout XML");
        return false;
    }

    // Why the request was refused is invisible from the outside - every
    // failure mode returns false rather than throwing - so it gets written
    // down. Install-Timi.ps1 reads this when it has to fall back.
    private static void PinLog(string line)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Timi");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "pin.log"),
                DateTime.Now.ToString("s") + "  " + line + Environment.NewLine);
        }
        catch { }
    }


    private static bool RunTask()
    {
        try
        {
            var psi = new ProcessStartInfo("schtasks.exe", "/Run /TN \"" + TaskName + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var p = Process.Start(psi))
            {
                // Draining the pipes matters: schtasks writes a success banner,
                // and a full pipe buffer would deadlock the wait.
                p.StandardOutput.ReadToEnd();
                p.StandardError.ReadToEnd();
                p.WaitForExit(15000);
                return p.HasExited && p.ExitCode == 0;
            }
        }
        catch
        {
            return false;
        }
    }

    private static bool RunScriptElevated()
    {
        var here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        var script = Path.Combine(here, "Launch-Timi.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show(
                "Timi could not find Launch-Timi.ps1 next to Timi.exe.\r\n\r\nExpected: " + script,
                "Timi", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }

        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" -Elevated")
            {
                UseShellExecute = true,   // required for the runas verb
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
            return true;
        }
        catch (Exception ex)
        {
            // The common case here is the user clicking No on the UAC prompt.
            // Saying so beats a launcher that appears to do nothing at all.
            MessageBox.Show("Timi could not start elevated.\r\n\r\n" + ex.Message,
                "Timi", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }
}
