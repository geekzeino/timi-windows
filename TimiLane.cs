// TimiLane.exe - the process behind one Timi agent tab.
//
// This is timi-lane.ps1 rewritten as a native executable, and the reason is
// latency: everything this file does happens between the user pressing Ctrl+T
// and the agent painting its first frame, so every millisecond here is a
// millisecond of empty tab. Measured on this machine, the PowerShell version
// spent ~1.0 s before its first statement ran (powershell.exe 5.1 startup) and
// a further ~0.8 s inside Get-HostTerminal, because the first Get-CimInstance
// in a fresh session pays for standing the whole WMI/CIM stack up. Neither
// cost bought anything: the parent walk is four integers deep, and the CIM
// query was only ever asked for one of them. This exe starts in ~40 ms and
// reads the same field from NtQueryInformationProcess in microseconds.
//
// The BEHAVIOUR is deliberately unchanged - the crash-resume contract below is
// the whole point of having a wrapper at all, and it is copied, not redesigned:
//
// Windows Terminal's own "restore my tabs" (firstWindowPreference:
// persistedWindowLayout) brings a tab back, but per its docs it restores the
// window/pane LAYOUT only - "not any contents of those panes". For a shell tab
// that is the whole story; for an agent tab it is half of one, because the tab
// comes back as a brand-new empty conversation and the work that was in it is
// gone. This wrapper closes that gap: it owns a Claude session id per lane and
// resumes it when - and only when - the terminal died underneath it.
//
// How "died" is told apart from "closed on purpose": the marker written at
// start records the PID *and start time* of the hosting WindowsTerminal.exe.
//   host process gone   -> the terminal crashed, or the box rebooted
//                          -> resume the session
//   host still alive    -> the user closed that tab themselves
//                          -> start a fresh session
// The start time is part of the check because Windows recycles PIDs; a stale
// marker pointing at a reused PID would otherwise read as "still open" and
// silently drop the resume.
//
// That test says which CONVERSATIONS are recoverable. It does not say which
// TABS are allowed to take one, and taking that for granted is what made a
// plain Ctrl+T open somebody's old chat: closing a Timi window ON PURPOSE
// also kills the host, so every tab that window held leaves a marker reading
// exactly like a crash, and the next tab to start - restored or not - walked
// off with one of them. A tab may now claim a conversation only while the
// window it lives in is still coming up, which is the layout restore and
// nothing else; a tab the user opened by hand always starts a new chat. See
// RestoreWindowSeconds.
//
// There is one marker per TAB, named lane.pid.ticks.json. It used to be one per
// LANE, which quietly lost work: two Opus tabs shared lanes/opus.json, so the
// one that started second wrote its session id over the first one's and that
// conversation could never be resumed. Worse, a tab that was closed before it
// said anything left a marker naming a transcript that does not exist, and the
// next start found that instead of the tab that held the real work. A tab now
// CLAIMS one orphaned marker - oldest first, transcript must exist, taken by
// rename so a race cannot hand the same conversation to two tabs.
//
// Session identity is ours, not the one --continue would pick: --continue
// resumes the most recent conversation IN THIS DIRECTORY, and all three lanes
// run in %USERPROFILE%, so after a crash it would hand the Sonnet tab whichever
// lane happened to speak last. --session-id on the way in and --resume on the
// way back keeps each lane on its own thread.
//
// Build: Install-Timi.ps1 compiles this with csc.exe, same as Timi.cs. It is a
// console exe, not a winexe - it inherits the tab's console and hands it
// straight to claude.exe.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

internal static class TimiLane
{
    private sealed class LaneSpec
    {
        public string Model;
        public string Label;
        public string Glyph;
    }

    private static LaneSpec Spec(string lane)
    {
        switch (lane)
        {
            case "opus":   return new LaneSpec { Model = "opus",   Label = "Opus",   Glyph = "✳" };
            case "sonnet": return new LaneSpec { Model = "sonnet", Label = "Sonnet", Glyph = "❖" };
            case "fable":  return new LaneSpec { Model = "fable",  Label = "Fable",  Glyph = "▲" };
            case "gemini": return new LaneSpec { Model = "gemini-3.8-flash-high", Label = "Gemini", Glyph = "♊" };
            default:       return null;
        }
    }

    private static int Main(string[] argv)
    {
        // Accept both "TimiLane.exe opus" and the PowerShell-era "-Lane opus",
        // so a settings.json that predates this exe still starts a lane.
        string lane = null;
        for (int i = 0; i < argv.Length; i++)
        {
            if (string.Equals(argv[i], "-Lane", StringComparison.OrdinalIgnoreCase) && i + 1 < argv.Length)
            {
                lane = argv[++i].ToLowerInvariant();
            }
            else if (!argv[i].StartsWith("-"))
            {
                lane = argv[i].ToLowerInvariant();
            }
        }

        LaneSpec spec = lane == null ? null : Spec(lane);
        if (spec == null)
        {
            Console.Error.WriteLine("TimiLane: usage: TimiLane.exe <opus|sonnet|fable|gemini>");
            return 2;
        }

        // The banner glyphs sit outside every OEM code page, and .NET encodes
        // console output with Console.OutputEncoding rather than going through
        // WriteConsoleW - so without this the tab opens on a mojibake line.
        // UTF8Encoding(false) because the BOM-carrying Encoding.UTF8 makes
        // .NET Framework emit a stray preamble on the first write.
        try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }

        // Ctrl+C belongs to the agent, not to this wrapper. The console sends
        // the event to every process attached to it, so claude.exe sees it
        // either way; swallowing it here just stops the wrapper from dying
        // first and running the marker cleanup out from under a live session.
        Console.CancelKeyPress += delegate(object s, ConsoleCancelEventArgs e) { e.Cancel = true; };

        string home     = Environment.GetEnvironmentVariable("USERPROFILE");
        string localApp = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        string stateDir = Path.Combine(localApp, "Timi", "lanes");

        Directory.CreateDirectory(stateDir);

        ResolveAccount(home, localApp, lane);

        // --- elevation ----------------------------------------------------
        // Elevation belongs to the WINDOW, and this is the only place that can
        // notice the window did not get it. The Terminal cannot lift a tab in
        // place: a profile carrying elevate=true is handed to elevate-shim.exe,
        // which shows a UAC dialog and opens a SECOND, elevated window - on a
        // command line that then suppresses the layout restore. So the lane asks
        // the "Timi" scheduled task (RunLevel Highest) to reopen Timi properly
        // and gets out of the way. Nothing has been written yet at this point,
        // so leaving costs nothing; in particular no marker has been touched,
        // which is what stops this bail-out from eating a session id.
        HostTerminal hostTerm = GetHostTerminal();

        if (!IsElevated() && ReopenElevated(localApp, hostTerm))
        {
            return 0;
        }

        string marker = Path.Combine(stateDir, string.Format(
            "{0}.{1}.{2}.json", lane, Process.GetCurrentProcess().Id,
            DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture)));

        // --- decide: resume or fresh -------------------------------------
        // One marker per TAB, not one per lane. A lane with two tabs open used
        // to share a single lane.json, so the tab that started second wrote its
        // session id over the first one's and that conversation could never
        // come back - measured live on 2026-08-20, where the opus marker named
        // an empty session opened a minute after the tab that held the actual
        // work. Each tab now claims exactly one orphaned marker, oldest first,
        // by renaming it: the rename is atomic on NTFS, so two tabs starting in
        // the same instant cannot both take the same conversation.
        //
        // ...and only a tab the Terminal restored is offered one at all. The
        // sweep still runs for a tab the user opened, because the dead empty
        // markers it clears would otherwise sit in front of the marker that
        // holds real work; it just comes back empty-handed.
        bool restoring = IsLayoutRestore(hostTerm);
        string resumeId = ClaimOrphanSession(stateDir, lane, home, restoring);

        string sessionId = resumeId ?? Guid.NewGuid().ToString();

        WriteMarker(marker, lane, sessionId, hostTerm);
        SyncClaudeTheme(home);
        EnsureFolderTrusted(home);

        // --- run ----------------------------------------------------------
        string shortId = sessionId.Substring(0, 8);
        if (resumeId != null)
        {
            WriteColour(ConsoleColor.DarkYellow, string.Format(
                "{0} Timi {1} - restoring session {2} (the terminal went away, this tab did not)",
                spec.Glyph, spec.Label, shortId));
        }
        else
        {
            WriteColour(ConsoleColor.DarkGray, string.Format(
                "{0} Timi {1} - new session {2}", spec.Glyph, spec.Label, shortId));
        }

        if (accountName != null)
        {
            WriteColour(ConsoleColor.DarkGray, "  account " + accountName);
        }

        // Effort comes from the generated lanes.json beside this exe - the same
        // manifest the launcher and settings patcher read - so the Windows lane
        // opens at the SAME effort the Linux reference ships (opus=medium, not
        // the xhigh every lane used to get here). A missing manifest is loud:
        // the reference default is used and the reason prints, never silence.
        string effort = ManifestEffort(lane);
        string common = "--model " + spec.Model + " --effort " + effort;
        int exit = 0;
        try
        {
            if (lane == "gemini")
            {
                if (resumeId != null)
                {
                    DateTime t0 = DateTime.UtcNow;
                    exit = RunAgy("--dangerously-skip-permissions --conversation " + Quote(resumeId), marker, lane, hostTerm, home);
                    if (exit != 0 && (DateTime.UtcNow - t0).TotalSeconds < 20)
                    {
                        WriteColour(ConsoleColor.DarkYellow, "  resume failed - starting a fresh session instead");
                        string fresh = Guid.NewGuid().ToString();
                        WriteMarker(marker, lane, fresh, hostTerm);
                        exit = RunAgy("--dangerously-skip-permissions", marker, lane, hostTerm, home);
                    }
                }
                else
                {
                    exit = RunAgy("--dangerously-skip-permissions", marker, lane, hostTerm, home);
                }
            }
            else if (resumeId != null)
            {
                DateTime t0 = DateTime.UtcNow;
                exit = RunClaude(common + " --resume " + Quote(resumeId));
                // A transcript that claude itself refuses (corrupt, or written
                // by a newer build) fails in about a second. Falling back keeps
                // the tab usable instead of parking it on an error.
                if (exit != 0 && (DateTime.UtcNow - t0).TotalSeconds < 20)
                {
                    WriteColour(ConsoleColor.DarkYellow, "  resume failed - starting a fresh session instead");
                    // Repoint the marker before starting over. Left naming the
                    // transcript that just refused to open, it is claimed again
                    // on every later start - the same conversation announced and
                    // dropped for ever - and the session that IS running goes
                    // unrecorded, so a crash in it could not be recovered.
                    string fresh = Guid.NewGuid().ToString();
                    WriteMarker(marker, lane, fresh, hostTerm);
                    exit = RunClaude(common + " --session-id " + Quote(fresh));
                }
            }
            else
            {
                exit = RunClaude(common + " --session-id " + Quote(sessionId));
            }
        }
        finally
        {
            // Reached only when claude returned on its own. A crash, a reboot
            // or a closed window never gets here - which is exactly what leaves
            // the marker behind for the next launch to find.
            try { File.Delete(marker); } catch { }
        }

        // The PowerShell profile carried -NoExit so a finished agent left a
        // usable shell behind instead of closing the tab. Same promise, but the
        // ~1 s of powershell.exe startup is now paid on the way OUT, where
        // nobody is waiting on it, instead of on the way in.
        try
        {
            ProcessStartInfo shell = new ProcessStartInfo("powershell.exe", "-NoLogo");
            shell.UseShellExecute = false;
            using (Process p = Process.Start(shell))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch
        {
            return exit;
        }
    }

    // --- claude ----------------------------------------------------------


    // --- account ----------------------------------------------------------
    // Which Claude account this tab bills. Windows Timi had exactly one - the
    // login in ~/.claude - so a lane whose account hit its quota had no way back
    // except logging the whole box out. The Linux deck picks per chat; this is
    // the same act, and CLAUDE_CONFIG_DIR is the whole mechanism, because that is
    // what claude.exe reads to find its credentials.
    private static string accountDir;
    private static string accountName;

    private static void ResolveAccount(string home, string localApp, string lane)
    {
        string perLane = Path.Combine(localApp, "Timi", "account." + lane);
        string global  = Path.Combine(localApp, "Timi", "account");
        string chosen  = null;
        try
        {
            if (File.Exists(perLane))     chosen = File.ReadAllText(perLane).Trim();
            else if (File.Exists(global)) chosen = File.ReadAllText(global).Trim();
        }
        catch (IOException)
        {
            chosen = null;
        }
        if (string.IsNullOrEmpty(chosen)) return;

        string dir = Path.Combine(home, ".claude-cfg", chosen);
        // A marker naming an account nobody provisioned must fall back to the
        // default login. Starting claude on an empty config dir does not fail
        // loudly - it asks the user to log in again, on a tab that was working.
        if (!File.Exists(Path.Combine(dir, ".credentials.json"))) return;
        accountName = chosen;
        accountDir  = dir;
    }

    private static int RunClaude(string args)
    {
        // No redirection: claude.exe inherits this tab's console and owns it.
        // Resolved off PATH by CreateProcess, the same way the shell did it.
        ProcessStartInfo psi = new ProcessStartInfo("claude.exe", args);
        psi.UseShellExecute = false;
        // Set on the CHILD only: the tab's own environment stays clean, so a
        // switch takes effect on the next lane start and never leaks sideways
        // into anything else the user runs in this console.
        if (accountDir != null)
        {
            psi.EnvironmentVariables["CLAUDE_CONFIG_DIR"] = accountDir;
        }
        try
        {
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            // claude missing from PATH, or a broken install. The shell version
            // left an error on screen and a live prompt behind it; an unhandled
            // exception here would instead take the console down and close the
            // tab, which loses the one message that says what went wrong.
            WriteColour(ConsoleColor.Red, "  could not start claude.exe: " + ex.Message);
            return -1;
        }
    }

    private static int RunAgy(string args, string markerPath = null, string lane = null, HostTerminal hostTerm = null, string home = null)
    {
        ProcessStartInfo psi = new ProcessStartInfo("agy.exe", args);
        psi.UseShellExecute = false;
        try
        {
            DateTime startUtc = DateTime.UtcNow;
            using (Process p = Process.Start(psi))
            {
                if (markerPath != null && lane != null && home != null)
                {
                    MonitorAgySession(p, markerPath, lane, hostTerm, home, startUtc);
                }
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            WriteColour(ConsoleColor.Red, "  could not start agy.exe: " + ex.Message);
            return -1;
        }
    }

    private static void MonitorAgySession(Process p, string markerPath, string lane, HostTerminal hostTerm, string home, DateTime startUtc)
    {
        Thread t = new Thread(delegate()
        {
            try
            {
                for (int i = 0; i < 15; i++)
                {
                    Thread.Sleep(1000);
                    if (p.HasExited) return;
                    string cid = FindLatestAgySession(home, startUtc);
                    if (!string.IsNullOrEmpty(cid))
                    {
                        WriteMarker(markerPath, lane, cid, hostTerm);
                        return;
                    }
                }
            }
            catch { }
        });
        t.IsBackground = true;
        t.Start();
    }

    private static string FindLatestAgySession(string home, DateTime startUtc)
    {
        try
        {
            string presenceDir = Path.Combine(home, ".gemini", "antigravity-cli", "presence");
            if (Directory.Exists(presenceDir))
            {
                string[] locks = Directory.GetFiles(presenceDir, "*.lock");
                string best = null;
                DateTime bestTime = DateTime.MinValue;
                foreach (string lk in locks)
                {
                    DateTime wt = File.GetLastWriteTimeUtc(lk);
                    if (wt >= startUtc.AddSeconds(-2) && wt > bestTime)
                    {
                        bestTime = wt;
                        best = Path.GetFileNameWithoutExtension(lk);
                    }
                }
                if (best != null) return best;
            }
            string brainDir = Path.Combine(home, ".gemini", "antigravity-cli", "brain");
            if (Directory.Exists(brainDir))
            {
                string[] dirs = Directory.GetDirectories(brainDir);
                string best = null;
                DateTime bestTime = DateTime.MinValue;
                foreach (string d in dirs)
                {
                    DateTime wt = Directory.GetLastWriteTimeUtc(d);
                    if (wt >= startUtc.AddSeconds(-2) && wt > bestTime)
                    {
                        bestTime = wt;
                        best = Path.GetFileName(d);
                    }
                }
                if (best != null) return best;
            }
        }
        catch { }
        return null;
    }

    private static string Quote(string s)
    {
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    private static void WriteColour(ConsoleColor colour, string text)
    {
        ConsoleColor previous = Console.ForegroundColor;
        try
        {
            Console.ForegroundColor = colour;
            Console.WriteLine(text);
        }
        finally { Console.ForegroundColor = previous; }
    }

    // --- host terminal ----------------------------------------------------

    private sealed class HostTerminal
    {
        public int Pid;
        public string Start;
        public DateTime When;
    }

    // Walk up the process tree to the WindowsTerminal.exe hosting this tab.
    // Depth is bounded: the real chain is TimiLane -> OpenConsole -> terminal,
    // and an unbounded walk would hang on a PID loop.
    private static HostTerminal GetHostTerminal()
    {
        try
        {
            Process current = Process.GetCurrentProcess();
            int walk = current.Id;
            DateTime childStart = current.StartTime;

            for (int hop = 0; hop < 6; hop++)
            {
                Process p;
                try { p = Process.GetProcessById(walk); }
                catch { return null; }

                if (string.Equals(p.ProcessName, "WindowsTerminal", StringComparison.OrdinalIgnoreCase))
                {
                    return new HostTerminal
                    {
                        Pid = p.Id,
                        Start = p.StartTime.ToString("o", CultureInfo.InvariantCulture),
                        When = p.StartTime,
                    };
                }

                int parent = ParentPid(walk);
                if (parent == 0 || parent == walk) return null;

                // A parent that started AFTER its child is not the parent: the
                // recorded parent id was recycled onto an unrelated process.
                // Walking into it would read some stranger's tree as our host.
                try
                {
                    Process pp = Process.GetProcessById(parent);
                    if (pp.StartTime > childStart) return null;
                    childStart = pp.StartTime;
                }
                catch { return null; }

                walk = parent;
            }
        }
        catch { }
        return null;
    }

    // Is this tab one Windows Terminal brought back itself, or one the user
    // just opened? Only the first may take a dead tab's conversation.
    //
    // Time is the discriminator because the command line is not: the persisted
    // layout stores each tab's command line verbatim, so a restored tab and a
    // Ctrl+T tab both arrive as `TimiLane.exe opus` with nothing in argv, in
    // the environment or on the parent chain to tell them apart. What does
    // separate them is when they start relative to their window. Measured here
    // on 2026-08-31: the restored tab wrote its marker 1.118 s after its
    // WindowsTerminal.exe began (host 1964 up at 13:20:45.180, marker opened
    // at 13:20:46.298), while the three tabs opened by hand in that same window
    // came 18, 27 and 29 minutes later. Five seconds is 4.5x the measured
    // restore - room for a multi-tab layout on a busy boot - and still less
    // than the gap between a window painting and a hand reaching for Ctrl+T.
    //
    // No host at all - a lane started from a plain console - reads as NOT a
    // restore. Unknown has to fall on the side that opens a new chat, because
    // that side is merely a fresh tab while the other side is somebody else's
    // conversation appearing uninvited.
    private const double RestoreWindowSeconds = 5.0;

    private static bool IsLayoutRestore(HostTerminal host)
    {
        if (host == null) return false;
        double age = (DateTime.Now - host.When).TotalSeconds;
        return age >= 0.0 && age <= RestoreWindowSeconds;
    }

    private static bool HostAlive(int markerPid, string markerStart)
    {
        // A marker with no host recorded means the lane once started outside a
        // Terminal window and we never knew who to watch. "Unknown" must read
        // as ALIVE here, not as dead: reading it as dead would make every such
        // start look like a crash and silently resume an old conversation.
        if (markerPid == 0) return true;
        try
        {
            Process p = Process.GetProcessById(markerPid);
            if (!string.Equals(p.ProcessName, "WindowsTerminal", StringComparison.OrdinalIgnoreCase)) return false;
            // PID reuse guard - same number, different process.
            return p.StartTime.ToString("o", CultureInfo.InvariantCulture) == markerStart;
        }
        catch { return false; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr handle, int infoClass, ref ProcessBasicInformation info, int length, out int returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    private static int ParentPid(int pid)
    {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return 0;
        try
        {
            ProcessBasicInformation pbi = new ProcessBasicInformation();
            int returned;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out returned) != 0) return 0;
            return pbi.InheritedFromUniqueProcessId.ToInt32();
        }
        catch { return 0; }
        finally { CloseHandle(h); }
    }

    // --- marker -----------------------------------------------------------

    // Claude Code stores a directory's transcripts under a slug of its path.
    // --- elevation -------------------------------------------------------

    private static bool IsElevated()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            {
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
            }
        }
        catch
        {
            // Unknown reads as elevated: a lane that cannot tell must not start
            // bouncing windows on a guess.
            return true;
        }
    }

    // Ask the "Timi" scheduled task (RunLevel Highest, so no consent dialog) to
    // reopen Timi properly, and report whether this tab should now step aside.
    //
    // The stamp records WHICH terminal asked, and that is the whole trick. A
    // window with three lanes in it produces three of these calls within a
    // second; only the first should fire the task, and the other two should
    // still leave, or the unelevated window survives beside the new one - the
    // two-windows bug wearing a different hat. A stamp from a DIFFERENT window
    // means something worse: the relaunch itself came back unelevated. Bouncing
    // again there would open windows forever, so the lane says so and runs.
    private static bool ReopenElevated(string localApp, HostTerminal host)
    {
        string stamp = Path.Combine(localApp, "Timi", "elevation-retry");
        string key = host == null ? "?" : host.Pid + "@" + host.Start;
        try
        {
            if (File.Exists(stamp) &&
                (DateTime.UtcNow - File.GetLastWriteTimeUtc(stamp)).TotalSeconds < 120)
            {
                string prev = File.ReadAllText(stamp).Trim();
                if (string.Equals(prev, key, StringComparison.Ordinal))
                {
                    // Sibling tab of the window that already asked.
                    return true;
                }
                WriteColour(ConsoleColor.DarkYellow,
                    "  Timi did not come back elevated - running this lane without administrator");
                return false;
            }
        }
        catch { }

        if (!RunTimiTask())
        {
            WriteColour(ConsoleColor.DarkYellow,
                "  not running as administrator, and the Timi task did not start - continuing anyway");
            return false;
        }

        try { File.WriteAllText(stamp, key); } catch { }
        WriteColour(ConsoleColor.DarkGray, "  reopening Timi as administrator...");
        return true;
    }

    private static bool RunTimiTask()
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", "/Run /TN \"Timi\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi))
            {
                p.StandardOutput.ReadToEnd();
                p.StandardError.ReadToEnd();
                p.WaitForExit(15000);
                return p.HasExited && p.ExitCode == 0;
            }
        }
        catch { return false; }
    }

    // --- orphaned sessions -------------------------------------------------

    private sealed class Orphan
    {
        public string Path;
        public string Session;
        public DateTimeOffset Opened;
    }

    // Every marker for this lane whose hosting terminal is gone is a tab that
    // died with a conversation in it. Take the oldest one that still has a
    // transcript on disk, and take it by RENAME so that two tabs starting
    // together cannot both walk off with the same session id.
    //
    // mayClaim false means "sweep, but keep your hands off": the caller is a
    // tab the user opened, which gets a new chat no matter what is lying here.
    private static string ClaimOrphanSession(string stateDir, string lane, string home, bool mayClaim)
    {
        List<Orphan> orphans = new List<Orphan>();
        string[] files;
        try { files = Directory.GetFiles(stateDir, "*.json"); }
        catch { return null; }

        foreach (string file in files)
        {
            try
            {
                string raw = File.ReadAllText(file);
                if (!string.Equals(ReadString(raw, "lane"), lane, StringComparison.OrdinalIgnoreCase)) continue;
                if (HostAlive(ReadInt(raw, "wtPid"), ReadString(raw, "wtStart"))) continue;

                string sid = ReadString(raw, "sessionId");
                if (string.IsNullOrEmpty(sid) || !SessionFileExists(home, lane, sid))
                {
                    // Host gone and no transcript ever written: an empty tab.
                    // Deleting it matters - left behind, it is what the next
                    // lane claims instead of the marker that has real work in
                    // it, and the conversation is reported as unrecoverable.
                    try { File.Delete(file); } catch { }
                    continue;
                }

                DateTimeOffset opened;
                if (!DateTimeOffset.TryParse(ReadString(raw, "opened"), CultureInfo.InvariantCulture,
                        DateTimeStyles.RoundtripKind, out opened))
                {
                    opened = DateTimeOffset.MinValue;
                }
                orphans.Add(new Orphan { Path = file, Session = sid, Opened = opened });
            }
            catch { }
        }

        if (!mayClaim) return null;

        orphans.Sort(delegate(Orphan a, Orphan b) { return a.Opened.CompareTo(b.Opened); });

        foreach (Orphan o in orphans)
        {
            // Unique destination per claimer: a stale .claimed file left by a
            // process that died mid-claim must not block every later tab.
            string claimed = o.Path + ".claimed-" + Process.GetCurrentProcess().Id;
            try { File.Move(o.Path, claimed); }
            catch { continue; }          // another tab got there first
            try { File.Delete(claimed); } catch { }
            return o.Session;
        }
        return null;
    }

    private static bool SessionFileExists(string home, string lane, string sid)
    {
        if (string.Equals(lane, "gemini", StringComparison.OrdinalIgnoreCase))
        {
            string brainDir = Path.Combine(home, ".gemini", "antigravity-cli", "brain", sid);
            if (Directory.Exists(brainDir)) return true;
            string transcript = Path.Combine(brainDir, ".system_generated", "logs", "transcript.jsonl");
            return File.Exists(transcript);
        }
        return File.Exists(SessionFile(ConfigDir(home), sid));
    }

    // Where claude keeps that session's transcript. This hangs off the CONFIG
    // DIR, and for a lane billing a Timi account that is not the home folder:
    // the lane runs claude with CLAUDE_CONFIG_DIR set to ~/.claude-cfg/<account>
    // and every transcript it writes lands under THAT. Looking in ~/.claude
    // regardless found the conversations from before the account existed and
    // offered those - measured 2026-08-31, where all four live markers named
    // transcripts last written on 2026-08-20 under ~/.claude while the sessions
    // actually running were under ~/.claude-cfg/zeinobusiness. Each one was
    // announced as restored and then refused by --resume, because the account
    // claude cannot see the default login's folder.
    private static string SessionFile(string configDir, string sessionId)
    {
        string slug = Regex.Replace(Environment.CurrentDirectory, "[^A-Za-z0-9]", "-");
        return Path.Combine(configDir, "projects", slug, sessionId + ".jsonl");
    }

    // The folder claude is going to read and write for this tab: the account's
    // when one is selected, ~/.claude otherwise. Same value RunClaude hands the
    // child as CLAUDE_CONFIG_DIR, which is what makes it the right place to
    // look.
    private static string ConfigDir(string home)
    {
        return accountDir ?? Path.Combine(home, ".claude");
    }

    private static void WriteMarker(string path, string lane, string sessionId, HostTerminal host)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("{\n");
        sb.AppendFormat("    \"lane\":  \"{0}\",\n", Esc(lane));
        sb.AppendFormat("    \"sessionId\":  \"{0}\",\n", Esc(sessionId));
        sb.AppendFormat("    \"wtPid\":  {0},\n", host == null ? 0 : host.Pid);
        sb.AppendFormat("    \"wtStart\":  \"{0}\",\n", host == null ? "" : Esc(host.Start));
        sb.AppendFormat("    \"shellPid\":  {0},\n", Process.GetCurrentProcess().Id);
        sb.AppendFormat("    \"opened\":  \"{0}\"\n", DateTime.Now.ToString("o", CultureInfo.InvariantCulture));
        sb.Append("}\n");
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
    }

    private static string Esc(string s)
    {
        return s == null ? "" : s.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    // The marker is a flat object this program wrote, so a keyed regex is a
    // complete reader for it - and it still reads the BOM-carrying files the
    // PowerShell version left behind, because File.ReadAllText detects that.
    private static string ReadString(string json, string key)
    {
        Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
        return m.Success ? m.Groups[1].Value : null;
    }

    private static int ReadInt(string json, string key)
    {
        Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*(-?\\d+)");
        int v;
        if (m.Success && int.TryParse(m.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) return v;
        return 0;
    }

    // --- folder trust -------------------------------------------------------

    // A tab that opens on "Quick safety check: is this a project you created or
    // one you trust?" has not started a chat - it has started a question, and
    // nothing can be typed until it is answered. Claude Code keeps that answer
    // per CONFIG DIR, in projects[<cwd>].hasTrustDialogAccepted, so every extra
    // account added to Timi arrives distrusting the one directory every lane
    // runs in; and because a tab still parked on the unanswered prompt writes
    // the flag back as false when it saves, answering it in one tab does not
    // reliably keep it answered. Measured 2026-08-31: .claude.json under
    // geekzeino and under the default login both held true for C:/Users/Ahmad
    // while zeinobusiness held false, rewritten false minutes after the prompt
    // had been accepted in another tab.
    //
    // This only ever COPIES an answer the user already gave for the SAME
    // directory under one of their own logins. It never invents trust: with no
    // other config saying yes, nothing is written and the prompt appears
    // exactly as it does today.
    private static void EnsureFolderTrusted(string home)
    {
        // The config spells the directory with forward slashes.
        string cwd = Environment.CurrentDirectory.Replace("\\", "/");
        // Not ConfigDir(): the default login keeps its config at ~/.claude.json,
        // beside the ~/.claude folder rather than inside it, while an account
        // keeps both in ~/.claude-cfg/<account>. The two roots differ by one
        // level and only for the default login.
        string target = Path.Combine(accountDir ?? home, ".claude.json");
        try
        {
            if (!File.Exists(target)) return;
            string raw = File.ReadAllText(target);
            int pos = TrustValuePos(raw, cwd);
            if (!TokenAt(raw, pos, "false")) return;   // already true, or no entry
            if (!TrustedElsewhere(home, target, cwd)) return;
            // A five-character splice, not a parse-and-rewrite: this file also
            // carries the OAuth login, every project's history and several
            // caches, and a full round-trip of it is a good way to lose one.
            File.WriteAllText(target,
                raw.Substring(0, pos) + "true" + raw.Substring(pos + 5),
                new UTF8Encoding(false));
        }
        catch { }
    }

    // Has the user already trusted this same directory under a DIFFERENT
    // login? Timi's accounts each live in %USERPROFILE%\.claude-cfg\<name>,
    // beside the default login's own .claude.json.
    private static bool TrustedElsewhere(string home, string except, string cwd)
    {
        List<string> configs = new List<string>();
        configs.Add(Path.Combine(home, ".claude.json"));
        try
        {
            foreach (string d in Directory.GetDirectories(Path.Combine(home, ".claude-cfg")))
            {
                configs.Add(Path.Combine(d, ".claude.json"));
            }
        }
        catch { }

        foreach (string c in configs)
        {
            if (string.Equals(c, except, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                if (!File.Exists(c)) continue;
                string raw = File.ReadAllText(c);
                if (TokenAt(raw, TrustValuePos(raw, cwd), "true")) return true;
            }
            catch { }
        }
        return false;
    }

    // Where this directory's hasTrustDialogAccepted VALUE starts, or -1 when the
    // file holds no entry for it. The flag is the first one after the project's
    // own key, because it sits inside that project's object.
    private static int TrustValuePos(string json, string cwd)
    {
        int key = json.IndexOf("\"" + cwd + "\"", StringComparison.Ordinal);
        if (key < 0) return -1;
        int flag = json.IndexOf("\"hasTrustDialogAccepted\"", key, StringComparison.Ordinal);
        if (flag < 0) return -1;
        int colon = json.IndexOf(':', flag);
        if (colon < 0) return -1;
        int v = colon + 1;
        while (v < json.Length && char.IsWhiteSpace(json[v])) v++;
        return v;
    }

    private static bool TokenAt(string json, int pos, string token)
    {
        return pos >= 0 && pos + token.Length <= json.Length
            && string.CompareOrdinal(json, pos, token, 0, token.Length) == 0;
    }

    // --- theme ------------------------------------------------------------

    // Claude Code reads its TUI theme from globalConfig.theme in ~/.claude.json
    // (verified in the binary: themeSetting comes off the global config object).
    // Windows Terminal already follows the OS light/dark switch on its own;
    // without this the terminal would go light while Claude Code kept painting
    // a dark-background palette on top of it.
    //
    // The edit is a targeted text splice, NOT a parse-and-rewrite: that file
    // also holds the OAuth account, every project's history and several caches,
    // and a full round-trip of it is a good way to lose one of those. Writes
    // only happen when the value actually changes, so on a normal launch this
    // touches nothing.
    private static void SyncClaudeTheme(string home)
    {
        string want;
        try
        {
            object v = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", null);
            if (v == null) return;   // key absent on some SKUs - leave the theme alone
            want = Convert.ToInt32(v) == 1 ? "light" : "dark";
        }
        catch { return; }

        string cfg = Path.Combine(home, ".claude.json");
        if (!File.Exists(cfg)) return;

        // One writer at a time: all three lanes start within the same second.
        // Constructed inside the guard, not before it: a Global\ mutex needs
        // SeCreateGlobalPrivilege, and a lane opened without elevation would
        // otherwise throw here and take the tab down over a cosmetic setting.
        Mutex mutex = null;
        bool held = false;
        try
        {
            mutex = new Mutex(false, @"Global\TimiThemeSync");
            try { held = mutex.WaitOne(3000); }
            catch (AbandonedMutexException) { held = true; }
            if (!held) return;

            string raw = File.ReadAllText(cfg);
            Match m = Regex.Match(raw, "\"theme\"\\s*:\\s*\"[^\"]*\"");
            string updated;
            if (m.Success)
            {
                if (m.Value.EndsWith("\"" + want + "\"")) return;   // already correct
                updated = raw.Remove(m.Index, m.Length).Insert(m.Index, "\"theme\": \"" + want + "\"");
            }
            else
            {
                int brace = raw.IndexOf('{');
                if (brace < 0) return;
                // Inserting a leading pair needs a key to follow the comma. An
                // empty object would turn into {"theme":"dark",} - invalid
                // JSON, and this file is too expensive to hand back broken.
                int next = brace + 1;
                while (next < raw.Length && char.IsWhiteSpace(raw[next])) next++;
                if (next >= raw.Length || raw[next] == '}') return;
                updated = raw.Insert(brace + 1, "\"theme\": \"" + want + "\",");
            }

            string bak = cfg + ".timi-bak";
            if (!File.Exists(bak)) File.Copy(cfg, bak);
            File.WriteAllText(cfg, updated, new UTF8Encoding(false));
        }
        catch
        {
            // A theme mismatch is cosmetic; never take the tab down over it.
        }
        finally
        {
            if (mutex != null)
            {
                if (held) mutex.ReleaseMutex();
                mutex.Close();
            }
        }
    }

    // The reference defaults, used only when lanes.json cannot be read. They
    // mirror the Linux PROVIDERS table so a degraded read still opens the lane
    // at the effort the user's deck ships - and the fallback always PRINTS.
    private static readonly Dictionary<string, string> ReferenceEfforts =
        new Dictionary<string, string>
    {
        { "opus", "medium" }, { "sonnet", "xhigh" }, { "fable", "xhigh" }, { "gemini", "high" },
    };

    private static string ManifestEffort(string lane)
    {
        try
        {
            string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lanes.json");
            string text = File.ReadAllText(path, Encoding.UTF8);
            // Pull this lane's block out of the manifest - the file is machine-
            // generated with one provider object per key, so a scoped regex on
            // "\"<lane>\": {...\"effort\": \"<value>\"" is exact enough here and
            // avoids pulling a JSON parser into a .NET Framework console exe.
            Match block = Regex.Match(text,
                "\"" + Regex.Escape(lane) + "\"\\s*:\\s*\\{(?<body>.*?)\\}",
                RegexOptions.Singleline);
            Match effort = Regex.Match(block.Success ? block.Groups["body"].Value : "",
                "\"effort\"\\s*:\\s*\"([^\"]*)\"");
            if (effort.Success && effort.Groups[1].Value.Length > 0)
            {
                return effort.Groups[1].Value;
            }
            WriteColour(ConsoleColor.DarkYellow,
                "  lanes.json has no effort for " + lane + " - using the reference default");
        }
        catch (Exception exc)
        {
            WriteColour(ConsoleColor.DarkYellow,
                "  lanes.json unreadable (" + exc.Message + ") - using the reference default");
        }
        string fallback;
        return ReferenceEfforts.TryGetValue(lane, out fallback) ? fallback : "xhigh";
    }
}
