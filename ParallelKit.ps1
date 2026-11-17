# ParallelKit - parallel runspace jobs, bounded external-process dispatch, and
# graceful Ctrl+C/window-close handling for Windows PowerShell 5.1 and
# PowerShell 7.
#
# Version 3.2 - https://github.com/HalRiveria/PowerShell-ParallelKit
# (Initialize-ParallelKit reports the version too: change both together.)
# Copyright (c) 2026 HalRiveria. MIT License: keep this notice with any copy;
# the full text is in LICENSE in the repository.
#
# Use:   . "<path>\ParallelKit.ps1"     (dot-source it; it loads itself as an in-memory module)
# Read README.md first: its two worker-code rules are what keep this from
# hanging or crashing.
#
# Works under Set-StrictMode: read job hashtables as $job['Name'], never
# $job.Name, which throws there for a key that isn't set yet. State lives in
# the static [PkState] class, never in $script: variables: a function called
# from a .GetNewClosure() block can see an empty $script: scope.

# Add-Type needs FullLanguage: say so, rather than fail on Add-Type's error.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw ("ParallelKit: this PowerShell session runs in " + $ExecutionContext.SessionState.LanguageMode + " mode, but the kit needs FullLanguage " +
        "(it compiles C# with Add-Type). This is usually set by AppLocker or Windows Defender Application Control policy. " +
        "Ask whoever manages the machine to allow this script, or run it where that policy doesn't apply.")
}

# Loads as an in-memory module, so a callback you pass in sees your
# variables, never the kit's, and the private helpers stay out of your
# session. A copy loaded earlier is removed first. -ErrorAction Stop makes a
# throw in here (the stale-types check) stop the script that loads the kit.
Get-Module -Name ParallelKit | Remove-Module
New-Module -Name ParallelKit -ErrorAction Stop -ScriptBlock {

# ==============================================================================
#  Native types (guarded so the file can be dot-sourced more than once)
# ==============================================================================

if (-not ([System.Management.Automation.PSTypeName]'PkConsoleCtrl').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class PkConsoleCtrl
{
    public delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Set by the handler (or Request-PkAbort); polled by PowerShell code.
    public static volatile bool AbortRequested = false;
    public static volatile bool IsCloseEvent   = false;   // true = window close/logoff/shutdown, false = Ctrl+C

    // The handler only acts while a run is active.
    public static volatile bool RunActive = false;

    // On a window close, logoff or shutdown the handler parks on this until
    // the run ends, since the process dies as soon as the handler returns.
    // Ctrl+C never parks.
    public static readonly ManualResetEventSlim DrainComplete = new ManualResetEventSlim(false);
    public static int DrainWaitMs = 65000;

    // Ctrl+C presses: the first starts the abort, the next skips the drain
    // (force-stops running jobs now), the one after that is let through to
    // PowerShell, which stops the script. A press within SkipDebounceMs of
    // the last counted one is a double tap or key repeat, and is ignored.
    public static volatile bool SkipDrain = false;
    public static volatile string PressedKey = null;   // "Ctrl+C" / "Ctrl+Break" once a press started the abort
    public static int SkipDebounceMs = 1000;
    private static long _lastPressTimestamp = 0;
    private static readonly object _pressLock = new object();

    private static HandlerRoutine _handler;   // strong ref so the GC can't collect it
    public static bool LastRegisterSucceeded = false;

    public static void Register()
    {
        // SetConsoleCtrlHandler is additive - drop the previous delegate
        // first so a second Register() can't leave an unrooted one behind.
        if (_handler != null) { SetConsoleCtrlHandler(_handler, false); }
        _handler = new HandlerRoutine(Handler);
        LastRegisterSucceeded = SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if (!RunActive) { return false; }
        if (ctrlType == 0 || ctrlType == 1)
        {
            // Never park here: Windows delivers one console event at a time, so
            // a parked Ctrl+C would hold back the next press and a window close.
            return OnInterrupt(ctrlType == 1 ? "Ctrl+Break" : "Ctrl+C");
        }
        if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            // IsCloseEvent BEFORE AbortRequested: a poller that sees
            // AbortRequested must already see the right IsCloseEvent.
            IsCloseEvent   = true;
            AbortRequested = true;
            DrainComplete.Wait(DrainWaitMs);
            return true;   // suppress the default OS action
        }
        return false;
    }

    // One Ctrl+C/Ctrl+Break press during a run. Public so tests can press it.
    // true = handled here; false = let PowerShell's own Ctrl+C stop the script.
    public static bool OnInterrupt(string key)
    {
        lock (_pressLock)
        {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (!AbortRequested)
            {
                PressedKey = key;
                _lastPressTimestamp = now;
                AbortRequested = true;
                return true;
            }
            // An abort is already under way (this press, Request-PkAbort or a
            // close). A press that follows a counted one too closely is ignored.
            if (_lastPressTimestamp != 0)
            {
                double sinceLastMs = (now - _lastPressTimestamp) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                if (sinceLastMs < SkipDebounceMs) { return true; }
            }
            _lastPressTimestamp = now;
            if (!SkipDrain) { SkipDrain = true; return true; }
            return false;
        }
    }

    public static void ResetPresses()
    {
        lock (_pressLock)
        {
            SkipDrain = false;
            PressedKey = null;
            _lastPressTimestamp = 0;
        }
    }
}

// Keeps the PC from idle-sleeping while a run is going. Per-thread: lifted
// by the same thread that set it, and dropped by Windows if the process ends.
public static class PkSleepBlock
{
    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);
    public static bool Block()   { return SetThreadExecutionState(0x80000000u | 0x00000001u) != 0; }
    public static bool Unblock() { return SetThreadExecutionState(0x80000000u) != 0; }
}

// Main-thread bookkeeping. Static on purpose - see the note at the top of
// ParallelKit.ps1.
public static class PkState
{
    public static bool AbortLatched = false;
    public static bool CloseAbort   = false;
    public static object MessageHandler = null;   // a PowerShell scriptblock, or null for the default
    public static volatile bool ThreadPoolRaised = false;

    // Bump this, and the check after the type definitions, whenever any C#
    // in this file changes: a session keeps the types it compiled first.
    public const int TypesVersion = 7;

    // Locked: Register-/Unregister-PkCancellationSource are callable from
    // worker runspaces, and List<T> is not safe for concurrent writers.
    private static readonly List<CancellationTokenSource> _sources = new List<CancellationTokenSource>();
    private static readonly object _sourcesLock = new object();

    public static void AddSource(CancellationTokenSource cts) { lock (_sourcesLock) { _sources.Add(cts); } }
    public static bool RemoveSource(CancellationTokenSource cts) { lock (_sourcesLock) { return _sources.Remove(cts); } }
    public static CancellationTokenSource[] SnapshotSources() { lock (_sourcesLock) { return _sources.ToArray(); } }
    public static int SourceCount { get { lock (_sourcesLock) { return _sources.Count; } } }
}
'@ -Language CSharp
}

if (-not ([System.Management.Automation.PSTypeName]'PkConsoleQuickEdit').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Console QuickEdit mode freezes the whole process while the user has text
// selected. Invoke-PkRun turns it off for the length of a run.
public static class PkConsoleQuickEdit
{
    private const int STD_INPUT_HANDLE = -10;
    private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    private const uint ENABLE_EXTENDED_FLAGS  = 0x0080;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    // 1 = on, 0 = off, -1 = can't tell (no real console).
    public static int GetEnabled()
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return -1; }
        uint mode;
        if (!GetConsoleMode(handle, out mode)) { return -1; }
        return (mode & ENABLE_QUICK_EDIT_MODE) != 0 ? 1 : 0;
    }

    public static bool SetEnabled(bool enabled)
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return false; }
        uint mode;
        if (!GetConsoleMode(handle, out mode)) { return false; }
        if (enabled) { mode |= ENABLE_QUICK_EDIT_MODE; } else { mode &= ~ENABLE_QUICK_EDIT_MODE; }
        mode |= ENABLE_EXTENDED_FLAGS;
        return SetConsoleMode(handle, mode);
    }
}
'@ -Language CSharp
}

if (-not ([System.Management.Automation.PSTypeName]'PkChildProcessJob').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class PkStartedProcess
{
    public Process Process;
    public StreamReader Stdout;
    public StreamReader Stderr;
}

// Reads one of a program's output streams to its end, in chunks, so what has
// arrived can be taken at any time (Snapshot): a program the program started
// can hold the stream open long after it exits. The task's result is the
// whole text, at the end of the stream. The reader's decoder carries a
// character split across two reads over to the next, so a snapshot never
// ends in half a character. A read blocks a thread-pool thread, as
// ReadToEndAsync did; it ends when every holder of the stream's write end
// has let go (at the latest when PowerShell exits: they're in the Job Object).
public sealed class PkStreamReadTask : Task<string>
{
    private sealed class Buffer
    {
        private readonly TextReader _reader;
        private StringBuilder _text = new StringBuilder();
        private string _final;
        private readonly object _gate = new object();
        public Buffer(TextReader reader) { _reader = reader; }
        public string Pump()
        {
            char[] chunk = new char[4096];
            int n;
            while ((n = _reader.Read(chunk, 0, chunk.Length)) > 0)
            {
                lock (_gate) { _text.Append(chunk, 0, n); }
            }
            // The builder goes once the text is final, so it isn't held twice.
            lock (_gate) { _final = _text.ToString(); _text = null; return _final; }
        }
        // Locked: the reader may be appending while Complete-PkProcess takes it.
        public string Snapshot() { lock (_gate) { return _final != null ? _final : _text.ToString(); } }
    }

    private readonly Buffer _buffer;
    private PkStreamReadTask(Buffer buffer) : base(new Func<string>(buffer.Pump)) { _buffer = buffer; }

    public static PkStreamReadTask Run(TextReader reader)
    {
        PkStreamReadTask task = new PkStreamReadTask(new Buffer(reader));
        task.Start(TaskScheduler.Default);
        return task;
    }

    // The text that has arrived so far; all of it once the task has finished.
    public string Snapshot() { return _buffer.Snapshot(); }
}

// A Windows Job Object with KILL_ON_JOB_CLOSE: every child process assigned
// to it dies when this process exits for ANY reason, force-kill included.
public static class PkChildProcessJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    // Never closed: Windows closes it when this process exits, and that is
    // what kills the children.
    private static IntPtr _job = IntPtr.Zero;
    private static readonly object _lock = new object();

    public static bool IsInitialized { get { return _job != IntPtr.Zero; } }
    public static int LastError { get; private set; }

    public static bool Initialize()
    {
        lock (_lock)
        {
            if (_job != IntPtr.Zero) { return true; }
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { LastError = Marshal.GetLastWin32Error(); return false; }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    LastError = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    return false;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
            _job = job;
            return true;
        }
    }

    // Never throws: a failed assignment only loses the force-kill cleanup
    // for that one process.
    public static bool Assign(System.Diagnostics.Process process)
    {
        if (_job == IntPtr.Zero || process == null) { return false; }
        try
        {
            if (AssignProcessToJobObject(_job, process.Handle)) { return true; }
            LastError = Marshal.GetLastWin32Error();
            return false;
        }
        catch { return false; }
    }

    // ---- Starting a program inside the job from its first instruction ----
    //
    // Process.Start can only be followed by Assign, so a program that starts a
    // child straight away (cmd /c tool.exe) can do so before it's in the job,
    // and that child survives a force-kill. TryStart has Windows put the
    // program in the job as it creates it (PROC_THREAD_ATTRIBUTE_JOB_LIST,
    // Windows 10 / Server 2016+), so its children join too.
    //
    // Everything else copies Process.Start with UseShellExecute = false:
    // command line, Windows' own search for a bare name, CREATE_NO_WINDOW,
    // stdin, redirected stdout/stderr, and the default encoding.
    //
    // The pipe ends the child writes to must be inheritable while it's
    // created, and a plain Process.Start elsewhere in PowerShell inherits
    // every inheritable handle: it would hold our output open until it exits.
    // .NET's own start lock keeps those apart, so TryStart takes it (found by
    // reflection) and returns null, for Process.Start plus Assign, when it
    // isn't there in a form it knows. The handle list keeps our child from
    // inheriting anyone else's handles.

    private const uint CREATE_SUSPENDED = 0x4;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x400;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x80000;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const int STARTF_USESTDHANDLES = 0x100;
    private const int STD_INPUT_HANDLE = -10;
    private const uint HANDLE_FLAG_INHERIT = 1;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = (IntPtr)0x20002;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = (IntPtr)0x2000D;

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public int bInheritHandle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetHandleInformation(IntPtr hObject, out uint lpdwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute,
        IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll")]
    private static extern uint GetConsoleOutputCP();

    // .NET's process-start lock: a plain object (5.1, 7.6) is held with
    // Monitor; a System.Threading.Lock (where newer .NET is moving its locks)
    // through its own Enter/Exit, by reflection since 5.1 has no such type.
    // Monitor on a Lock wouldn't keep out its Enter, hence the type check.
    private sealed class StartLock
    {
        public readonly string Kind;
        private readonly object _obj;
        private readonly MethodInfo _enter, _exit;

        private StartLock(string kind, object obj, MethodInfo enter, MethodInfo exit)
        {
            Kind = kind; _obj = obj; _enter = enter; _exit = exit;
        }

        public static StartLock From(object candidate, string fieldName)
        {
            if (candidate == null) { return null; }
            Type t = candidate.GetType();
            if (t == typeof(object)) { return new StartLock("Monitor:" + fieldName, candidate, null, null); }
            if (t.FullName == "System.Threading.Lock")
            {
                BindingFlags bf = BindingFlags.Public | BindingFlags.Instance;
                MethodInfo enter = t.GetMethod("Enter", bf, null, Type.EmptyTypes, null);
                MethodInfo exit = t.GetMethod("Exit", bf, null, Type.EmptyTypes, null);
                if (enter != null && exit != null && enter.ReturnType == typeof(void) && exit.ReturnType == typeof(void))
                {
                    return new StartLock("Lock:" + fieldName, candidate, enter, exit);
                }
            }
            return null;
        }

        public void Enter()
        {
            if (_enter == null) { Monitor.Enter(_obj); return; }
            try { _enter.Invoke(_obj, null); }
            catch (TargetInvocationException e) { throw e.InnerException; }
        }

        public void Exit()
        {
            if (_exit == null) { Monitor.Exit(_obj); return; }
            try { _exit.Invoke(_obj, null); }
            catch (TargetInvocationException e) { throw e.InnerException; }
        }
    }

    private static StartLock _startLock;
    private static bool _startLockLooked;

    private static StartLock GetStartLock()
    {
        lock (_lock)
        {
            if (_startLockLooked) { return _startLock; }
            _startLockLooked = true;
            // .NET Framework: s_CreateProcessLock. .NET (Core) on Windows: s_createProcessLock.
            string[] names = new string[] { "s_CreateProcessLock", "s_createProcessLock" };
            foreach (string n in names)
            {
                try
                {
                    FieldInfo f = typeof(Process).GetField(n, BindingFlags.NonPublic | BindingFlags.Static);
                    if (f == null) { continue; }
                    StartLock l = StartLock.From(f.GetValue(null), n);
                    if (l != null) { _startLock = l; break; }
                }
                catch { }   // reflection refused or the field changed: try the next name, else Process.Start
            }
            return _startLock;
        }
    }

    // How TryStart holds .NET's start lock ("Monitor:<field>" or
    // "Lock:<field>"), or null when it can't and the kit uses Process.Start.
    public static string StartLockKind { get { StartLock l = GetStartLock(); return l == null ? null : l.Kind; } }

    // Harness only: makes TryStart return null, to test the Process.Start path.
    public static bool TestUseProcessStart = false;
    // Harness only: make a start's setup fail, or building its output readers.
    public static bool TestFailSetup = false;
    public static bool TestFailReaders = false;

    // How programs start here, for Initialize-ParallelKit: "CreatedInJob"
    // (TryStart), "AddedToJob" (Process.Start, then the job: no usable start
    // lock, or the harness switch), or "NoJob" (the job couldn't be set up,
    // so nothing is cleaned up on a kill). A single start can still fall back
    // from CreatedInJob when its setup fails; that warns.
    public static string StartMode
    {
        get
        {
            if (_job == IntPtr.Zero) { return "NoJob"; }
            if (TestUseProcessStart || GetStartLock() == null) { return "AddedToJob"; }
            return "CreatedInJob";
        }
    }

    // The fallback warning is shown once per process: true for the first caller.
    private static int _fallbackWarned = 0;
    public static bool ClaimFallbackWarning() { return Interlocked.Exchange(ref _fallbackWarned, 1) == 0; }
    public static void TestResetFallbackWarning() { Interlocked.Exchange(ref _fallbackWarned, 0); }

    private static StringBuilder BuildCommandLine(string fileName, string arguments)
    {
        // As Process.Start builds it: the program quoted unless it already is.
        StringBuilder sb = new StringBuilder();
        string f = fileName.Trim();
        bool quoted = f.Length > 1 && f.StartsWith("\"", StringComparison.Ordinal) && f.EndsWith("\"", StringComparison.Ordinal);
        if (!quoted) { sb.Append('"'); }
        sb.Append(f);
        if (!quoted) { sb.Append('"'); }
        if (!String.IsNullOrEmpty(arguments)) { sb.Append(' '); sb.Append(arguments); }
        return sb;
    }

    private static void CreateOutputPipe(out IntPtr read, out IntPtr write)
    {
        SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
        sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        sa.bInheritHandle = 1;
        if (!CreatePipe(out read, out write, ref sa, 0)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        if (!SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0))
        {
            int e = Marshal.GetLastWin32Error();
            CloseHandle(read); CloseHandle(write);
            read = IntPtr.Zero; write = IntPtr.Zero;
            throw new Win32Exception(e);
        }
    }

    // Starts the program in the job, or returns null when it can't do that
    // safely: the caller then uses Process.Start and Assign. fallbackReason
    // says why, for the caller's one-time warning; it stays null where no
    // warning is due (no job, which has its own; the harness switch). Throws
    // Win32Exception when Windows refuses to create the program, as
    // Process.Start does. encoding null: the console's output code page.
    public static PkStartedProcess TryStart(string fileName, string arguments, string workingDirectory, Encoding encoding, out string fallbackReason)
    {
        fallbackReason = null;
        if (TestUseProcessStart || _job == IntPtr.Zero) { return null; }
        StartLock startLock = GetStartLock();
        if (startLock == null) { fallbackReason = ".NET's process-start lock isn't where the kit expects it on this .NET version"; return null; }
        if (encoding == null)
        {
            try { encoding = Encoding.GetEncoding((int)GetConsoleOutputCP()); }
            catch { encoding = Console.OutputEncoding; }   // a code page this runtime can't decode: what PowerShell itself uses
        }
        StringBuilder commandLine = BuildCommandLine(fileName, arguments);

        IntPtr outRead = IntPtr.Zero, outWrite = IntPtr.Zero, errRead = IntPtr.Zero, errWrite = IntPtr.Zero;
        IntPtr attrList = IntPtr.Zero, handleArr = IntPtr.Zero, jobArr = IntPtr.Zero;
        bool attrReady = false, created = false, setupFailed = false;
        IntPtr stdin = IntPtr.Zero;
        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();

        startLock.Enter();
        try
        {
            try
            {
                // Setup: a failure here falls back to Process.Start and Assign
                // (3.1's way) instead of failing the start. Only CreateProcess
                // itself, below, reports that the program couldn't start.
                try
                {
                    CreateOutputPipe(out outRead, out outWrite);
                    CreateOutputPipe(out errRead, out errWrite);

                    // stdin as Process.Start passes it: PowerShell's own. Listed
                    // only if inheritable, the only case the child could use it.
                    stdin = GetStdHandle(STD_INPUT_HANDLE);
                    uint hflags;
                    bool stdinInherit = stdin != IntPtr.Zero && stdin != new IntPtr(-1)
                        && GetHandleInformation(stdin, out hflags) && (hflags & HANDLE_FLAG_INHERIT) != 0;
                    int handleCount = stdinInherit ? 3 : 2;
                    handleArr = Marshal.AllocHGlobal(IntPtr.Size * handleCount);
                    Marshal.WriteIntPtr(handleArr, 0, outWrite);
                    Marshal.WriteIntPtr(handleArr, IntPtr.Size, errWrite);
                    if (stdinInherit) { Marshal.WriteIntPtr(handleArr, 2 * IntPtr.Size, stdin); }
                    jobArr = Marshal.AllocHGlobal(IntPtr.Size);
                    Marshal.WriteIntPtr(jobArr, _job);

                    IntPtr size = IntPtr.Zero;
                    InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);   // fails by design: returns the size
                    attrList = Marshal.AllocHGlobal(size);
                    if (!InitializeProcThreadAttributeList(attrList, 2, 0, ref size)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    attrReady = true;
                    if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleArr,
                            (IntPtr)(IntPtr.Size * handleCount), IntPtr.Zero, IntPtr.Zero)
                        || !UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, jobArr,
                            (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    if (TestFailSetup) { throw new Win32Exception(5); }
                }
                catch (Win32Exception e)
                {
                    setupFailed = true;
                    fallbackReason = "setting up a start inside the Job Object failed (" + e.Message + ")";
                }
                if (setupFailed) { return null; }   // the finally blocks below clean up and release the lock

                STARTUPINFOEX si = new STARTUPINFOEX();
                si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                si.StartupInfo.hStdInput = stdin;
                si.StartupInfo.hStdOutput = outWrite;
                si.StartupInfo.hStdError = errWrite;
                si.lpAttributeList = attrList;

                // Suspended only until the Process object below has its handle:
                // the program is in the job already, so nothing can escape.
                uint flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
                string dir = String.IsNullOrEmpty(workingDirectory) ? null : workingDirectory;
                if (!CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, dir, ref si, out pi))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                created = true;
            }
            finally
            {
                if (attrReady) { DeleteProcThreadAttributeList(attrList); }
                if (attrList != IntPtr.Zero) { Marshal.FreeHGlobal(attrList); }
                if (handleArr != IntPtr.Zero) { Marshal.FreeHGlobal(handleArr); }
                if (jobArr != IntPtr.Zero) { Marshal.FreeHGlobal(jobArr); }
                // The child has its own copies; ours must go, or reading its
                // output never reaches the end.
                if (outWrite != IntPtr.Zero) { CloseHandle(outWrite); }
                if (errWrite != IntPtr.Zero) { CloseHandle(errWrite); }
                if (!created)
                {
                    if (outRead != IntPtr.Zero) { CloseHandle(outRead); }
                    if (errRead != IntPtr.Zero) { CloseHandle(errRead); }
                }
            }
        }
        finally { startLock.Exit(); }

        // Everything up to the resume is guarded, the output readers included:
        // if any step fails, the program (still suspended) is ended and every
        // handle released, so nothing is left running untracked.
        Process proc = null;
        SafeFileHandle outSafe = null, errSafe = null;
        StreamReader stdoutReader = null, stderrReader = null;
        try
        {
            proc = Process.GetProcessById(pi.dwProcessId);
            IntPtr opened = proc.Handle;   // taken while it's suspended, so ExitCode stays readable however fast it exits
            outSafe = new SafeFileHandle(outRead, true);
            errSafe = new SafeFileHandle(errRead, true);
            if (TestFailReaders) { throw new IOException("Test: building the output readers failed."); }
            stdoutReader = new StreamReader(new FileStream(outSafe, FileAccess.Read, 4096, false), encoding, true, 4096);
            stderrReader = new StreamReader(new FileStream(errSafe, FileAccess.Read, 4096, false), encoding, true, 4096);
            if (ResumeThread(pi.hThread) == 0xFFFFFFFF) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
        catch
        {
            TerminateProcess(pi.hProcess, 1);
            // A reader owns its handle; a SafeFileHandle not yet in a reader
            // owns its own; before either, the raw handle is closed directly.
            if (stdoutReader != null) { stdoutReader.Dispose(); }
            if (outSafe != null) { outSafe.Dispose(); } else { CloseHandle(outRead); }
            if (stderrReader != null) { stderrReader.Dispose(); }
            if (errSafe != null) { errSafe.Dispose(); } else { CloseHandle(errRead); }
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            if (proc != null) { proc.Dispose(); }
            throw;
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);

        PkStartedProcess r = new PkStartedProcess();
        r.Process = proc;
        r.Stdout = stdoutReader;
        r.Stderr = stderrReader;
        return r;
    }
}
'@ -Language CSharp
}

# A session that loaded an older copy keeps its compiled types. Say so,
# rather than fail later with a missing-method error. Keep this number in
# sync with [PkState]::TypesVersion.
if ((& { try { [PkState]::TypesVersion } catch { 0 } }) -ne 7) {
    throw "ParallelKit: this PowerShell session already loaded an older version of the kit, and its compiled parts can't be swapped out. Close this window and start a new one."
}

# Set in a worker by Invoke-PkRunspaceJobs, null elsewhere: how kit
# functions tell where they run. Defined here for strict mode.
if (-not (Test-Path -LiteralPath 'Variable:\global:PkWorkerQueue')) { $global:PkWorkerQueue = $null }
if (-not (Test-Path -LiteralPath 'Variable:\global:PkCancelToken')) { $global:PkCancelToken = $null }

# ==============================================================================
#  Messages
# ==============================================================================

function Set-PkMessageHandler {
    # .SYNOPSIS
    # Sends every message the kit writes to your own scriptblock.
    # .DESCRIPTION
    # The handler gets ($Message, $Level), where Level is Info, Warn or Error, and
    # always runs on the main thread, including for messages from worker code. If it
    # throws, the message is shown on the console instead and the run carries on.
    # Leave it early with return: continue and break end it too, but warn once.
    # .PARAMETER Handler
    # { param($Message, $Level) ... }, or $null to go back to the default (console).
    # .EXAMPLE
    # Set-PkMessageHandler { param($Message, $Level) Add-Content run.log "$Level $Message" }
    [CmdletBinding()]
    param([scriptblock]$Handler)
    [PkState]::MessageHandler = $Handler
}

function Invoke-PkMessageHandler {
    # Main thread only.
    param([string]$Message, [string]$Level = 'Info')
    $handler = [PkState]::MessageHandler
    if ($null -ne $handler) {
        try {
            # Invoke-PkCallback's do/while, inlined: its warning is itself a
            # message. Warns on the console, once per handler (a note on the
            # scriptblock).
            $handlerDone = $false
            do { $null = & $handler $Message $Level; $handlerDone = $true } while ($false)
            if (-not $handlerDone -and $null -eq $handler.PSObject.Properties['PkLoopWarned']) {
                $handler.PSObject.Properties.Add([psnoteproperty]::new('PkLoopWarned', $true))
                Write-Host "[ParallelKit] the message handler used 'continue' or 'break'. PowerShell sends those to the nearest loop, which here is one of the kit's, so the kit stopped the handler there instead. Use 'return' to leave it early." -ForegroundColor Yellow
            }
            return
        } catch {
            # A failing handler (a locked log file, say) mustn't stop the run:
            # show this message on the console instead.
            Write-Host ("[ParallelKit] message handler failed (" + $_ + ") - showing the message here instead:") -ForegroundColor Yellow
        }
    }
    $color = switch ($Level) { 'Error' { 'Red' } 'Warn' { 'Yellow' } default { $null } }
    if ($color) { Write-Host $Message -ForegroundColor $color } else { Write-Host $Message }
}

function Write-PkMessage {
    # .SYNOPSIS
    # Writes a message through the kit's message handler. Safe to call from worker code.
    # .DESCRIPTION
    # In a worker runspace the message is queued and the main thread delivers it; on
    # the main thread it goes straight to the handler (see Set-PkMessageHandler).
    # .PARAMETER Message
    # The text.
    # .PARAMETER Level
    # Info (the default), Warn or Error. Warning also works and is passed on as
    # Warn. Anything else is an error.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Warning')]
        [string]$Level = 'Info'
    )
    # Handlers only ever see Info, Warn or Error, spelled that way:
    # ValidateSet ignores case. Done before a worker queues it.
    switch ($Level) {
        'Error' { $Level = 'Error' }
        'Info'  { $Level = 'Info' }
        default { $Level = 'Warn' }
    }
    if ($null -ne $global:PkWorkerQueue) {
        $global:PkWorkerQueue.Enqueue(@{ Message = $Message; Level = $Level })
        return
    }
    Invoke-PkMessageHandler -Message $Message -Level $Level
}

function Receive-PkWorkerMessages {
    # Main thread only: deliver everything workers have queued so far.
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)
    if ($null -eq $Queue) { return }
    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        Invoke-PkMessageHandler -Message $item.Message -Level $item.Level
    }
}

function Invoke-PkCallback {
    # Calls one of the caller's callbacks and returns its output. A `continue`
    # or `break` in a callback goes to the nearest loop on the call stack, even
    # across the module boundary: one of the kit's, which then skips its
    # bookkeeping or never ends. This do/while catches it instead, so it ends
    # only the callback, like `return`. A labeled `break outer` still reaches
    # the caller's loop. Inlined where a callback runs per job or per result
    # (on 5.1 this call more than doubled the dispatcher's own time per job),
    # and in Invoke-PkMessageHandler.
    # pk-prefixed: in a worker, a callback without .GetNewClosure() sees this frame.
    param(
        [Parameter(Mandatory)][scriptblock]$PkCallback,
        [object[]]$PkArgs = @(),
        [Parameter(Mandatory)][string]$PkName,
        [hashtable]$PkContext
    )
    $pkCompleted = $false
    $pkOutput = do { & $PkCallback @PkArgs; $pkCompleted = $true } while ($false)
    if (-not $pkCompleted) { Write-PkCallbackLoopWarning -PkName $PkName -PkContext $PkContext }
    # The comma keeps a collection returned whole (`return ,$list`) one value.
    if ($null -ne $pkOutput) { return ,$pkOutput }
}

function Write-PkCallbackLoopWarning {
    # For a callback that used continue/break (see Invoke-PkCallback). Warns
    # once per -PkName in a run. -PkContext is the run's @{ Prefix; Warned }:
    # Prefix names the engine, Warned the names already warned about.
    param([string]$PkName, [hashtable]$PkContext)
    $pkFullName = $PkName
    if ($null -ne $PkContext) {
        $pkWarned = $PkContext['Warned']
        if ($pkWarned.ContainsKey($PkName)) { return }
        $pkWarned[$PkName] = $true
        $pkFullName = [string]$PkContext['Prefix'] + $PkName
    }
    Write-PkMessage ($pkFullName + " used 'continue' or 'break' outside a loop of its own. PowerShell sends those to the nearest loop, which here is one of the kit's, so the kit stopped the callback there instead. Use 'return' to leave a callback early.") -Level Warn
}

# ==============================================================================
#  Abort handling
# ==============================================================================

function Register-PkAbortHandler {
    [PkConsoleCtrl]::Register()
    if (-not [PkConsoleCtrl]::LastRegisterSucceeded) {
        Invoke-PkMessageHandler -Level Warn -Message "[WARNING] Could not register the Ctrl+C/window-close handler - aborting a run may not drain gracefully (Ctrl+C will use the OS default action instead)."
    }
    return [PkConsoleCtrl]::LastRegisterSucceeded
}

function Initialize-PkChildProcessJob {
    if ([PkChildProcessJob]::Initialize()) { return $true }
    Invoke-PkMessageHandler -Level Warn -Message ("[WARNING] Could not set up child-process cleanup (Win32 error " + [PkChildProcessJob]::LastError + ") - if this window is force-closed mid-run, a running child process may be left behind and need ending in Task Manager.")
    return $false
}

function Initialize-PkThreadPool {
    # Each redirected child holds two pool threads for its output reads, and
    # the pool grows slowly past its minimum, so a burst of processes could
    # stall their reads. Raise the minimum up front.
    param([int]$MaxConcurrentProcesses = 0)
    $clampedProcs = [Math]::Min([Math]::Max($MaxConcurrentProcesses, 0), 16000)
    $minimumWorkerThreads = [Math]::Max(128, (2 * $clampedProcs) + 32)
    $worker = 0; $io = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
    [PkState]::ThreadPoolRaised = $true
    if ($worker -ge $minimumWorkerThreads) { return $true }
    return [System.Threading.ThreadPool]::SetMinThreads($minimumWorkerThreads, $io)
}

function Initialize-ParallelKit {
    # .SYNOPSIS
    # Sets up Ctrl+C handling, child-process cleanup and the thread pool up front. Optional.
    # .DESCRIPTION
    # The engines set up what they need on first use anyway. Safe to call more than
    # once. A failed Ctrl+C handler or child-process cleanup also prints a warning.
    # .PARAMETER MaxConcurrentProcesses
    # How many programs you expect to run at once, used to size the thread pool.
    # 0 (the default) sizes it for up to about 48.
    # .OUTPUTS
    # An object with AbortHandler, ChildProcessJob and ThreadPool, each $true if that
    # part worked; Version, the kit's version; and StartMode, how the kit starts
    # programs here: CreatedInJob (inside the Job Object, so anything they start
    # is in it too), AddedToJob (started, then added to it just after), or NoJob
    # (no cleanup if PowerShell is killed). A program whose start can't be set up
    # in the job falls back to AddedToJob, with a warning.
    [CmdletBinding()]
    param([int]$MaxConcurrentProcesses = 0)
    $handlerOk = Register-PkAbortHandler
    $jobOk     = Initialize-PkChildProcessJob
    $poolOk    = Initialize-PkThreadPool -MaxConcurrentProcesses $MaxConcurrentProcesses
    # The header's Version line: the version PR changes both, and the harness
    # checks they match.
    $version = [version]'3.2'
    return [pscustomobject][ordered]@{ AbortHandler = $handlerOk; ChildProcessJob = $jobOk; ThreadPool = $poolOk; Version = $version; StartMode = [PkChildProcessJob]::StartMode }
}

function Register-PkCancellationSource {
    # .SYNOPSIS
    # Adds your own CancellationTokenSource to the set an abort cancels.
    # .DESCRIPTION
    # Every registered source is canceled the moment an abort is detected. If an
    # abort is still in force when you register (see Reset-PkAbortState), the source
    # is canceled right away. A -Cts passed to Invoke-PkRunspaceJobs is
    # registered for you. Remove it with Unregister-PkCancellationSource when done.
    # .PARAMETER Cts
    # The source to cancel on an abort.

    # Canceled at once while an old abort is in force: otherwise a later run
    # would start while its workers, seeing the old flag, did nothing.
    param([Parameter(Mandatory)][System.Threading.CancellationTokenSource]$Cts)
    [PkState]::AddSource($Cts)
    if ([PkState]::AbortLatched) {
        try { $Cts.Cancel() } catch { }   # an already-disposed source has nothing left to cancel
    }
}

function Unregister-PkCancellationSource {
    # .SYNOPSIS
    # Removes a source added with Register-PkCancellationSource.
    # .PARAMETER Cts
    # The source to remove.
    param([Parameter(Mandatory)][System.Threading.CancellationTokenSource]$Cts)
    $null = [PkState]::RemoveSource($Cts)
}

function Reset-PkAbortState {
    # .SYNOPSIS
    # Clears a finished abort so the engines run again.
    # .DESCRIPTION
    # An abort stays in force until this is called: until then every engine returns
    # right away with Aborted = $true. Invoke-PkRun calls it at the start of each
    # run, so you only need it to call an engine again outside Invoke-PkRun after an
    # abort.

    # Deliberately leaves RunActive alone: that belongs to Invoke-PkRun, and
    # clearing it here would disarm a run that calls this part-way through.
    [CmdletBinding()]
    param()
    [PkState]::AbortLatched = $false
    [PkState]::CloseAbort   = $false
    [PkConsoleCtrl]::AbortRequested = $false
    [PkConsoleCtrl]::IsCloseEvent   = $false
    [PkConsoleCtrl]::ResetPresses()
    [PkConsoleCtrl]::DrainComplete.Reset()
}

function Request-PkAbort {
    # .SYNOPSIS
    # Starts an abort from code, the same as the user pressing Ctrl+C.
    [CmdletBinding()]
    param()
    [PkConsoleCtrl]::AbortRequested = $true
}

function Test-PkAbortSignal {
    # .SYNOPSIS
    # Returns $true once an abort (Ctrl+C, window close, Request-PkAbort) is under way.
    # .DESCRIPTION
    # Inside Invoke-PkRun, Ctrl+C only raises a flag. A long step of your own there
    # should check this now and then and stop when it's true. On the main thread, the
    # first call after an abort also cancels every registered source and announces
    # the abort. Worker code should use Test-PkCancelRequested instead.
    # .OUTPUTS
    # [bool]
    [CmdletBinding()]
    param()
    if ($null -ne $global:PkWorkerQueue) {
        return [PkConsoleCtrl]::AbortRequested
    }

    if ([PkConsoleCtrl]::AbortRequested -and -not [PkState]::AbortLatched) {
        [PkState]::AbortLatched = $true
        [PkState]::CloseAbort   = [PkConsoleCtrl]::IsCloseEvent
        foreach ($cts in [PkState]::SnapshotSources()) {
            try { $cts.Cancel() } catch { }   # an already-disposed source has nothing left to cancel
        }
        $pressedKey = [PkConsoleCtrl]::PressedKey
        $abortMessage = if ([PkState]::CloseAbort) {
            # No drain on a close: Windows ends the process within seconds.
            "[ABORT] Window close detected - stopping current jobs now..."
        } elseif ($null -ne $pressedKey) {
            "[ABORT] " + $pressedKey + " detected - finishing current jobs, please wait... Press Ctrl+C again to stop them now."
        } elseif ([PkConsoleCtrl]::RunActive) {
            "[ABORT] Abort requested - finishing current jobs, please wait... Press Ctrl+C to stop them now."
        } else {
            "[ABORT] Abort requested - finishing current jobs, please wait..."
        }
        Invoke-PkMessageHandler -Message $abortMessage -Level Warn
    }
    return [PkState]::AbortLatched
}

function Test-PkCancelRequested {
    # .SYNOPSIS
    # For worker code: returns $true once this run is being canceled or aborted.
    # .DESCRIPTION
    # Check it before any step that can't be undone (deleting a source file, say)
    # and skip the step if it's true: a worker that was force-stopped isn't killed,
    # and can carry on once its current .NET call returns.
    # .OUTPUTS
    # [bool]
    [CmdletBinding()]
    param()
    if ($null -ne $global:PkCancelToken -and $global:PkCancelToken.IsCancellationRequested) { return $true }
    return [PkConsoleCtrl]::AbortRequested
}

function Get-PkAbortTriggerLabel {
    # .SYNOPSIS
    # Says what started the abort: "Ctrl+C", "Ctrl+Break", "window close (X button)",
    # or "Request-PkAbort" for an abort started from code.
    # .OUTPUTS
    # [string]
    [CmdletBinding()]
    param()
    if ([PkState]::CloseAbort) { return "window close (X button)" }
    $pressedKey = [PkConsoleCtrl]::PressedKey
    if ($null -ne $pressedKey) { return $pressedKey }
    return "Request-PkAbort"
}

function Get-PkForceStopReason {
    # Why an abort is force-stopping jobs, for the engines' force-stop notice.
    param([int]$TimeoutSeconds)
    if ([PkConsoleCtrl]::IsCloseEvent) { return " now: the window is closing" }
    if ([PkConsoleCtrl]::SkipDrain)    { return " now: Ctrl+C was pressed again" }
    return (" that did not finish within " + $TimeoutSeconds + "s")
}

function Complete-PkAbortDrain {
    # Releases the native handler thread. Idempotent; safe on a run that was
    # never aborted.
    try { [PkConsoleCtrl]::DrainComplete.Set() } catch { }   # nothing useful to do if the event itself is broken
}

function Invoke-PkRun {
    # .SYNOPSIS
    # Runs a block with graceful Ctrl+C: the kit's engines wind their work down
    # instead of the script being killed.
    # .DESCRIPTION
    # Inside the block, Ctrl+C no longer kills anything by itself. It raises a flag
    # the kit's engines watch: no new work starts, running work gets time to finish,
    # and whatever is left is then stopped. A long step of your own in here must
    # check Test-PkAbortSignal now and then and stop when it's true, or Ctrl+C will
    # seem to do nothing until that step ends. Pressing Ctrl+C again, or closing the
    # window, skips the wait; a third press stops the script as Ctrl+C normally does,
    # and the kit's engines still kill the programs they started.
    #
    # For the length of the run it also keeps the PC from idle-sleeping and turns off
    # the console's QuickEdit mode. Whatever the block outputs is passed through.
    # .PARAMETER ScriptBlock
    # The work to run.
    # .PARAMETER DisableQuickEdit
    # Turn QuickEdit off during the run (default $true). With it on, one stray click
    # starts a selection and freezes the script at its next console write.
    # .PARAMETER KeepAwake
    # Stop the PC idle-sleeping during the run (default $true). The display can
    # still turn off.
    # .EXAMPLE
    # $batch = Invoke-PkRun { Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 6 }
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [bool]$DisableQuickEdit = $true,
        [bool]$KeepAwake = $true
    )
    # Already inside a run: just run it. Re-arming would wipe the outer run's
    # abort state, and disarming afterwards would leave the rest of it
    # unprotected.
    if ([PkConsoleCtrl]::RunActive) {
        & $ScriptBlock
        return
    }
    if (-not [PkConsoleCtrl]::LastRegisterSucceeded) { $null = Register-PkAbortHandler }
    if (-not [PkChildProcessJob]::IsInitialized)     { $null = Initialize-PkChildProcessJob }
    Reset-PkAbortState
    [PkConsoleCtrl]::RunActive = $true
    $quickEditWasOn = ([PkConsoleQuickEdit]::GetEnabled() -eq 1)
    if ($DisableQuickEdit -and $quickEditWasOn) { $null = [PkConsoleQuickEdit]::SetEnabled($false) }
    if ($KeepAwake) { $null = [PkSleepBlock]::Block() }
    try {
        & $ScriptBlock
    } finally {
        if ($KeepAwake) { $null = [PkSleepBlock]::Unblock() }
        if ($DisableQuickEdit -and $quickEditWasOn) { $null = [PkConsoleQuickEdit]::SetEnabled($true) }
        [PkConsoleCtrl]::RunActive = $false
        Complete-PkAbortDrain
    }
}

# ==============================================================================
#  External processes (all raw .NET - safe inside workers)
# ==============================================================================

function ConvertTo-PkArgumentString {
    # .SYNOPSIS
    # Joins a list of arguments into one command line, quoted so the program gets
    # exactly that list back.
    # .DESCRIPTION
    # An argument with a space, tab, newline or quote is wrapped in quotes, its
    # quotes become \", and backslashes are doubled where they come before a quote.
    # These are the C runtime's rules, which most Windows programs use; cmd.exe
    # parses its own way. An argument with one of & | < > ^ ( ) , ; is quoted
    # too, so a .bat or .cmd program, which runs through cmd.exe, gets it as one
    # argument instead of cmd acting on it. The kit's -Arguments and Arguments
    # values do this themselves when given a list, and for cmd.exe or a
    # batch-file program they also write a quote as "" instead of \", which
    # cmd.exe can't be tricked by. This function's own output uses \": for
    # those, give the kit the list instead. Not covered for those programs
    # either way: cmd expands %NAME% inside quotes, and splits batch arguments
    # at = (left unquoted, since some programs read NAME=value themselves).
    # .PARAMETER Arguments
    # The arguments, in order. A $null one is left out; an empty string is passed
    # as "". A file or folder object (from Get-ChildItem or Get-Item) is its full
    # path. An element that is itself a list (or a hashtable) is an error: put
    # each argument in the outer list.
    # .OUTPUTS
    # [string]
    # .EXAMPLE
    # ConvertTo-PkArgumentString @('C:\My Files\a.png', '-o', 'C:\out\a.jxl')
    #
    # Returns: "C:\My Files\a.png" -o C:\out\a.jxl

    # .NET Framework's ProcessStartInfo has no ArgumentList, hence this.
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        # Not [string[]]: binding an array held in a variable to that turns a
        # $null element into '' before it can be left out.
        [object[]]$Arguments
    )
    return (ConvertTo-PkArgumentStringCore -Arguments $Arguments)
}

function ConvertTo-PkArgumentStringCore {
    # ConvertTo-PkArgumentString's body. -ForBatchFile: for cmd.exe or a .bat
    # or .cmd, whose command line cmd.exe reads first, a quote is written ""
    # instead of \". cmd.exe counts every quote, \" included, so with \" an argument like
    # a" & del ... & " runs a second command. "" keeps the count even, and the
    # C runtime still reads it as one quote in a program the batch file passes
    # %* to. A line break would end cmd.exe's command line, so it's refused.
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Arguments,
        [switch]$ForBatchFile
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $position = 0
    foreach ($item in $Arguments) {
        $position++
        if ($null -eq $item) { continue }
        # A [string] cast would join a nested list with $OFS into one argument.
        if ($item -isnot [string] -and $item -is [System.Collections.IEnumerable]) {
            throw ("Arguments must be one string or a list of arguments, but element " + $position + " is itself a list (" + $item.GetType().Name + "). Put each argument in the outer list.")
        }
        # On 5.1 a FileInfo from Get-ChildItem casts to its bare name.
        if ($item -is [System.IO.FileSystemInfo]) { $arg = $item.FullName } else { $arg = [string]$item }
        if ($ForBatchFile -and $arg.IndexOfAny([char[]]@("`r", "`n")) -ge 0) {
            throw ("Arguments element " + $position + " contains a line break, which can't be passed to cmd.exe or a .bat or .cmd program: cmd.exe would end the command line there and drop the rest. Pass it another way (a file, an environment variable).")
        }
        # The C runtime only needs whitespace and quotes quoted. The rest are for
        # cmd.exe, which runs a .bat/.cmd: it acts on & | < > ^ ( ) outside
        # quotes and splits batch arguments at , ; Quoting them is harmless
        # to other programs.
        if ($arg.Length -gt 0 -and $arg.IndexOfAny([char[]]@(' ', "`t", "`n", "`v", '"', '&', '|', '<', '>', '^', '(', ')', ',', ';')) -lt 0) {
            $parts.Add($arg)
            continue
        }
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.Append('"')
        $backslashes = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            if ($ch -eq '"') {
                # Each backslash before a quote is doubled, then the quote
                # escaped: \" normally, "" for a batch file (see above).
                if ($ForBatchFile) {
                    $null = $sb.Append('\', 2 * $backslashes)
                    $null = $sb.Append('""')
                } else {
                    $null = $sb.Append('\', 2 * $backslashes + 1)
                    $null = $sb.Append('"')
                }
            } else {
                if ($backslashes -gt 0) { $null = $sb.Append('\', $backslashes) }
                $null = $sb.Append($ch)
            }
            $backslashes = 0
        }
        # Trailing backslashes are doubled so they don't escape the closing quote.
        if ($backslashes -gt 0) { $null = $sb.Append('\', 2 * $backslashes) }
        $null = $sb.Append('"')
        $parts.Add($sb.ToString())
    }
    return ($parts -join ' ')
}

function Resolve-PkArguments {
    # -Arguments as given -> the command line: a string as written, a list
    # quoted one argument per element (a [string] cast would join it with
    # spaces, or $OFS), a lone file or folder object as its full path.
    # -FilePath picks batch-file quoting for cmd.exe or a .bat or .cmd. A bare
    # name only finds an .exe, so a batch file always has its extension here.
    param($Arguments, [string]$FilePath = '')
    if ($null -eq $Arguments) { return '' }
    if ($Arguments -is [string]) { return $Arguments }
    if ($Arguments -is [System.Collections.IDictionary]) {
        throw ("Arguments must be one string or a list of arguments (got a " + $Arguments.GetType().Name + ").")
    }
    if ($Arguments -is [System.Collections.IEnumerable] -or $Arguments -is [System.IO.FileSystemInfo]) {
        # Windows drops trailing dots and spaces from a file name, so
        # 'run.cmd.' still runs through cmd.exe. cmd.exe itself, given a list
        # (cmd /c tool "a b"), reads its command line the same way, so it gets
        # the same quoting.
        $exeName = $FilePath.Trim().Trim('"').TrimEnd(' ', '.')
        $forBatchFile = ($exeName -match '\.(bat|cmd)$' -or $exeName -match '(^|[\\/])cmd(\.exe)?$')
        return (ConvertTo-PkArgumentStringCore -Arguments @($Arguments) -ForBatchFile:$forBatchFile)
    }
    return [string]$Arguments
}

function Resolve-PkEncoding {
    # -OutputEncoding as given (an Encoding, a code page number, or a name
    # like 'utf-8' or 'utf8') -> an Encoding, or $null for "not set".
    param($Encoding)
    if ($null -eq $Encoding -or ($Encoding -is [string] -and $Encoding -eq '')) { return $null }
    if ($Encoding -is [System.Text.Encoding]) { return $Encoding }
    # .NET Framework doesn't know the name 'utf8'; no BOM either way, since
    # this only decodes.
    if ($Encoding -is [string] -and $Encoding -in @('utf8', 'utf-8')) { return [System.Text.UTF8Encoding]::new($false) }
    try {
        if ($Encoding -is [int]) { return [System.Text.Encoding]::GetEncoding([int]$Encoding) }
        return [System.Text.Encoding]::GetEncoding([string]$Encoding)
    } catch {
        throw ("OutputEncoding '" + $Encoding + "' isn't an encoding .NET knows. Use a name like 'utf-8' or 'windows-1252', or a code page number like 65001.")
    }
}

function Resolve-PkFileSystemPath {
    # A path the way PowerShell reads it, turned into one Windows can use:
    # relative to the current location, or on a drive like Data:\ or ~.
    # Anything that isn't a file-system path to PowerShell (relative while
    # the current location is HKLM:, say) is taken relative to $Here, the
    # last file-system location.
    param([string]$Path, [string]$Here, [System.Management.Automation.SessionState]$CallerState)
    # Only a complete path goes straight through. \tools and C:tools depend on
    # a current drive and folder, which are PowerShell's here, not the process's.
    if ($Path -match '^([A-Za-z]:[\\/]|[\\/]{2})') { return $Path }
    $lookupFailed = $false
    try {
        $provider = $null
        $drive = $null
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
        if ($provider.Name -eq 'FileSystem') { return $resolved }
    } catch { $lookupFailed = $true }
    # A drive this module can't see: New-PSDrive inside the caller's function
    # makes one visible only from that function. Ask again from there, the
    # way Get-PkCallerFunction does (see its notes on InvokeScript).
    if ($lookupFailed -and $null -ne $CallerState) {
        $q = [string][char]39
        $text = @'
& {
    $pkProvider = $null
    $pkDrive = $null
    try {
        $pkResolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(__PATH__, [ref]$pkProvider, [ref]$pkDrive)
        if ($pkProvider.Name -eq 'FileSystem') { $pkResolved }
    } catch { }   # a path the caller's scope can't read either falls back below
}
'@
        $text = $text.Replace('__PATH__', $q + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Path) + $q)
        $hit = @($ExecutionContext.InvokeCommand.InvokeScript($CallerState, [scriptblock]::Create($text), @()))
        if ($hit.Count -gt 0) { return [string]$hit[0] }
    }
    # \tools while the current location is HKLM:, say: the root of that last
    # file-system location's drive, not the process's.
    if ($Path -match '^[\\/]') { return [System.IO.Path]::Combine([System.IO.Path]::GetPathRoot($Here), $Path.TrimStart('\', '/')) }
    # Not a path PowerShell can read (an unknown drive, say): this folder is the best guess.
    return [System.IO.Path]::Combine($Here, $Path)
}

function Start-PkProcess {
    # .SYNOPSIS
    # Starts one program hidden, with its output captured in the background.
    # .DESCRIPTION
    # The output is read as it arrives, so a chatty program can't stall on a full
    # pipe. The program is tied to the script and dies if the script is killed.
    # Pass what this returns to Wait-PkProcess and Complete-PkProcess. Throws if the
    # program can't be started.
    # .PARAMETER FilePath
    # The program to run. A path with a folder in it is read as PowerShell reads
    # paths: .\tool.exe and bin\tool.exe are relative to your current location, and
    # drives like Data:\ or ~ work. A bare name (tool.exe) is found the way Windows
    # finds programs, mostly on PATH. Only an .exe is found without its extension:
    # write a .cmd wrapper out in full (npm.cmd).
    # .PARAMETER Arguments
    # Its command line: one string, passed exactly as written, or a list, each
    # element one argument, quoted for you (see ConvertTo-PkArgumentString).
    # .PARAMETER WorkingDirectory
    # Where to run it. Default: your current location. Read as PowerShell reads
    # paths, so a relative path is relative to your current location, and drives
    # like Data:\ or ~ work.
    # .PARAMETER OutputEncoding
    # How to decode its output: a name like 'utf-8', a code page number, or a
    # [System.Text.Encoding]. Default: the console's code page.
    # .OUTPUTS
    # A hashtable @{ Proc; StdoutTask; StderrTask; Stopwatch }. Proc is the
    # program's Process. Read its output from StdoutTask and StderrTask: Proc's
    # own StandardOutput, StandardError and StartInfo are usually not set.
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        $Arguments = "",
        [string]$WorkingDirectory = "",
        $OutputEncoding = $null
    )
    return (Start-PkProcessCore -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -OutputEncoding $OutputEncoding -CallerState $PSCmdlet.SessionState)
}

function Start-PkProcessCore {
    # Start-PkProcess's body. -CallerState: the session of whoever called the
    # public function, for paths only visible from there. Deep inside the
    # module, $PSCmdlet no longer leads back to the caller.
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        $Arguments = "",
        [string]$WorkingDirectory = "",
        $OutputEncoding = $null,
        [System.Management.Automation.SessionState]$CallerState
    )
    $encoding = Resolve-PkEncoding -Encoding $OutputEncoding
    $commandLine = Resolve-PkArguments -Arguments $Arguments -FilePath $FilePath
    # For a caller who never ran Initialize-ParallelKit. No-ops once done.
    if (-not [PkChildProcessJob]::IsInitialized) { $null = [PkChildProcessJob]::Initialize() }
    if (-not [PkState]::ThreadPoolRaised)        { $null = Initialize-PkThreadPool }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $FilePath
    $psi.Arguments              = $commandLine
    $psi.UseShellExecute        = $false
    if ($null -ne $encoding) {
        $psi.StandardOutputEncoding = $encoding
        $psi.StandardErrorEncoding  = $encoding
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    # Relative paths mean your current location, not the process's working
    # directory, which Set-Location never changes. From a location that isn't
    # on disk (HKLM:) that's the last file-system one. If that folder is gone,
    # the process's working directory.
    $here = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    if (-not [System.IO.Directory]::Exists($here)) { $here = $null }

    # In a try/catch: a .NET call that throws doesn't reliably stop the
    # script, and a $null process would be polled forever. The path handling
    # is in here too: it throws on characters Windows doesn't allow.
    $started = $null
    try {
        if ($WorkingDirectory) {
            if ($null -ne $here) { $WorkingDirectory = Resolve-PkFileSystemPath -Path $WorkingDirectory -Here $here -CallerState $CallerState }
            $psi.WorkingDirectory = $WorkingDirectory
        } elseif ($null -ne $here) {
            $psi.WorkingDirectory = $here
        }
        # Only a path with a folder or drive in it: a bare name is left to
        # Windows' own search, which looks on PATH.
        if ($null -ne $here -and ($FilePath.Contains('\') -or $FilePath.Contains('/') -or $FilePath.Contains(':'))) {
            $psi.FileName = Resolve-PkFileSystemPath -Path $FilePath -Here $here -CallerState $CallerState
        }
        # In the job from its first instruction where possible; otherwise
        # Process.Start, and the job just after (a child it starts at once
        # can miss it then).
        $fallbackReason = $null
        $started = [PkChildProcessJob]::TryStart($psi.FileName, $psi.Arguments, $psi.WorkingDirectory, $encoding, [ref]$fallbackReason)
        if ($null -eq $started) {
            # Once per process: the cost is the same for every program after.
            if ($null -ne $fallbackReason -and [PkChildProcessJob]::ClaimFallbackWarning()) {
                Write-PkMessage ("[WARNING] Starting programs with Process.Start and adding them to the Job Object just after, because " + $fallbackReason + ". A child a program starts straight away (cmd /c tool.exe) can escape the cleanup if PowerShell is killed outright. Shown once.") -Level Warn
            }
            $proc = [System.Diagnostics.Process]::Start($psi)
        }
    } catch {
        $tried = ""
        if ($psi.FileName -ne $FilePath) { $tried = " (" + $psi.FileName + ")" }
        # Windows' reason, without PowerShell's "Exception calling <method>" wrapper.
        $reason = [string]$_
        if ($_.Exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $_.Exception.InnerException) { $reason = $_.Exception.InnerException.Message }
        # The original goes along as the inner exception: the batch reads Windows' error code from it.
        throw [System.Management.Automation.RuntimeException]::new("Start-PkProcess: could not start '" + $FilePath + "'" + $tried + ": " + $reason, $_.Exception)
    }
    # The output is read in chunks (PkStreamReadTask), so Complete-PkProcess
    # can keep what arrived when a stream times out. The two hashtables below
    # have the same four keys, and the dispatcher's default starter and the
    # batch's starter copy those keys onto their jobs: a new key goes in all
    # four places.
    if ($null -ne $started) {
        return @{
            Proc       = $started.Process
            StdoutTask = [PkStreamReadTask]::Run($started.Stdout)
            StderrTask = [PkStreamReadTask]::Run($started.Stderr)
            Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
        }
    }
    $null = [PkChildProcessJob]::Assign($proc)
    return @{
        Proc       = $proc
        StdoutTask = [PkStreamReadTask]::Run($proc.StandardOutput)
        StderrTask = [PkStreamReadTask]::Run($proc.StandardError)
        Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Stop-PkProcessTree {
    # .SYNOPSIS
    # Kills one or more programs and every program they started.
    # .DESCRIPTION
    # Uses taskkill /T, in as few calls as Windows' command-line limit allows,
    # so none is left running and holding a program's output open. If taskkill
    # can't start, fails, or is still running after 10 seconds (it's killed
    # then), each program is killed directly.
    # .PARAMETER Process
    # The program(s), such as the Proc that Start-PkProcess returns.
    # .OUTPUTS
    # [bool] For one program, $true if this call killed it, even if part of its
    # tree couldn't be killed, and $false if it had already exited. For several,
    # $true if this call killed any of them.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Diagnostics.Process[]]$Process
    )
    return Stop-PkProcessTreeCore -Process $Process
}

function Stop-PkProcessTreeCore {
    # Stop-PkProcessTree's body. The other parameters are for the harness: a
    # stand-in for taskkill, a shorter wait for it, and a shorter limit on its
    # argument list.
    param(
        [AllowEmptyCollection()]
        [System.Diagnostics.Process[]]$Process,
        [string]$TaskkillPath = (Join-Path $env:SystemRoot 'System32\taskkill.exe'),
        [int]$TaskkillWaitMs = 10000,
        [int]$MaxArgumentLength = 0
    )
    $alive = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    # A disposed Process reads $null for HasExited and Id (no throw), and an
    # empty /PID fails taskkill for the whole list, so it's left out.
    foreach ($p in $Process) { if ($null -ne $p -and $p.HasExited -eq $false -and $null -ne $p.Id) { $alive.Add($p) } }
    if ($alive.Count -eq 0) { return $false }
    $killed = $false
    # One command line for every PID passes Windows' 32,767-character limit at
    # roughly 2,500-3,000 programs, and then taskkill can't start at all: so as
    # many taskkill calls as the limit needs.
    if ($MaxArgumentLength -le 0) { $MaxArgumentLength = 32000 - $TaskkillPath.Length }
    $ids = [int[]]@(foreach ($p in $alive) { $p.Id })
    foreach ($taskkillArgs in (Split-PkTaskkillArguments -Ids $ids -MaxLength $MaxArgumentLength)) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($TaskkillPath, $taskkillArgs)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        try {
            $taskkill = [System.Diagnostics.Process]::Start($psi)
            try {
                # Read both pipes while taskkill runs: it prints a line per
                # process it kills, and on a large kill a full pipe blocks it.
                $taskkillOut = $taskkill.StandardOutput.ReadToEndAsync()
                $taskkillErr = $taskkill.StandardError.ReadToEndAsync()
                if ($taskkill.WaitForExit($TaskkillWaitMs)) {
                    if ($taskkill.ExitCode -eq 0) { $killed = $true }
                    try { $null = [System.Threading.Tasks.Task]::WaitAll(@($taskkillOut, $taskkillErr), 2000) } catch { }  # the reads only keep the pipes drained; their text isn't used
                } else {
                    # Still running after its wait (hung, or held up by security
                    # software): killed, so it isn't left running outside the
                    # Job Object. The fallback below kills the programs.
                    try { $taskkill.Kill(); $null = $taskkill.WaitForExit(2000) } catch { }  # it exited between the wait and the kill
                }
            } finally { $taskkill.Dispose() }
        } catch { }  # taskkill missing or blocked: the fallback below still kills each process itself
    }
    # taskkill fails if any process in the trees couldn't be killed, even when
    # it killed the program: one already gone (a child in another listed tree,
    # or a `cmd /c` that ended once taskkill killed its child, which it does
    # first) or one it wasn't allowed to kill. So a listed process now gone
    # counts as killed, even one that just exited on its own. Only
    # Stop-PkTimedOutJob reads the result, and it only kills overdue programs.
    if (-not $killed) {
        foreach ($p in $alive) { if ($p.HasExited) { $killed = $true; break } }
    }
    foreach ($p in $alive) {
        if (-not $p.HasExited) {
            try { $p.Kill(); $killed = $true } catch { }  # it exited between the check and the kill
        }
    }
    if ($killed) {
        foreach ($p in $alive) {
            try { $null = $p.WaitForExit(5000) } catch { }  # disposed by its owner meanwhile; one failed wait mustn't skip the others
        }
    }
    return $killed
}

function Split-PkTaskkillArguments {
    # taskkill argument lists ('/T /F /PID 1 /PID 2 ...') for these PIDs, as
    # few as fit, each at most MaxLength characters (a single PID that doesn't
    # fit still gets a list of its own). Returns a list of strings.
    param([int[]]$Ids, [int]$MaxLength)
    $lists = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new('/T /F')
    $count = 0
    foreach ($id in $Ids) {
        $part = ' /PID ' + $id
        if ($count -gt 0 -and $current.Length + $part.Length -gt $MaxLength) {
            $lists.Add($current.ToString())
            $null = $current.Clear().Append('/T /F')
            $count = 0
        }
        $null = $current.Append($part)
        $count++
    }
    if ($count -gt 0) { $lists.Add($current.ToString()) }
    return ,$lists
}

function Stop-PkJobProcesses {
    # The dispatcher's force-stop: every running job's tree in one
    # Stop-PkProcessTree call. A custom starter's .Proc may not be a Process;
    # those are skipped.
    param([System.Collections.Generic.List[hashtable]]$Jobs)
    $procs = foreach ($job in $Jobs) { if ($job['Proc'] -is [System.Diagnostics.Process]) { $job['Proc'] } }
    try { $null = Stop-PkProcessTree -Process @($procs) } catch { }  # best effort; each job is still waited on and disposed after
}

function Get-PkJobTimeLimit {
    # A dispatcher job's time limit in seconds: its own TimeoutSeconds key if it
    # has one, else the default. 0 = no limit. Throws on a bad key. The batch
    # and dispatcher check their -TimeoutSeconds by the same rule.
    param([hashtable]$Job, [double]$DefaultTimeoutSeconds = 0)
    $value = $Job['TimeoutSeconds']
    if ($null -eq $value) { return $DefaultTimeoutSeconds }
    $limit = 0.0
    $parsed = [double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$limit)
    if (-not $parsed -or [double]::IsNaN($limit) -or [double]::IsInfinity($limit) -or $limit -lt 0) {
        throw ("TimeoutSeconds must be a number of seconds, 0 (no limit) or more (got '" + $value + "').")
    }
    return $limit
}

function Stop-PkTimedOutJob {
    # Kills a dispatcher job's program tree once it passes its TimeLimit and
    # sets TimedOut; the job is then finalized like any other. Only a .Proc
    # that is a real Process is timed.
    param([hashtable]$Job)
    $proc = $Job['Proc']
    $clock = $Job['Stopwatch']
    if ($proc -isnot [System.Diagnostics.Process] -or $clock -isnot [System.Diagnostics.Stopwatch]) { return }
    if ($proc.HasExited -or $clock.Elapsed.TotalSeconds -lt $Job['TimeLimit']) { return }
    # Only flagged if this call did the killing: a program that exited on its
    # own right at the deadline didn't time out. One try only: this runs every
    # pass, and a program that can't be killed would start a taskkill each time.
    $Job['TimeLimit'] = 0
    if (Stop-PkProcessTree -Process $proc) {
        $Job['TimedOut'] = $true
    } elseif (-not $proc.HasExited) {
        Write-PkMessage ("ProcessDispatch: a job passed its time limit, but its program (process " + $proc.Id + ") couldn't be stopped. It holds its slot until it exits.") -Level Warn
    }
}

function Wait-PkProcess {
    # .SYNOPSIS
    # Waits for a program to exit, with a timeout that can't overrun.
    # .DESCRIPTION
    # Waits on the process handle itself. Process.WaitForExit(int) also waits for
    # redirected output and can hang well past its own timeout.
    # .PARAMETER Process
    # The program, such as the Proc that Start-PkProcess returns.
    # .PARAMETER TimeoutMs
    # How long to wait, in milliseconds; 0 or more, and 0 just checks.
    # .OUTPUTS
    # [bool] $true if it exited in time.
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )
    # -1 would wait until the program exits, forever if it never does.
    if ($TimeoutMs -lt 0) { throw ("Wait-PkProcess: -TimeoutMs must be 0 or more (got " + $TimeoutMs + "). It's how long to wait, in milliseconds; 0 just checks.") }
    # Same handle wrapping as Wait-PkRunningJobs.
    $waitHandle = [System.Threading.ManualResetEvent]::new($false)
    $origHandle = $waitHandle.SafeWaitHandle
    $waitHandle.SafeWaitHandle = [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new($Process.Handle, $false)
    try {
        return $waitHandle.WaitOne($TimeoutMs)
    } finally {
        $waitHandle.SafeWaitHandle = $origHandle
        $waitHandle.Dispose()
    }
}

function Wait-PkRunningJobs {
    # The dispatch loop's pause: until a running program exits, the token is
    # canceled, or TimeoutMs passes. Exited programs aren't waited on: a
    # -JobPollCompleted can keep saying "not done" after the exit, and the
    # signaled handle would spin a core. A job with no real process, or past
    # the 63 handles WaitAny holds on an STA thread (one is the token), is only
    # noticed when the time is up. Same handle wrapping as Wait-PkProcess.
    param(
        [System.Collections.Generic.List[hashtable]]$Jobs,
        [System.Threading.CancellationToken]$CancelToken,
        [int]$TimeoutMs
    )
    $waits = [System.Collections.Generic.List[System.Threading.WaitHandle]]::new()
    $origHandles = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($job in $Jobs) {
            if ($waits.Count -ge 62) { break }
            $proc = $job['Proc']
            if ($proc -isnot [System.Diagnostics.Process] -or $proc.HasExited) { continue }
            $procHandle = $proc.Handle
            $waitHandle = [System.Threading.ManualResetEvent]::new($false)
            $origHandle = $waitHandle.SafeWaitHandle
            $waitHandle.SafeWaitHandle = [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new($procHandle, $false)
            $waits.Add($waitHandle)
            $origHandles.Add($origHandle)
        }
        if ($waits.Count -gt 0) {
            $waits.Add($CancelToken.WaitHandle)
            $null = [System.Threading.WaitHandle]::WaitAny($waits.ToArray(), $TimeoutMs)
            return
        }
    } catch {
        # A process that can't be read or waited on (a starter's own, say) is
        # the job's -JobPollCompleted to deal with; here it just means sleeping.
    } finally {
        for ($i = 0; $i -lt $origHandles.Count; $i++) {
            $waits[$i].SafeWaitHandle = $origHandles[$i]
            $waits[$i].Dispose()
        }
    }
    [System.Threading.Thread]::Sleep($TimeoutMs)
}

function Get-PkProcessDuration {
    # How long a program ran, from its start to its exit or kill, as a
    # [TimeSpan]: not the time it waited for a slot, nor any wait for its
    # output afterwards. $null if it isn't a Process (a custom starter's),
    # hasn't exited, or was already disposed (Dispose loses the times).
    param($Process)
    if ($Process -isnot [System.Diagnostics.Process]) { return $null }
    try {
        if ($Process.HasExited -ne $true) { return $null }
        return ($Process.ExitTime - $Process.StartTime)
    } catch { return $null }   # times not readable: no duration, rather than a throw inside -JobFinalize
}

function Complete-PkProcess {
    # .SYNOPSIS
    # Collects the exit code and output of a program that has exited.
    # .DESCRIPTION
    # A program that exited can still have its output held open by a program it
    # started, so reading the output is time-limited too; StreamTimedOut says when
    # that limit was hit. The stream it gave up on comes back with what arrived
    # before then: cut short, not lost. Its read carries on in the background
    # until that program lets go of it (it's killed with PowerShell at the
    # latest). A stream whose read failed (StreamError) comes back $null.
    # .PARAMETER Job
    # What Start-PkProcess returned, or a dispatcher job with the same keys.
    # .PARAMETER StreamTimeoutMs
    # How long to wait for the output after the program exits,
    # in milliseconds (default 15000); 0 or more, and 0 doesn't wait.
    # .PARAMETER Dispose
    # Dispose the process object afterwards.
    # .OUTPUTS
    # An object with ExitCode, Stdout, Stderr, StreamTimedOut, StreamError and
    # Duration (how long the program ran, from its start to its exit or kill).

    # Only -Job by position: otherwise `-Dispose $true` would bind $true to
    # -StreamTimeoutMs (1 ms) and cut the output off without an error.
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [hashtable]$Job,
        [int]$StreamTimeoutMs = 15000,
        [switch]$Dispose
    )
    # A negative wait isn't a limit: -1 waited until the output closed, however
    # long a leftover child held it. Invoke-PkProcessWithTimeout checks it too,
    # before starting its program.
    if ($StreamTimeoutMs -lt 0) {
        throw ("Complete-PkProcess: -StreamTimeoutMs must be 0 or more (got " + $StreamTimeoutMs + "). It's how long to wait for the output after the program exits, in milliseconds; 0 doesn't wait.")
    }
    $result = [ordered]@{ ExitCode = $null; Stdout = $null; Stderr = $null; StreamTimedOut = $false; StreamError = $null; Duration = $null }
    # A custom starter's job may have no read tasks, and a read can fail.
    # Neither throws: this runs inside JobFinalize, where a throw stops the
    # whole dispatcher.
    $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    if ($null -ne $Job['StdoutTask']) { $tasks.Add($Job['StdoutTask']) }
    if ($null -ne $Job['StderrTask']) { $tasks.Add($Job['StderrTask']) }
    if ($tasks.Count -gt 0) {
        try {
            if (-not [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $StreamTimeoutMs)) { $result.StreamTimedOut = $true }
        } catch {
            $result.StreamError = [string]$_.Exception.Message
        }
    }
    # The output's end (both streams closed, or the timeout) is separate from
    # the program's end (the exit code, below): a program it started can hold
    # a stream open after it exits. A stream still open at the timeout gives
    # the text that arrived before it, each stream on its own; its read
    # carries on in the background until that program lets go.
    $ranToCompletion = [System.Threading.Tasks.TaskStatus]::RanToCompletion
    foreach ($stream in 'Stdout', 'Stderr') {
        $task = $Job[$stream + 'Task']
        if ($null -eq $task) { continue }
        if ($task.Status -eq $ranToCompletion) { $result[$stream] = $task.Result }
        elseif (-not $task.IsCompleted -and $task -is [PkStreamReadTask]) { $result[$stream] = $task.Snapshot() }
    }
    $result.ExitCode = $Job['Proc'].ExitCode
    # The program's end, not the output's: before Dispose, which loses it.
    $result.Duration = Get-PkProcessDuration -Process $Job['Proc']
    if ($Dispose) { $Job['Proc'].Dispose() }
    return [pscustomobject]$result
}

function Invoke-PkProcessWithTimeout {
    # .SYNOPSIS
    # Runs one program to completion, with a hard time limit.
    # .DESCRIPTION
    # Throws if the program had to be killed: because it ran past -TimeoutMs, or
    # because the run was aborted or canceled while it was going. Anything the
    # program started is killed with it.
    # .PARAMETER FilePath
    # The program to run.
    # .PARAMETER Arguments
    # Its command line: one string, passed exactly as written, or a list, each
    # element one argument, quoted for you (see ConvertTo-PkArgumentString).
    # .PARAMETER TimeoutMs
    # The time limit in milliseconds (default 60000), at least 1.
    # .PARAMETER StreamTimeoutMs
    # How long to wait for the output after the program exits,
    # in milliseconds (default 15000); 0 or more, and 0 doesn't wait.
    # .PARAMETER WorkingDirectory
    # Where to run it, as for Start-PkProcess. Default: your current location.
    # .PARAMETER OutputEncoding
    # How to decode its output, as for Start-PkProcess.
    # .PARAMETER IgnoreAbort
    # Keep going during an abort, for a cleanup or restore step that has to run
    # because of it.
    # .OUTPUTS
    # An object with ExitCode, Stdout, Stderr, StreamTimedOut, StreamError and
    # Duration (how long the program ran, from its start to its exit or kill).
    # .EXAMPLE
    # $r = Invoke-PkProcessWithTimeout -FilePath git.exe -Arguments 'rev-parse HEAD' -TimeoutMs 10000
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        $Arguments = "",
        [int]$TimeoutMs = 60000,
        [int]$StreamTimeoutMs = 15000,
        [string]$WorkingDirectory = "",
        $OutputEncoding = $null,
        [switch]$IgnoreAbort
    )
    # Checked before starting anything: 0 or less would kill the program at once.
    if ($TimeoutMs -lt 1) { throw ("Invoke-PkProcessWithTimeout: -TimeoutMs must be at least 1 (got " + $TimeoutMs + "). It's the program's time limit in milliseconds.") }
    # Complete-PkProcess makes the same check, but only after the program has run.
    if ($StreamTimeoutMs -lt 0) { throw ("Invoke-PkProcessWithTimeout: -StreamTimeoutMs must be 0 or more (got " + $StreamTimeoutMs + "). It's how long to wait for the output after the program exits, in milliseconds; 0 doesn't wait.") }
    $job = Start-PkProcessCore -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -OutputEncoding $OutputEncoding -CallerState $PSCmdlet.SessionState
    try {
        # Short slices, so an abort or cancel is noticed within a moment.
        $waited  = [System.Diagnostics.Stopwatch]::StartNew()
        $exited  = $false
        $stopWhy = $null
        while (-not $exited) {
            $remainingMs = $TimeoutMs - [int]$waited.ElapsedMilliseconds
            if ($remainingMs -le 0) { $stopWhy = ("did not exit within " + $TimeoutMs + "ms"); break }
            $exited = Wait-PkProcess -Process $job['Proc'] -TimeoutMs ([Math]::Min(200, $remainingMs))
            if (-not $exited -and -not $IgnoreAbort -and ((Test-PkAbortSignal) -or (Test-PkCancelRequested))) { $stopWhy = "was stopped because the run is being aborted"; break }
        }
        if (-not $exited) {
            try { $null = Stop-PkProcessTree -Process $job['Proc'] } catch { }   # best effort - the throw below still reports why
            # Let the output reads finish (the kill closes their pipes) before
            # the process is disposed under them. Bounded; a read error doesn't
            # matter here.
            try { $null = [System.Threading.Tasks.Task]::WaitAll(@($job['StdoutTask'], $job['StderrTask']), 500) } catch { }
            throw ("'" + $FilePath + "' " + $stopWhy + " - killed")
        }
        return Complete-PkProcess -Job $job -StreamTimeoutMs $StreamTimeoutMs
    } finally {
        # Still running here only when PowerShell is stopping the script
        # (that skips catch blocks, not finally ones): kill it before the
        # process object goes. Best effort, as above.
        try { if (-not $job['Proc'].HasExited) { $null = Stop-PkProcessTree -Process $job['Proc'] } } catch { }
        $job['Proc'].Dispose()
    }
}

# ==============================================================================
#  Process dispatch - run many external processes, a bounded number at a time
# ==============================================================================

function Invoke-PkProcessDispatch {
    # .SYNOPSIS
    # Runs external programs grouped by unit of work (a folder, a batch), a limited
    # number at a time, with a callback when each group is done.
    # .DESCRIPTION
    # Groups are pulled one at a time from -GroupProvider; -JobBuilder turns each
    # into job hashtables; jobs run up to -MaxConcurrent at once across all groups;
    # -GroupCompleteCallback fires when a group's last job finishes. Apart from the
    # return values described below, anything your callbacks output is discarded.
    # Leave a callback early with return: continue and break end it too, but warn.
    #
    # The dispatcher keeps its own state on each job hashtable. Don't use these keys
    # for anything else: GroupKey, SlotReleased, Proc, StdoutTask, StderrTask,
    # Stopwatch, TimeLimit, TimedOut, StartFailureReported. It also sets Group to
    # the job's group, unless the job already has a Group of its own. The default
    # starter reads FilePath, Arguments (a string as written, or a list quoted one
    # argument per element), WorkingDirectory and OutputEncoding from the job. A
    # job's TimeoutSeconds key overrides -TimeoutSeconds.
    # .PARAMETER GroupProvider
    # { } returning the next group, or $null when there are no more, and
    # outputting nothing else. Return a list as one group with a comma:
    # return ,@('a', 'b'). Output ending in $null is taken as the end, with a
    # warning, so a list group can't end in $null.
    # .PARAMETER JobBuilder
    # { param($group) } returning the group's job hashtable(s), or @() for none.
    # .PARAMETER JobStarter
    # { param($job) } that starts the job and returns it with .Proc set. Default:
    # Start-PkProcess on the job's FilePath and Arguments.
    # .PARAMETER JobPollCompleted
    # { param($job) } returning $true once the job is finished. Default:
    # $job['Proc'].HasExited. Only its last output value counts.
    # .PARAMETER JobFinalize
    # { param($job, $pendingQueue) } called once per finished job; collect its
    # result with Complete-PkProcess. Enqueue new job hashtables onto $pendingQueue
    # to retry or add follow-up work in the same group.
    # .PARAMETER JobAbortCleanup
    # { param($job) } for a job an abort killed or kept from starting, to remove its
    # partial output.
    # .PARAMETER GroupCompleteCallback
    # { param($group) } when a group's last job finishes. Also called for a group an
    # abort cut short, so check Test-PkCancelRequested before anything irreversible.
    # .PARAMETER MaxConcurrent
    # How many programs run at once: an int, or a SemaphoreSlim shared by several
    # dispatchers that must stay under one combined limit. -MaxParallel also works.
    # .PARAMETER PollCallback
    # { param($runningJobs) } run on every loop pass, with the jobs currently running.
    # -AbortPollCallback (its name before 3.0) also works.
    # .PARAMETER CancelToken
    # Stops the dispatcher when canceled. An abort stops it either way, without
    # canceling this token.
    # .PARAMETER AbortTimeoutSeconds
    # How long an abort waits for running jobs before force-stopping them
    # (default 60). A force-stopped program is killed along with anything it
    # started. -DrainTimeoutSeconds also works.
    # .PARAMETER MaxQueueAhead
    # How many groups to pull ahead of the ones running (default 3).
    # .PARAMETER GroupReleaseCheck
    # { param($group) } returning $true to release a zero-job group's queue-ahead
    # slot; until then it holds the slot. Runs on every loop pass, so keep it cheap.
    # Only its last output value counts.
    # .PARAMETER TimeoutSeconds
    # Kill a job's program, and anything it started, still running after this long
    # (default 0, no limit). A job's own TimeoutSeconds key overrides it, and 0 there
    # opts the job out. The killed job still goes through -JobFinalize, with
    # $job['TimedOut'] = $true. A job whose .Proc isn't a process isn't timed.
    # .OUTPUTS
    # An object with GroupResults, Aborted, ForceKilledCount and
    # JobStarterFailedCount. Each group result has GroupInfo (the group), Completed
    # and Aborted.
    param(
        [Parameter(Mandatory)]
        [scriptblock]$GroupProvider,
        [Parameter(Mandatory)]
        [scriptblock]$JobBuilder,
        [scriptblock]$JobStarter = $null,
        [scriptblock]$JobPollCompleted = $null,
        [Parameter(Mandatory)]
        [scriptblock]$JobFinalize,
        [scriptblock]$JobAbortCleanup = $null,
        [scriptblock]$GroupCompleteCallback = $null,
        [Parameter(Mandatory)]
        [Alias('MaxParallel')]
        $MaxConcurrent,
        [Alias('AbortPollCallback')]
        [scriptblock]$PollCallback = $null,
        [System.Threading.CancellationToken]$CancelToken,
        [Alias('DrainTimeoutSeconds')]
        [int]$AbortTimeoutSeconds = 60,
        [int]$MaxQueueAhead = 3,
        [scriptblock]$GroupReleaseCheck = $null,
        [double]$TimeoutSeconds = 0
    )
    # pk-prefixed, parameters included: inside a worker runspace the kit isn't
    # a module, so a callback without .GetNewClosure() sees this frame's
    # variables. Same in Add-PkDispatchGroupJobs, Invoke-PkProcessDispatchCore, Invoke-PkProcessBatch.
    $pkGroupProvider = $GroupProvider
    $pkJobBuilder = $JobBuilder
    $pkJobStarter = $JobStarter
    $pkJobPollCompleted = $JobPollCompleted
    $pkJobFinalize = $JobFinalize
    $pkJobAbortCleanup = $JobAbortCleanup
    $pkGroupCompleteCallback = $GroupCompleteCallback
    $pkMaxConcurrent = $MaxConcurrent
    $pkPollCallback = $PollCallback
    $pkCancelToken = $CancelToken
    $pkAbortTimeoutSeconds = $AbortTimeoutSeconds
    $pkMaxQueueAhead = $MaxQueueAhead
    $pkGroupReleaseCheck = $GroupReleaseCheck
    $pkTimeoutSeconds = $TimeoutSeconds
    Remove-Variable -Name GroupProvider, JobBuilder, JobStarter, JobPollCompleted, JobFinalize, JobAbortCleanup, GroupCompleteCallback, MaxConcurrent, PollCallback, CancelToken, AbortTimeoutSeconds, MaxQueueAhead, GroupReleaseCheck, TimeoutSeconds -Scope Local

    # 0 or less would never start a job (or pull a group) and spin forever.
    if ($pkMaxConcurrent -isnot [System.Threading.SemaphoreSlim]) {
        $pkMaxConcurrentInt = 0
        if (-not [int]::TryParse([string]$pkMaxConcurrent, [ref]$pkMaxConcurrentInt) -or $pkMaxConcurrentInt -lt 1) {
            throw ("Invoke-PkProcessDispatch: -MaxConcurrent must be a whole number of at least 1, or a SemaphoreSlim (got '" + $pkMaxConcurrent + "').")
        }
        $pkMaxConcurrent = $pkMaxConcurrentInt
    }
    if ($pkMaxQueueAhead -lt 1) { throw "Invoke-PkProcessDispatch: -MaxQueueAhead must be at least 1." }
    # Invoke-PkProcessBatch makes the same -MaxConcurrent, -TimeoutSeconds and
    # -AbortTimeoutSeconds checks, so its errors name the batch: keep the two in
    # step. NaN and +Infinity pass a `-lt 0` test and acted as no limit. A job's
    # own TimeoutSeconds key follows the same rule (Get-PkJobTimeLimit).
    if ([double]::IsNaN($pkTimeoutSeconds) -or [double]::IsInfinity($pkTimeoutSeconds) -or $pkTimeoutSeconds -lt 0) {
        throw ("Invoke-PkProcessDispatch: -TimeoutSeconds must be a number of seconds, 0 (no limit) or more (got " + $pkTimeoutSeconds + ").")
    }
    if ($pkAbortTimeoutSeconds -lt 0) {
        throw ("Invoke-PkProcessDispatch: -AbortTimeoutSeconds must be 0 or more (got " + $pkAbortTimeoutSeconds + "). It's how long an abort waits for running jobs before force-stopping them; 0 doesn't wait.")
    }

    # Size the thread pool up front. For a shared budget, its free slots now
    # are the best measure of its size.
    $pkPoolSizeHint = 0
    if ($pkMaxConcurrent -is [int]) { $pkPoolSizeHint = $pkMaxConcurrent }
    elseif ($pkMaxConcurrent -is [System.Threading.SemaphoreSlim]) { $pkPoolSizeHint = $pkMaxConcurrent.CurrentCount }
    $null = Initialize-PkThreadPool -MaxConcurrentProcesses $pkPoolSizeHint

    if ($null -eq $pkJobStarter) {
        $pkCallerState = $PSCmdlet.SessionState
        $pkJobStarter = {
            param($pkJob)
            $pkStarted = Start-PkProcessCore -CallerState $pkCallerState -FilePath $pkJob['FilePath'] -Arguments $pkJob['Arguments'] -WorkingDirectory ([string]$pkJob['WorkingDirectory']) -OutputEncoding $pkJob['OutputEncoding']
            # Start-PkProcessCore's four keys (it builds them in two places); the
            # batch's starter copies them too: a new key goes in all four.
            $pkJob['Proc'] = $pkStarted.Proc; $pkJob['StdoutTask'] = $pkStarted.StdoutTask; $pkJob['StderrTask'] = $pkStarted.StderrTask
            $pkJob['Stopwatch'] = $pkStarted.Stopwatch
            return $pkJob
        }
    }
    # The default poll reads $pkJob['Proc'], so a started job must have one.
    $pkRequireProc = ($null -eq $pkJobPollCompleted)
    if ($null -eq $pkJobPollCompleted)      { $pkJobPollCompleted      = { param($pkJob) return $pkJob['Proc'].HasExited } }
    if ($null -eq $pkJobAbortCleanup)       { $pkJobAbortCleanup       = { param($pkJob) } }
    if ($null -eq $pkGroupCompleteCallback) { $pkGroupCompleteCallback = { param($pkGroup) } }

    # Token: the caller's; else (in a worker) the run's own; else a fresh one
    # registered so an abort cancels it.
    $pkOwnCts = $null
    if (-not $PSBoundParameters.ContainsKey('CancelToken')) {
        if ($null -ne $global:PkCancelToken) {
            $pkCancelToken = $global:PkCancelToken
        } else {
            $pkOwnCts = [System.Threading.CancellationTokenSource]::new()
            Register-PkCancellationSource -Cts $pkOwnCts
            $pkCancelToken = $pkOwnCts.Token
        }
    } else {
        # Nothing cancels the caller's token on Ctrl+C, so run on a linked
        # source an abort does cancel. In a worker it also follows the run's
        # token.
        $pkLinkTokens = [System.Collections.Generic.List[System.Threading.CancellationToken]]::new()
        $pkLinkTokens.Add($pkCancelToken)
        if ($null -ne $global:PkCancelToken) { $pkLinkTokens.Add($global:PkCancelToken) }
        $pkOwnCts = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($pkLinkTokens.ToArray())
        Register-PkCancellationSource -Cts $pkOwnCts
        $pkCancelToken = $pkOwnCts.Token
    }

    try {
        return Invoke-PkProcessDispatchCore -GroupProvider $pkGroupProvider -JobBuilder $pkJobBuilder -JobStarter $pkJobStarter `
            -JobPollCompleted $pkJobPollCompleted -JobFinalize $pkJobFinalize -JobAbortCleanup $pkJobAbortCleanup `
            -GroupCompleteCallback $pkGroupCompleteCallback -MaxConcurrent $pkMaxConcurrent -PollCallback $pkPollCallback `
            -CancelToken $pkCancelToken -AbortTimeoutSeconds $pkAbortTimeoutSeconds -MaxQueueAhead $pkMaxQueueAhead `
            -GroupReleaseCheck $pkGroupReleaseCheck -RequireProc $pkRequireProc -TimeoutSeconds $pkTimeoutSeconds
    } finally {
        if ($null -ne $pkOwnCts) {
            Unregister-PkCancellationSource -Cts $pkOwnCts
            $pkOwnCts.Dispose()
        }
    }
}

function Add-PkDispatchGroupJobs {
    # Builds one group's jobs, tags them with the group and queues them;
    # returns how many. Its own function so the group's job list dies with
    # this call: in the dispatch loop's frame it kept every finished job's
    # output alive for the whole run, and nulling the variables there didn't
    # release it.
    param(
        [Parameter(Mandatory)][scriptblock]$JobBuilder,
        $GroupInfo,
        [Parameter(Mandatory)][object]$GroupKey,
        [Parameter(Mandatory)][System.Collections.Generic.Queue[hashtable]]$Pending,
        [hashtable]$CallbackContext
    )
    # pk-prefixed, parameters included: inside a worker runspace the kit isn't
    # a module, so a callback without .GetNewClosure() sees this frame's
    # variables. Same in Invoke-PkProcessDispatch, Invoke-PkProcessDispatchCore, Invoke-PkProcessBatch.
    $pkJobBuilder = $JobBuilder
    $pkGroupInfo = $GroupInfo
    $pkGroupKey = $GroupKey
    $pkPending = $Pending
    $pkCallbackContext = $CallbackContext
    Remove-Variable -Name JobBuilder, GroupInfo, GroupKey, Pending, CallbackContext -Scope Local
    $pkRawJobs = Invoke-PkCallback -PkCallback $pkJobBuilder -PkArgs @(,$pkGroupInfo) -PkName '-JobBuilder' -PkContext $pkCallbackContext
    # Assigned in each branch, not `$x = if ... else ...`: captured that way,
    # a single hashtable is enumerated into its key/value pairs.
    if ($null -eq $pkRawJobs) { $pkRawJobList = @() } else { $pkRawJobList = @($pkRawJobs) }
    # Keep only real job hashtables: a builder that lets a stray
    # value escape (a HashSet.Add's True, say) must not crash the run.
    $pkJobs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($pkRawJob in $pkRawJobList) { if ($pkRawJob -is [hashtable]) { $pkJobs.Add($pkRawJob) } }
    if ($pkJobs.Count -ne $pkRawJobList.Count) {
        Write-PkMessage ("ProcessDispatch: -JobBuilder returned " + ($pkRawJobList.Count - $pkJobs.Count) + " value(s) that are not job hashtables - ignored. Each job must be a hashtable.") -Level Warn
    }
    foreach ($pkJ in $pkJobs) {
        $pkJ['GroupKey'] = $pkGroupKey
        if (-not $pkJ.ContainsKey('Group')) { $pkJ['Group'] = $pkGroupInfo }   # leave a job's own 'Group' field alone
        $pkPending.Enqueue($pkJ)
    }
    return $pkJobs.Count
}

function Invoke-PkProcessDispatchCore {
    # The dispatch loop itself. Call Invoke-PkProcessDispatch, not this.
    param(
        [scriptblock]$GroupProvider,
        [scriptblock]$JobBuilder,
        [scriptblock]$JobStarter,
        [scriptblock]$JobPollCompleted,
        [scriptblock]$JobFinalize,
        [scriptblock]$JobAbortCleanup,
        [scriptblock]$GroupCompleteCallback,
        $MaxConcurrent,
        [scriptblock]$PollCallback,
        [System.Threading.CancellationToken]$CancelToken,
        [int]$AbortTimeoutSeconds,
        [int]$MaxQueueAhead,
        [scriptblock]$GroupReleaseCheck,
        [bool]$RequireProc = $false,
        [double]$TimeoutSeconds = 0
    )
    # pk-prefixed, parameters included: inside a worker runspace the kit isn't
    # a module, so a callback without .GetNewClosure() sees this frame's
    # variables. Same in Add-PkDispatchGroupJobs, Invoke-PkProcessDispatch, Invoke-PkProcessBatch.
    $pkGroupProvider = $GroupProvider
    $pkJobBuilder = $JobBuilder
    $pkJobStarter = $JobStarter
    $pkJobPollCompleted = $JobPollCompleted
    $pkJobFinalize = $JobFinalize
    $pkJobAbortCleanup = $JobAbortCleanup
    $pkGroupCompleteCallback = $GroupCompleteCallback
    $pkMaxConcurrent = $MaxConcurrent
    $pkPollCallback = $PollCallback
    $pkCancelToken = $CancelToken
    $pkAbortTimeoutSeconds = $AbortTimeoutSeconds
    $pkMaxQueueAhead = $MaxQueueAhead
    $pkGroupReleaseCheck = $GroupReleaseCheck
    $pkRequireProc = $RequireProc
    $pkTimeoutSeconds = $TimeoutSeconds
    Remove-Variable -Name GroupProvider, JobBuilder, JobStarter, JobPollCompleted, JobFinalize, JobAbortCleanup, GroupCompleteCallback, MaxConcurrent, PollCallback, CancelToken, AbortTimeoutSeconds, MaxQueueAhead, GroupReleaseCheck, RequireProc, TimeoutSeconds -Scope Local

    $pkIsSharedBudget = ($pkMaxConcurrent -is [System.Threading.SemaphoreSlim])

    $pkGroupStates      = [System.Collections.Generic.Dictionary[object,hashtable]]::new()
    $pkGroupResults     = [System.Collections.Generic.List[object]]::new()
    $pkActiveGroupCount = 0
    $pkProviderExhausted = $false
    $pkHeldGroups       = [System.Collections.Generic.List[object]]::new()

    $pkPending = [System.Collections.Generic.Queue[hashtable]]::new()
    $pkRunning = [System.Collections.Generic.List[hashtable]]::new()

    $pkDispatchResult = [ordered]@{
        GroupResults          = $pkGroupResults
        Aborted               = $false
        ForceKilledCount      = 0
        JobStarterFailedCount = 0
    }

    # The job -JobStarter is working on: not in $pkRunning yet, but it may
    # already have a program and a shared slot.
    $pkStarting = $null
    # The job -JobFinalize is working on. It has finished, so if -JobFinalize
    # throws, the teardown skips -JobAbortCleanup for it (that's for jobs it
    # kills) and only gives back its slot.
    $pkFinalizing = $null
    # Invoke-PkCallback's -PkContext: callbacks that used continue/break are
    # warned about once each, under this prefix.
    $pkCallbackContext = @{ Prefix = 'ProcessDispatch: '; Warned = @{} }
    # Teardown is in a finally, guarded by this flag: when PowerShell stops
    # the script (Ctrl+C outside Invoke-PkRun, the runspace engine
    # force-stopping a worker), catch blocks are skipped.
    $pkLoopDone = $false
    try {
    while ((-not $pkCancelToken.IsCancellationRequested) -and `
           (-not $pkProviderExhausted -or $pkActiveGroupCount -gt 0 -or $pkPending.Count -gt 0 -or $pkRunning.Count -gt 0)) {

        for ($pkH = $pkHeldGroups.Count - 1; $pkH -ge 0; $pkH--) {
            $pkReleased = Invoke-PkCallback -PkCallback $pkGroupReleaseCheck -PkArgs @(,$pkHeldGroups[$pkH]) -PkName '-GroupReleaseCheck' -PkContext $pkCallbackContext
            # Only the check's last value counts, as with -JobPollCompleted: a
            # value it leaks first (an ArrayList.Add index) would release the group.
            if ($pkReleased -is [object[]]) { $pkReleased = $pkReleased[-1] }
            if ([bool]$pkReleased) {
                $pkHeldGroups.RemoveAt($pkH)
                $pkActiveGroupCount--
            }
        }

        while ((-not $pkProviderExhausted) -and $pkActiveGroupCount -lt $pkMaxQueueAhead -and (-not $pkCancelToken.IsCancellationRequested)) {
            $pkGroupInfo = Invoke-PkCallback -PkCallback $pkGroupProvider -PkName '-GroupProvider' -PkContext $pkCallbackContext
            # A value the provider leaks before `return $null` (an ArrayList.Add
            # index) arrives as @(<index>, $null). Taken as one more group, the
            # dispatcher would ask again forever, so output ending in $null is
            # the end. A list can't be told apart from that (wrapped or not, a
            # list reaches here as the same array), so a list group can't end
            # in $null.
            if ($pkGroupInfo -is [object[]] -and $pkGroupInfo.Count -gt 0 -and $null -eq $pkGroupInfo[-1]) {
                Write-PkMessage ("ProcessDispatch: -GroupProvider output " + ($pkGroupInfo.Count - 1) + " other value(s) along with `$null, taken as no more groups. Output only the group, or `$null alone to end (`$null = ... discards a value you don't want).") -Level Warn
                $pkGroupInfo = $null
            }
            if ($null -eq $pkGroupInfo) { $pkProviderExhausted = $true; break }
            # A fresh key per group, not the group value: two groups that
            # compare equal (the same folder name) mustn't share a job count.
            $pkGroupKey = [object]::new()
            $pkJobCount = Add-PkDispatchGroupJobs -JobBuilder $pkJobBuilder -GroupInfo $pkGroupInfo -GroupKey $pkGroupKey -Pending $pkPending -CallbackContext $pkCallbackContext
            $pkState = @{ GroupInfo = $pkGroupInfo; Outstanding = $pkJobCount; Completed = $false }
            $pkGroupStates[$pkGroupKey] = $pkState
            $pkActiveGroupCount++
            if ($pkState.Outstanding -le 0) {
                $null = Invoke-PkCallback -PkCallback $pkGroupCompleteCallback -PkArgs @(,$pkGroupInfo) -PkName '-GroupCompleteCallback' -PkContext $pkCallbackContext
                $pkState.Completed = $true
                if ($null -ne $pkGroupReleaseCheck) { $pkHeldGroups.Add($pkGroupInfo) } else { $pkActiveGroupCount-- }
                $pkGroupResults.Add([pscustomobject][ordered]@{ GroupInfo = $pkGroupInfo; Completed = $true; Aborted = $false })
            }
        }

        # Main thread: this is what notices an abort and cancels the token.
        # Worker: just reads the flag; the main thread cancels the token.
        $null = Test-PkAbortSignal
        # This and the per-job callbacks below inline Invoke-PkCallback.
        if ($pkPollCallback) {
            $pkCbDone = $false
            $null = do { & $pkPollCallback @($pkRunning); $pkCbDone = $true } while ($false)
            if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-PollCallback' -PkContext $pkCallbackContext }
        }

        while ($pkPending.Count -gt 0 -and (-not $pkCancelToken.IsCancellationRequested) -and `
               $(if ($pkIsSharedBudget) { $pkMaxConcurrent.Wait(0) } else { $pkRunning.Count -lt $pkMaxConcurrent })) {
            $pkJob = $pkPending.Dequeue()
            try {
                # The running job is always the caller's own object: a starter
                # that forgets to return it, or leaks other output, would
                # otherwise leave something un-pollable running. A different
                # hashtable it outputs (a bare Start-PkProcess result) has its
                # fields folded in. A job JobFinalize re-queued still carries
                # its old, disposed process: cleared first.
                if ($pkJob['SlotReleased']) {
                    $pkJob['Proc'] = $null; $pkJob['StdoutTask'] = $null; $pkJob['StderrTask'] = $null; $pkJob['Stopwatch'] = $null
                }
                $pkJob['SlotReleased'] = $false
                $pkStarting = $pkJob
                # Before starting, so a bad key never leaves a program running.
                $pkStartFailureText = "ProcessDispatch: a job couldn't start: "
                $pkJob['TimeLimit'] = Get-PkJobTimeLimit -Job $pkJob -DefaultTimeoutSeconds $pkTimeoutSeconds
                $pkStartFailureText = "ProcessDispatch: JobStarter failed to start a job: "
                $pkCbDone = $false
                $pkStartedRaw = do { & $pkJobStarter $pkJob; $pkCbDone = $true } while ($false)
                if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobStarter' -PkContext $pkCallbackContext }
                foreach ($pkItem in @($pkStartedRaw)) {
                    if ($pkItem -isnot [hashtable] -or [object]::ReferenceEquals($pkItem, $pkJob)) { continue }
                    foreach ($pkItemKey in @($pkItem.Keys)) {
                        if ($null -eq $pkJob[$pkItemKey]) { $pkJob[$pkItemKey] = $pkItem[$pkItemKey] }
                    }
                }
                if ($pkRequireProc -and $null -eq $pkJob['Proc']) {
                    throw "JobStarter did not set the job's .Proc (set .Proc on the job and return it, or supply -JobPollCompleted)."
                }
                $pkJob['TimedOut'] = $false
                if ($pkJob['TimeLimit'] -gt 0 -and $null -eq $pkJob['Stopwatch']) { $pkJob['Stopwatch'] = [System.Diagnostics.Stopwatch]::StartNew() }
                $pkRunning.Add($pkJob)
                $pkStarting = $null
            } catch {
                # Release before reporting: this job isn't in $pkRunning, so if
                # reporting threw, nothing would release its slot. A program the
                # starter started before throwing is killed first: nothing else
                # tracks it. $pkStarting is cleared before the release, so the
                # teardown can't release the slot again.
                if ($pkJob['Proc'] -is [System.Diagnostics.Process]) {
                    try { $null = Stop-PkProcessTree -Process $pkJob['Proc'] } catch { }   # best effort; the failed start is still reported below
                    try { $pkJob['Proc'].Dispose() } catch { }   # the failed start is reported either way
                }
                $pkStarting = $null
                if ($pkIsSharedBudget) { $null = $pkMaxConcurrent.Release() }
                # The batch sets this key on its own jobs: it reports start failures itself.
                if (-not $pkJob['StartFailureReported']) { Write-PkMessage ($pkStartFailureText + $_) -Level Error }
                $pkDispatchResult.JobStarterFailedCount++
                $pkKey = $pkJob['GroupKey']
                if ($pkGroupStates.ContainsKey($pkKey)) {
                    $pkState = $pkGroupStates[$pkKey]
                    $pkState.Outstanding--
                    if ($pkState.Outstanding -le 0 -and -not $pkState.Completed) {
                        $null = Invoke-PkCallback -PkCallback $pkGroupCompleteCallback -PkArgs @(,$pkState.GroupInfo) -PkName '-GroupCompleteCallback' -PkContext $pkCallbackContext
                        $pkState.Completed = $true
                        $pkActiveGroupCount--
                        $pkGroupResults.Add([pscustomobject][ordered]@{ GroupInfo = $pkState.GroupInfo; Completed = $true; Aborted = $false })
                    }
                } else {
                    Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (JobStarter failure path). This should be unreachable; the dispatch loop may now hang.") -Level Error
                }
            }
        }

        # ---- BLOCK: main dispatch loop's poll pass ----
        # Same poll/finalize/completion sequence as the graceful-wait loop
        # and the mandatory final pass below - keep all three in sync.
        $pkStillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($pkJob in $pkRunning) {
            if ($pkJob['TimeLimit'] -gt 0) { Stop-PkTimedOutJob -Job $pkJob }
            $pkCbDone = $false
            $pkPolled = do { & $pkJobPollCompleted $pkJob; $pkCbDone = $true } while ($false)
            if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobPollCompleted' -PkContext $pkCallbackContext }
            # Only the poll's last value counts: a value it leaks first (an
            # ArrayList.Add index, say) would make a running job look done.
            if ($pkPolled -is [object[]]) { $pkPolled = $pkPolled[-1] }
            if ($pkPolled) {
                $pkPendingBefore = $pkPending.Count
                $pkCbDone = $false
                $pkFinalizing = $pkJob
                $null = do { & $pkJobFinalize $pkJob $pkPending; $pkCbDone = $true } while ($false)
                $pkFinalizing = $null
                if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobFinalize' -PkContext $pkCallbackContext }
                # Marked done first: a stop landing after the Release or the
                # Dispose would otherwise have the teardown release the slot a
                # second time and treat the disposed job as still running.
                $pkJob['SlotReleased'] = $true
                if ($pkIsSharedBudget) { $null = $pkMaxConcurrent.Release() }
                try { if ($pkJob['Proc']) { $pkJob['Proc'].Dispose() } } catch { }   # a failed Dispose can't affect the result already taken
                # Whatever JobFinalize queued (a retry, follow-ups) joins its group
                # here, read off the queue rather than a returned flag. Only when the
                # queue grew: walking it for every job is slow on a large batch.
                if ($pkPending.Count -gt $pkPendingBefore) {
                    $pkQueuedIndex = 0
                    foreach ($pkQueued in $pkPending) {
                        if ($pkQueuedIndex -ge $pkPendingBefore) {
                            if ($null -eq $pkQueued['GroupKey']) { $pkQueued['GroupKey'] = $pkJob['GroupKey']; if (-not $pkQueued.ContainsKey('Group')) { $pkQueued['Group'] = $pkJob['Group'] } }
                            if ($pkGroupStates.ContainsKey($pkQueued['GroupKey'])) { $pkGroupStates[$pkQueued['GroupKey']].Outstanding++ }
                        }
                        $pkQueuedIndex++
                    }
                }
                if ($null -ne $pkJob['GroupKey']) {
                    $pkKey = $pkJob['GroupKey']
                    if ($pkGroupStates.ContainsKey($pkKey)) {
                        $pkState = $pkGroupStates[$pkKey]
                        $pkState.Outstanding--
                        if ($pkState.Outstanding -le 0 -and -not $pkState.Completed) {
                            $null = Invoke-PkCallback -PkCallback $pkGroupCompleteCallback -PkArgs @(,$pkState.GroupInfo) -PkName '-GroupCompleteCallback' -PkContext $pkCallbackContext
                            $pkState.Completed = $true
                            $pkActiveGroupCount--
                            $pkGroupResults.Add([pscustomobject][ordered]@{ GroupInfo = $pkState.GroupInfo; Completed = $true; Aborted = $false })
                        }
                    } else {
                        Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (main poll pass). This should be unreachable; the dispatch loop may now hang.") -Level Error
                    }
                }
            } else {
                $pkStillRunning.Add($pkJob)
            }
        }
        # A finished job freed a slot: refill it right away. Not on a shared
        # budget, where a sibling dispatcher only looks every 50 ms and
        # refilling at once starved it. The 50 ms cap is how soon an abort or a
        # sibling's released slot is noticed: neither wakes the wait.
        $pkAnyFinished = ($pkStillRunning.Count -lt $pkRunning.Count)
        $pkRunning = $pkStillRunning

        if ($pkIsSharedBudget -or -not $pkAnyFinished) { Wait-PkRunningJobs -Jobs $pkRunning -CancelToken $pkCancelToken -TimeoutMs 50 }
    }

    if ($pkCancelToken.IsCancellationRequested -and $pkRunning.Count -gt 0) {
        $pkAbortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
        while ($pkRunning.Count -gt 0 -and -not [PkConsoleCtrl]::IsCloseEvent -and -not [PkConsoleCtrl]::SkipDrain -and $pkAbortDeadline.Elapsed.TotalSeconds -lt $pkAbortTimeoutSeconds) {
            # ---- BLOCK: graceful-wait loop ---- (keep in sync with the
            # main poll pass above and the final pass below)
            $pkStillWaiting = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($pkJob in $pkRunning) {
                if ($pkJob['TimeLimit'] -gt 0) { Stop-PkTimedOutJob -Job $pkJob }
                $pkCbDone = $false
                $pkPolled = do { & $pkJobPollCompleted $pkJob; $pkCbDone = $true } while ($false)
                if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobPollCompleted' -PkContext $pkCallbackContext }
                if ($pkPolled -is [object[]]) { $pkPolled = $pkPolled[-1] }   # only the last value counts: see the main poll pass
                if ($pkPolled) {
                    $pkPendingBefore = $pkPending.Count
                    $pkCbDone = $false
                    $pkFinalizing = $pkJob
                    $null = do { & $pkJobFinalize $pkJob $pkPending; $pkCbDone = $true } while ($false)
                    $pkFinalizing = $null
                    if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobFinalize' -PkContext $pkCallbackContext }
                    $pkJob['SlotReleased'] = $true   # first: see the main poll pass
                    if ($pkIsSharedBudget) { $null = $pkMaxConcurrent.Release() }
                    try { if ($pkJob['Proc']) { $pkJob['Proc'].Dispose() } } catch { }   # a failed Dispose can't affect the result already taken
                    # Whatever JobFinalize queued (a retry, follow-ups) joins its group
                    # here, read off the queue rather than a returned flag. Only when the
                    # queue grew: walking it for every job is slow on a large batch.
                    if ($pkPending.Count -gt $pkPendingBefore) {
                        $pkQueuedIndex = 0
                        foreach ($pkQueued in $pkPending) {
                            if ($pkQueuedIndex -ge $pkPendingBefore) {
                                if ($null -eq $pkQueued['GroupKey']) { $pkQueued['GroupKey'] = $pkJob['GroupKey']; if (-not $pkQueued.ContainsKey('Group')) { $pkQueued['Group'] = $pkJob['Group'] } }
                                if ($pkGroupStates.ContainsKey($pkQueued['GroupKey'])) { $pkGroupStates[$pkQueued['GroupKey']].Outstanding++ }
                            }
                            $pkQueuedIndex++
                        }
                    }
                    if ($null -ne $pkJob['GroupKey']) {
                        $pkKey = $pkJob['GroupKey']
                        if ($pkGroupStates.ContainsKey($pkKey)) {
                            $pkState = $pkGroupStates[$pkKey]
                            $pkState.Outstanding--
                            if ($pkState.Outstanding -le 0 -and -not $pkState.Completed) {
                                $null = Invoke-PkCallback -PkCallback $pkGroupCompleteCallback -PkArgs @(,$pkState.GroupInfo) -PkName '-GroupCompleteCallback' -PkContext $pkCallbackContext
                                $pkState.Completed = $true
                                $pkActiveGroupCount--
                                $pkGroupResults.Add([pscustomobject][ordered]@{ GroupInfo = $pkState.GroupInfo; Completed = $true; Aborted = $false })
                            }
                        } else {
                            Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (graceful-wait loop). This should be unreachable.") -Level Error
                        }
                    }
                } else {
                    $pkStillWaiting.Add($pkJob)
                }
            }
            $pkRunning = $pkStillWaiting
            if ($pkRunning.Count -gt 0) { [System.Threading.Thread]::Sleep(250) }
        }

        # ---- BLOCK: final pass ----
        # A window close can end the loop above before any poll, and a job can
        # finish just before the deadline: a finished job mustn't count as
        # force-stopped. Keep in sync with the two blocks above, minus the time
        # limit (whatever is left is force-stopped just below).
        if ($pkRunning.Count -gt 0) {
            $pkStillWaiting = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($pkJob in $pkRunning) {
                $pkCbDone = $false
                $pkPolled = do { & $pkJobPollCompleted $pkJob; $pkCbDone = $true } while ($false)
                if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobPollCompleted' -PkContext $pkCallbackContext }
                if ($pkPolled -is [object[]]) { $pkPolled = $pkPolled[-1] }   # only the last value counts: see the main poll pass
                if ($pkPolled) {
                    $pkPendingBefore = $pkPending.Count
                    $pkCbDone = $false
                    $pkFinalizing = $pkJob
                    $null = do { & $pkJobFinalize $pkJob $pkPending; $pkCbDone = $true } while ($false)
                    $pkFinalizing = $null
                    if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-JobFinalize' -PkContext $pkCallbackContext }
                    $pkJob['SlotReleased'] = $true   # first: see the main poll pass
                    if ($pkIsSharedBudget) { $null = $pkMaxConcurrent.Release() }
                    try { if ($pkJob['Proc']) { $pkJob['Proc'].Dispose() } } catch { }   # a failed Dispose can't affect the result already taken
                    # Whatever JobFinalize queued (a retry, follow-ups) joins its group
                    # here, read off the queue rather than a returned flag. Only when the
                    # queue grew: walking it for every job is slow on a large batch.
                    if ($pkPending.Count -gt $pkPendingBefore) {
                        $pkQueuedIndex = 0
                        foreach ($pkQueued in $pkPending) {
                            if ($pkQueuedIndex -ge $pkPendingBefore) {
                                if ($null -eq $pkQueued['GroupKey']) { $pkQueued['GroupKey'] = $pkJob['GroupKey']; if (-not $pkQueued.ContainsKey('Group')) { $pkQueued['Group'] = $pkJob['Group'] } }
                                if ($pkGroupStates.ContainsKey($pkQueued['GroupKey'])) { $pkGroupStates[$pkQueued['GroupKey']].Outstanding++ }
                            }
                            $pkQueuedIndex++
                        }
                    }
                    if ($null -ne $pkJob['GroupKey']) {
                        $pkKey = $pkJob['GroupKey']
                        if ($pkGroupStates.ContainsKey($pkKey)) {
                            $pkState = $pkGroupStates[$pkKey]
                            $pkState.Outstanding--
                            if ($pkState.Outstanding -le 0 -and -not $pkState.Completed) {
                                $null = Invoke-PkCallback -PkCallback $pkGroupCompleteCallback -PkArgs @(,$pkState.GroupInfo) -PkName '-GroupCompleteCallback' -PkContext $pkCallbackContext
                                $pkState.Completed = $true
                                $pkActiveGroupCount--
                                $pkGroupResults.Add([pscustomobject][ordered]@{ GroupInfo = $pkState.GroupInfo; Completed = $true; Aborted = $false })
                            }
                        } else {
                            Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (final pass). This should be unreachable.") -Level Error
                        }
                    }
                } else {
                    $pkStillWaiting.Add($pkJob)
                }
            }
            $pkRunning = $pkStillWaiting
        }

        # Same per-job steps as the teardown in the finally below; keep the two in step.
        if ($pkRunning.Count -gt 0) {
            $pkDispatchResult.ForceKilledCount = $pkRunning.Count
            Write-PkMessage ("ProcessDispatch: force-stopping " + $pkRunning.Count + " job(s)" + (Get-PkForceStopReason -TimeoutSeconds $pkAbortTimeoutSeconds) + ".") -Level Warn
            Stop-PkJobProcesses -Jobs $pkRunning
            foreach ($pkJob in $pkRunning) {
                try { if ($pkJob['Proc']) { $null = $pkJob['Proc'].WaitForExit(5000) } } catch { }   # a custom starter's .Proc may not be a Process; the kill above already ran
                try { $null = Invoke-PkCallback -PkCallback $pkJobAbortCleanup -PkArgs @(,$pkJob) -PkName '-JobAbortCleanup' -PkContext $pkCallbackContext } catch { }   # one job's failed cleanup mustn't skip the others'
                $pkJob['SlotReleased'] = $true   # first: see the main poll pass
                if ($pkIsSharedBudget) { try { $null = $pkMaxConcurrent.Release() } catch { } }   # best effort: one failed release mustn't stop the other jobs' cleanup
                try { if ($pkJob['Proc']) { $pkJob['Proc'].Dispose() } } catch { }   # the job is over either way
            }
        }
    }
    $pkLoopDone = $true
    } finally {
        if (-not $pkLoopDone) {
            # Best-effort teardown after an error or a stop (an error carries
            # on up by itself). Jobs with SlotReleased set are already done:
            # their slot is released and their process disposed, or both are
            # about to be. Same per-job steps as the force-stop above; keep the
            # two in step.
            $pkTearDown = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($pkJob in $pkRunning) { if (-not $pkJob['SlotReleased']) { $pkTearDown.Add($pkJob) } }
            if ($null -ne $pkStarting -and -not $pkTearDown.Contains($pkStarting)) { $pkTearDown.Add($pkStarting) }
            Stop-PkJobProcesses -Jobs $pkTearDown
            foreach ($pkJob in $pkTearDown) {
                try { if ($pkJob['Proc']) { $null = $pkJob['Proc'].WaitForExit(5000) } } catch { }   # a custom starter's .Proc may not be a Process; the kill above already ran
                if (-not [object]::ReferenceEquals($pkJob, $pkFinalizing)) {
                    try { $null = Invoke-PkCallback -PkCallback $pkJobAbortCleanup -PkArgs @(,$pkJob) -PkName '-JobAbortCleanup' -PkContext $pkCallbackContext } catch { }   # one job's failed cleanup mustn't skip the others'
                }
                $pkJob['SlotReleased'] = $true   # first, as in the force-stop above
                if ($pkIsSharedBudget) { try { $null = $pkMaxConcurrent.Release() } catch { } }   # best effort: one failed release mustn't stop the other jobs' cleanup
                try { if ($pkJob['Proc']) { $pkJob['Proc'].Dispose() } } catch { }   # the job is over either way
            }
        }
    }

    # Jobs still pending here were never started (only reachable via
    # cancellation). Clean them up and count them off, or their group could
    # never be reported.
    if ($pkPending.Count -gt 0) {
        foreach ($pkJob in $pkPending) {
            try { $null = Invoke-PkCallback -PkCallback $pkJobAbortCleanup -PkArgs @(,$pkJob) -PkName '-JobAbortCleanup' -PkContext $pkCallbackContext } catch { }   # one job's failed cleanup mustn't skip the others'
            $pkKey = $pkJob['GroupKey']
            if ($pkGroupStates.ContainsKey($pkKey)) { $pkGroupStates[$pkKey].Outstanding-- }
        }
        $pkPending.Clear()
    }

    $pkDispatchResult.Aborted = $pkCancelToken.IsCancellationRequested
    foreach ($pkState in $pkGroupStates.Values) {
        if (-not $pkState.Completed) {
            # An aborted group still gets its callback: it's where the caller
            # credits the jobs that did finish. Swallowed, so one failing
            # callback doesn't cost the other groups their results.
            try { $null = Invoke-PkCallback -PkCallback $pkGroupCompleteCallback -PkArgs @(,$pkState.GroupInfo) -PkName '-GroupCompleteCallback' -PkContext $pkCallbackContext } catch { }
            $pkState.Completed = $true
            $pkGroupResults.Add([pscustomobject][ordered]@{ GroupInfo = $pkState.GroupInfo; Completed = $false; Aborted = $true })
        }
    }

    return [pscustomobject]$pkDispatchResult
}

function New-PkBatchResult {
    # One Invoke-PkProcessBatch result, the same shape however the command
    # ended: ran (-Completed is Complete-PkProcess's object), couldn't start
    # (-StartError), or stopped by an abort (-Aborted; -Process is its program,
    # if it was started, for how long it ran).
    param(
        [hashtable]$Command,
        $Completed = $null,
        [string]$StartError = $null,
        [switch]$Aborted,
        [bool]$TimedOut = $false,
        $Process = $null
    )
    $r = [ordered]@{ Command = $Command; ExitCode = $null; Stdout = $null; Stderr = $null; StreamTimedOut = $false; StreamError = $null
                     StartError = $null; Aborted = [bool]$Aborted; TimedOut = $TimedOut; Duration = $null }
    if ($null -ne $Completed) {
        $r.ExitCode = $Completed.ExitCode; $r.Stdout = $Completed.Stdout; $r.Stderr = $Completed.Stderr
        $r.StreamTimedOut = $Completed.StreamTimedOut; $r.StreamError = $Completed.StreamError; $r.Duration = $Completed.Duration
    } elseif ($null -ne $Process) {
        $r.Duration = Get-PkProcessDuration -Process $Process
    }
    if ($StartError) { $r.StartError = $StartError }
    return [pscustomobject]$r
}

function Get-PkStartFailureCause {
    # Why a command couldn't start, for telling repeats apart: Windows' own text
    # for the error code where there is one, because on 7 the exception's text
    # for one failure differs by working directory.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$StartError)
    for ($e = $StartError.Exception; $null -ne $e; $e = $e.InnerException) {
        if ($e -is [System.ComponentModel.Win32Exception]) {
            return [System.ComponentModel.Win32Exception]::new($e.NativeErrorCode).Message.TrimEnd('.')
        }
    }
    return [string]$StartError
}

function Invoke-PkProcessBatch {
    # .SYNOPSIS
    # Runs a list of external programs, a limited number at a time, and returns
    # each one's exit code and output.
    # .DESCRIPTION
    # Each command is a hashtable: @{ FilePath = ...; Arguments = ... } plus,
    # optionally, WorkingDirectory, OutputEncoding (overrides -OutputEncoding),
    # TimeoutSeconds (overrides -TimeoutSeconds) and any keys of your own, which
    # come back on the result's Command. Inside
    # Invoke-PkRun, Ctrl+C lets running programs finish (up to -AbortTimeoutSeconds)
    # and starts no new ones; a second Ctrl+C kills them right away. Every
    # command is tried, and one that can't start gets a StartError on its result.
    # Repeats of the same failure for the same program are reported once, with a
    # count at the end.
    # .PARAMETER Commands
    # The command hashtables. $null or empty returns no results.
    # .PARAMETER MaxConcurrent
    # How many programs run at once (default 4). -MaxParallel also works.
    # .PARAMETER OnComplete
    # { param($command, $result) } run on the main thread as each program finishes.
    # Not called for one that couldn't start or was stopped by an abort.
    # .PARAMETER AbortTimeoutSeconds
    # How long an abort waits for running programs before killing them (default 60).
    # -DrainTimeoutSeconds also works.
    # .PARAMETER TimeoutSeconds
    # Kill a program still running after this long (default 0, no limit). Its
    # result has TimedOut = $true.
    # .PARAMETER OutputEncoding
    # How to decode every program's output: a name like 'utf-8', a code page number,
    # or a [System.Text.Encoding]. Default: the console's code page.
    # .OUTPUTS
    # An object with Results, Aborted and ForceKilledCount. Each result has Command,
    # ExitCode, Stdout, Stderr, StreamTimedOut, StreamError, StartError, Aborted,
    # TimedOut and Duration, in the order the programs finished.
    # .EXAMPLE
    # $commands = foreach ($f in Get-ChildItem *.png) { @{ FilePath = 'cjxl.exe'; Arguments = @($f.FullName, "$($f.FullName).jxl") } }
    # $batch = Invoke-PkRun { Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 6 }
    # $batch.Results | Format-Table ExitCode, Aborted, TimedOut
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$Commands,
        [Alias('MaxParallel')]
        [int]$MaxConcurrent = 4,
        [scriptblock]$OnComplete = $null,
        [Alias('DrainTimeoutSeconds')]
        [int]$AbortTimeoutSeconds = 60,
        [double]$TimeoutSeconds = 0,
        $OutputEncoding = $null
    )
    # pk-prefixed, parameters included: inside a worker runspace the kit isn't
    # a module, so a callback without .GetNewClosure() sees this frame's
    # variables. Same in Add-PkDispatchGroupJobs, Invoke-PkProcessDispatch, Invoke-PkProcessDispatchCore.
    $pkCommands = $Commands
    $pkMaxConcurrent = $MaxConcurrent
    $pkOnComplete = $OnComplete
    $pkAbortTimeoutSeconds = $AbortTimeoutSeconds
    $pkTimeoutSeconds = $TimeoutSeconds
    $pkOutputEncoding = $OutputEncoding
    Remove-Variable -Name Commands, MaxConcurrent, OnComplete, AbortTimeoutSeconds, TimeoutSeconds, OutputEncoding -Scope Local

    # Checked once here, so a bad name fails the call instead of every command.
    $null = Resolve-PkEncoding -Encoding $pkOutputEncoding
    # Invoke-PkProcessDispatch makes the same three checks; these name the
    # batch. Keep the two in step. Get-PkJobTimeLimit checks a job's own
    # TimeoutSeconds key by the same rule.
    if ($pkMaxConcurrent -lt 1) { throw ("Invoke-PkProcessBatch: -MaxConcurrent must be at least 1 (got " + $pkMaxConcurrent + ").") }
    if ([double]::IsNaN($pkTimeoutSeconds) -or [double]::IsInfinity($pkTimeoutSeconds) -or $pkTimeoutSeconds -lt 0) {
        throw ("Invoke-PkProcessBatch: -TimeoutSeconds must be a number of seconds, 0 (no limit) or more (got " + $pkTimeoutSeconds + ").")
    }
    if ($pkAbortTimeoutSeconds -lt 0) {
        throw ("Invoke-PkProcessBatch: -AbortTimeoutSeconds must be 0 or more (got " + $pkAbortTimeoutSeconds + "). It's how long an abort waits for running programs before force-stopping them; 0 doesn't wait.")
    }

    $pkResults = [System.Collections.Generic.List[object]]::new()
    $pkState   = @{ Given = $false }
    # The closures below can't see the module's private functions (a
    # .GetNewClosure() block only sees global ones), so take these along.
    $pkNewBatchResult = ${function:New-PkBatchResult}
    $pkStartProcessCore = ${function:Start-PkProcessCore}
    $pkGetJobTimeLimit = ${function:Get-PkJobTimeLimit}
    $pkGetStartFailureCause = ${function:Get-PkStartFailureCause}
    $pkWriteCallbackLoopWarning = ${function:Write-PkCallbackLoopWarning}
    # Invoke-PkCallback's -PkContext: callbacks that used continue/break are
    # warned about once each, under this prefix.
    $pkCallbackContext = @{ Prefix = 'Invoke-PkProcessBatch: '; Warned = @{} }
    $pkCallerState = $PSCmdlet.SessionState
    $pkStartFailures = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    # The first failure for a program and cause goes out in full; the rest only
    # add to the count that's reported after the dispatch.
    $pkReportStartFailure = {
        param($pkCommand, $pkError)
        $pkResults.Add((& $pkNewBatchResult -Command $pkCommand -StartError ([string]$pkError)))
        $pkFilePath = [string]$pkCommand['FilePath']
        $pkCause = & $pkGetStartFailureCause -StartError $pkError
        $pkFailureKey = $pkFilePath + '|' + $pkCause
        if ($pkStartFailures.Contains($pkFailureKey)) {
            $pkStartFailures[$pkFailureKey].More++
            return
        }
        $pkStartFailures[$pkFailureKey] = @{ FilePath = $pkFilePath; Cause = $pkCause; More = 0 }
        Write-PkMessage ("Invoke-PkProcessBatch: a command couldn't start: " + $pkError) -Level Error
    }.GetNewClosure()

    $pkGroupProvider = {
        if ($pkState.Given) { return $null }
        $pkState.Given = $true
        return @{ Name = 'batch' }
    }.GetNewClosure()

    $pkJobBuilder = {
        param($pkGroup)
        $pkJobs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($pkC in $pkCommands) {
            if ($null -eq $pkC) { continue }
            $pkEncoding = $pkOutputEncoding
            if ($pkC.ContainsKey('OutputEncoding')) { $pkEncoding = $pkC['OutputEncoding'] }
            # Here, not left to the dispatcher: a job it refuses never reaches the
            # starter below, so the command would get no result.
            try {
                $null = & $pkGetJobTimeLimit -Job $pkC
            } catch {
                & $pkReportStartFailure $pkC $_
                continue
            }
            $pkJobs.Add(@{ FilePath = $pkC['FilePath']; Arguments = $pkC['Arguments']; WorkingDirectory = [string]$pkC['WorkingDirectory']; OutputEncoding = $pkEncoding; TimeoutSeconds = $pkC['TimeoutSeconds']; Command = $pkC })
        }
        return $pkJobs
    }.GetNewClosure()

    $pkJobStarter = {
        param($pkJob)
        try {
            $pkStarted = & $pkStartProcessCore -CallerState $pkCallerState -FilePath $pkJob['FilePath'] -Arguments $pkJob['Arguments'] -WorkingDirectory $pkJob['WorkingDirectory'] -OutputEncoding $pkJob['OutputEncoding']
        } catch {
            $pkJob['StartFailureReported'] = $true
            & $pkReportStartFailure $pkJob['Command'] $_
            throw
        }
        # Start-PkProcessCore's four keys (it builds them in two places); the
        # dispatcher's default starter copies them too: a new key goes in all four.
        $pkJob['Proc'] = $pkStarted.Proc; $pkJob['StdoutTask'] = $pkStarted.StdoutTask; $pkJob['StderrTask'] = $pkStarted.StderrTask
        $pkJob['Stopwatch'] = $pkStarted.Stopwatch
        return $pkJob
    }.GetNewClosure()

    $pkJobFinalize = {
        param($pkJob, $pkPendingQueue)
        $pkR = & $pkNewBatchResult -Command $pkJob['Command'] -Completed (Complete-PkProcess -Job $pkJob) -TimedOut ([bool]$pkJob['TimedOut'])
        $pkResults.Add($pkR)
        if ($null -ne $pkOnComplete) {
            # Invoke-PkCallback, inlined: this runs per command.
            $pkCbDone = $false
            $null = do { & $pkOnComplete $pkJob['Command'] $pkR; $pkCbDone = $true } while ($false)
            if (-not $pkCbDone) { & $pkWriteCallbackLoopWarning -PkName '-OnComplete' -PkContext $pkCallbackContext }
        }
        return @{ Success = ($pkR.ExitCode -eq 0) }
    }.GetNewClosure()

    $pkJobAbortCleanup = {
        param($pkJob)
        # Called after a force-stop's kill and before the program is disposed,
        # so a started program's run time can still be read.
        $pkResults.Add((& $pkNewBatchResult -Command $pkJob['Command'] -Aborted -Process $pkJob['Proc']))
    }.GetNewClosure()

    $pkDispatchParams = @{
        GroupProvider = $pkGroupProvider; JobBuilder = $pkJobBuilder; JobStarter = $pkJobStarter
        JobFinalize = $pkJobFinalize; JobAbortCleanup = $pkJobAbortCleanup; MaxConcurrent = $pkMaxConcurrent
        AbortTimeoutSeconds = $pkAbortTimeoutSeconds; MaxQueueAhead = 1; TimeoutSeconds = $pkTimeoutSeconds
    }
    try {
        $pkDispatch = Invoke-PkProcessDispatch @pkDispatchParams
    } finally {
        foreach ($pkFailure in $pkStartFailures.Values) {
            if ($pkFailure.More -eq 0) { continue }
            $pkCommandWord = if ($pkFailure.More -eq 1) { 'command' } else { 'commands' }
            Write-PkMessage ("Invoke-PkProcessBatch: " + $pkFailure.More + " more " + $pkCommandWord + " couldn't start '" + $pkFailure.FilePath + "' (" + $pkFailure.Cause + ").") -Level Error
        }
    }

    return [pscustomobject][ordered]@{ Results = $pkResults; Aborted = $pkDispatch.Aborted; ForceKilledCount = $pkDispatch.ForceKilledCount }
}

# ==============================================================================
#  Runspace jobs - run PowerShell worker scripts in parallel
# ==============================================================================

function Get-PkWorkerSafeFunctionNames {
    # Kit functions every worker runspace gets automatically.
    return @('Write-PkMessage', 'Test-PkAbortSignal', 'Test-PkCancelRequested', 'Initialize-PkThreadPool', 'Stop-PkProcessTree', 'Stop-PkProcessTreeCore', 'Split-PkTaskkillArguments', 'Stop-PkJobProcesses', 'Get-PkProcessDuration', 'Resolve-PkEncoding',
             'Start-PkProcess', 'Wait-PkProcess', 'Wait-PkRunningJobs', 'Complete-PkProcess', 'Invoke-PkProcessWithTimeout',
             'Invoke-PkProcessDispatch', 'Invoke-PkProcessDispatchCore', 'Invoke-PkProcessBatch',
             'Register-PkCancellationSource', 'Unregister-PkCancellationSource', 'New-PkBatchResult', 'ConvertTo-PkArgumentString', 'Get-PkForceStopReason', 'Resolve-PkFileSystemPath', 'Add-PkDispatchGroupJobs', 'Start-PkProcessCore', 'Get-PkJobTimeLimit', 'Stop-PkTimedOutJob', 'Get-PkStartFailureCause', 'Resolve-PkArguments', 'Invoke-PkCallback', 'Write-PkCallbackLoopWarning', 'ConvertTo-PkArgumentStringCore')
}

function Get-PkHandlerParamCount {
    # How many parameters a callback declares, or -1 if it has no param()
    # block (it takes whatever it's given, in $args).
    param([Parameter(Mandatory)][scriptblock]$Callback)
    $ast = $Callback.Ast
    if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        if ($null -ne $ast.Parameters) { return $ast.Parameters.Count }   # function f($a, $b)
        $ast = $ast.Body
    }
    if ($null -eq $ast.ParamBlock) { return -1 }
    return $ast.ParamBlock.Parameters.Count
}

function Add-PkCrashedJob {
    # A worker threw: count it, record it with its job, announce it, and tell
    # -JobCrashedHandler. Shared by the main loop and the abort drain.
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$PkOutcome,
        [hashtable]$PkJob,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$PkError,
        [scriptblock]$PkHandler,
        [string]$PkWhen = "",
        [hashtable]$PkCallbackContext
    )
    $PkOutcome.CrashedCount++
    $PkOutcome.Crashed.Add([pscustomobject][ordered]@{ Job = $PkJob; Error = $PkError })
    Invoke-PkMessageHandler -Level Error -Message ("Error collecting runspace result" + $PkWhen + ": " + $PkError)
    if ($null -eq $PkHandler) { return }
    try {
        # The job only goes to a handler that has room for it: a one-parameter
        # handler with [CmdletBinding()] or [Parameter()] would throw on a
        # second argument.
        $pkParamCount = Get-PkHandlerParamCount -Callback $PkHandler
        $pkHandlerArgs = @($PkError, $PkJob)
        if ($pkParamCount -ne -1 -and $pkParamCount -lt 2) { $pkHandlerArgs = @(,$PkError) }
        $null = Invoke-PkCallback -PkCallback $PkHandler -PkArgs $pkHandlerArgs -PkName '-JobCrashedHandler' -PkContext $PkCallbackContext
    } catch {
        # Reported, not rethrown: a broken crash handler mustn't take the other workers down.
        Invoke-PkMessageHandler -Level Error -Message ("-JobCrashedHandler threw: " + $_)
    }
}

function Add-PkJobErrors {
    # A finished worker's non-terminating errors: print each and record it
    # with its job. Shared by the main loop and the abort drain. Called for a
    # crashed worker too: its error stream holds only the errors before the
    # one that stopped it.
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$PkOutcome,
        [hashtable]$PkJob,
        $PkErrors
    )
    if ($null -eq $PkErrors) { return }
    foreach ($pkError in $PkErrors) {
        $PkOutcome.Errors.Add([pscustomobject][ordered]@{ Job = $PkJob; Error = $pkError })
        Invoke-PkMessageHandler -Message ("Runspace error: " + $pkError.ToString()) -Level Error
    }
}

function Receive-PkCompletedHandles {
    param(
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [System.Collections.Specialized.OrderedDictionary]$Outcome,
        [scriptblock]$JobCrashedHandler,
        [hashtable]$CallbackContext
    )
    $stillActive = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($h in $Handles) {
        if ($h.Handle.IsCompleted) {
            $pkWorkerOutput = $null
            $pkCrash = $null
            try {
                try { $pkWorkerOutput = $h.PS.EndInvoke($h.Handle) } catch { $pkCrash = $_ }
                # Same as Invoke-PkRunspaceJobs' main loop: its errors, then the
                # crash, in the order they happened.
                Add-PkJobErrors -PkOutcome $Outcome -PkJob $h['Job'] -PkErrors $h.PS.Streams.Error
                if ($null -ne $pkCrash) {
                    Add-PkCrashedJob -PkOutcome $Outcome -PkJob $h['Job'] -PkError $pkCrash -PkHandler $JobCrashedHandler -PkWhen " during abort drain" -PkCallbackContext $CallbackContext
                }
            } finally {
                $h.PS.Dispose()
            }
            if ($null -ne $ResultHandler -and $null -ne $pkWorkerOutput) {
                foreach ($r in $pkWorkerOutput) {
                    # Invoke-PkCallback, inlined: this runs per result.
                    $pkCbDone = $false
                    $null = do { & $ResultHandler $r; $pkCbDone = $true } while ($false)
                    if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-ResultHandler' -PkContext $CallbackContext }
                }
            }
        } else {
            $stillActive.Add($h)
        }
    }
    return ,$stillActive
}

function Invoke-PkGracefulDrain {
    # After an abort: give running workers $TimeoutSeconds to finish, collect
    # what they return, force-stop the rest. Leaves the native handler thread
    # parked: on a window close it's released when Invoke-PkRun ends, so the
    # rest of the run still gets the few seconds Windows allows.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$MessageQueue,
        [int]$TimeoutSeconds = 60,
        [string]$AbortWaitMessage,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Outcome,
        [scriptblock]$JobCrashedHandler,
        [hashtable]$CallbackContext
    )

    if ($Handles.Count -eq 0) {
        return @{ ForceStoppedCount = 0 }
    }

    if (-not $PSBoundParameters.ContainsKey('AbortWaitMessage')) {
        $AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to " + $TimeoutSeconds + "s)..."
    }

    $localHandles  = $Handles
    $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
    $forceStoppedCount = 0

    if ($AbortWaitMessage -ne "") { Invoke-PkMessageHandler -Message $AbortWaitMessage -Level Warn }

    while ($localHandles.Count -gt 0 -and -not [PkConsoleCtrl]::IsCloseEvent -and -not [PkConsoleCtrl]::SkipDrain -and $abortDeadline.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $localHandles = Receive-PkCompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -Outcome $Outcome -JobCrashedHandler $JobCrashedHandler -CallbackContext $CallbackContext
        Receive-PkWorkerMessages -Queue $MessageQueue
        if ($localHandles.Count -gt 0) { [System.Threading.Thread]::Sleep(250) }
    }

    # One final pass before declaring anything force-stopped.
    if ($localHandles.Count -gt 0) {
        $localHandles = Receive-PkCompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -Outcome $Outcome -JobCrashedHandler $JobCrashedHandler -CallbackContext $CallbackContext
        Receive-PkWorkerMessages -Queue $MessageQueue
    }

    if ($localHandles.Count -gt 0) {
        $forceStoppedCount = $localHandles.Count
        Invoke-PkMessageHandler -Level Error -Message ("[ABORT] Force-stopping " + $forceStoppedCount + " job(s)" + (Get-PkForceStopReason -TimeoutSeconds $TimeoutSeconds) + ".")
        foreach ($h in $localHandles) {
            # BeginStop, not Stop: Stop() blocks until the pipeline
            # actually unwinds, and a worker stuck in a .NET call never does.
            try { $null = $h.PS.BeginStop($null, $null) } catch { }   # one worker that can't be asked to stop mustn't keep the rest from being asked
        }
    }

    Receive-PkWorkerMessages -Queue $MessageQueue

    return @{ ForceStoppedCount = $forceStoppedCount }
}

function Invoke-PkRunspaceJobs {
    # .SYNOPSIS
    # Runs a PowerShell scriptblock once per job, a limited number at a time, each in
    # its own runspace.
    # .DESCRIPTION
    # Each job hashtable's keys become the worker's parameters. A worker runspace
    # starts empty apart from cmdlets, installed modules and the kit's own worker
    # functions, so name every function of yours it calls in -SharedFunctionNames.
    # Each job starts in your current location, in a fresh scope: a folder change
    # or a variable from an earlier job doesn't carry over.
    # Only an error that stops the worker (throw, -ErrorAction Stop) counts as a
    # crash; a non-terminating one is printed, recorded in Errors, and the job's
    # output still counts.
    # The worker code is checked against the worker rules (see the README)
    # before anything starts, and each job's values before that job starts;
    # code or values that break them are refused.
    # .PARAMETER WorkerScript
    # A scriptblock with a param() block declaring every job key. If it declares
    # $CancelToken, it gets the run's cancellation token.
    # .PARAMETER JobParams
    # A list or array of job hashtables, or a single one. Use this or
    # -NextJobProvider.
    # .PARAMETER NextJobProvider
    # { } returning the next job hashtable, or $null when there are no more. Runs on
    # the main thread, so jobs can be produced lazily. Only its last value counts:
    # $null ends the run, otherwise the last hashtable is the job; anything else
    # it outputs is ignored, with a warning.
    # .PARAMETER SharedFunctionNames
    # Your functions the worker calls.
    # .PARAMETER MaxParallel
    # How many workers run at once. -MaxConcurrent also works.
    # .PARAMETER Cts
    # Your own CancellationTokenSource for the run; an abort cancels it too.
    # So does any exit that leaves workers running (one of your callbacks
    # throwing, say), so a worker that checks Test-PkCancelRequested is told.
    # .PARAMETER ResultHandler
    # { param($result) } on the main thread, once per object a worker returns.
    # .PARAMETER PollCallback
    # { } on the main thread, every loop pass (for progress and the like).
    # .PARAMETER JobCrashedHandler
    # { param($errorRecord, $job) } on the main thread when a worker throws, also
    # during an abort's drain. $job is the job hashtable that crashed; leave it out
    # of param() if you don't need it. The worker's own error is
    # $errorRecord.Exception.InnerException. If the handler throws, that's reported
    # as a message and the run carries on.
    # .PARAMETER DrainTimeoutSeconds
    # How long an abort waits for running workers before force-stopping them
    # (default 60). -AbortTimeoutSeconds also works.
    # .PARAMETER AbortWaitMessage
    # The message shown while an abort waits; '' for none.
    # .PARAMETER CheckWorkerSafety
    # Check the worker code and job values before starting. On unless you pass
    # -CheckWorkerSafety:$false, whatever Get-Help says the default is.
    # .OUTPUTS
    # An object with ForceStoppedCount (workers an abort stopped waiting for;
    # one stuck in a .NET call keeps running), CrashedCount, Aborted, Crashed
    # (one @{ Job; Error } entry per worker that threw) and Errors (one
    # @{ Job; Error } entry per non-terminating error a worker wrote).
    # .EXAMPLE
    # Invoke-PkRunspaceJobs -MaxParallel 4 -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -WorkerScript { param($Id) $Id * 2 } -ResultHandler { param($r) Write-Host $r }
    param(
        [Parameter(Mandatory)]
        [scriptblock]$WorkerScript,
        $JobParams = $null,
        [scriptblock]$NextJobProvider = $null,
        [string[]]$SharedFunctionNames = @(),
        [Parameter(Mandatory)]
        [Alias('MaxConcurrent')]
        [int]$MaxParallel,
        [System.Threading.CancellationTokenSource]$Cts = $null,
        [scriptblock]$ResultHandler = $null,
        [scriptblock]$PollCallback = $null,
        [scriptblock]$JobCrashedHandler = $null,
        [Alias('AbortTimeoutSeconds')]
        [int]$DrainTimeoutSeconds = 60,
        [string]$AbortWaitMessage,
        [switch]$CheckWorkerSafety
    )
    # Not passed means on: a switch can't default to on without a lint warning.
    $checkSafety = (-not $PSBoundParameters.ContainsKey('CheckWorkerSafety')) -or $CheckWorkerSafety.IsPresent

    if ($null -eq $JobParams -and $null -eq $NextJobProvider) {
        throw "Invoke-PkRunspaceJobs: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-PkRunspaceJobs: supply only one of -JobParams or -NextJobProvider, not both."
    }
    if ($MaxParallel -lt 1) { throw "Invoke-PkRunspaceJobs: -MaxParallel must be at least 1." }
    if ($DrainTimeoutSeconds -lt 0) {
        throw ("Invoke-PkRunspaceJobs: -DrainTimeoutSeconds must be 0 or more (got " + $DrainTimeoutSeconds + "). It's how long an abort waits for running workers before force-stopping them; 0 doesn't wait.")
    }

    # A List, an array or a single hashtable: a one-job list built with
    # foreach collapses to a bare hashtable.
    if ($null -ne $JobParams) {
        $normalizedJobs = [System.Collections.Generic.List[hashtable]]::new()
        if ($JobParams -is [hashtable]) {
            $normalizedJobs.Add($JobParams)
        } else {
            foreach ($jobEntry in $JobParams) {
                if ($jobEntry -isnot [hashtable]) {
                    throw ("Invoke-PkRunspaceJobs: -JobParams entry " + $normalizedJobs.Count + " is not a hashtable. Each job must be a hashtable of the worker's parameters.")
                }
                $normalizedJobs.Add($jobEntry)
            }
        }
        $JobParams = $normalizedJobs
    }

    $outcome = [ordered]@{ ForceStoppedCount = 0; CrashedCount = 0; Aborted = $false; Crashed = [System.Collections.Generic.List[object]]::new(); Errors = [System.Collections.Generic.List[object]]::new() }
    if ($null -ne $JobParams -and $JobParams.Count -eq 0) { return [pscustomobject]$outcome }

    if ($checkSafety) {
        $safetyFindings = Test-PkWorkerSafetyCore -WorkerScript $WorkerScript -SharedFunctionNames $SharedFunctionNames -SessionState $PSCmdlet.SessionState
        if ($safetyFindings.Count -gt 0) {
            $safetyLines = foreach ($f in $safetyFindings) { "  " + $f.Text }
            throw ("Invoke-PkRunspaceJobs: worker code breaks the worker-safety rules (see README.md):`r`n" + ($safetyLines -join "`r`n"))
        }
    }

    if ($null -eq $ResultHandler) { $ResultHandler = { param($r) } }

    # Passing a parameter the worker doesn't declare fails the whole invoke
    # with an unhelpful binding error.
    $declaredParams = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $WorkerScript.Ast.ParamBlock) {
        foreach ($p in $WorkerScript.Ast.ParamBlock.Parameters) { $null = $declaredParams.Add($p.Name.VariablePath.UserPath) }
    }

    # A fixed list can be checked before a single worker starts.
    if ($null -ne $JobParams) {
        for ($jobIndex = 0; $jobIndex -lt $JobParams.Count; $jobIndex++) {
            foreach ($key in $JobParams[$jobIndex].Keys) {
                if (-not $declaredParams.Contains([string]$key)) {
                    throw ("Invoke-PkRunspaceJobs: job " + $jobIndex + " supplies '" + $key + "', but -WorkerScript's param() block doesn't declare it. Nothing was started.")
                }
            }
            if ($checkSafety) {
                $sbKey = Get-PkScriptBlockJobKey -Job $JobParams[$jobIndex]
                if ($null -ne $sbKey) { throw ((Get-PkScriptBlockJobMessage -Job ("job " + $jobIndex) -Key $sbKey) + " Nothing was started.") }
            }
        }
    }

    $fixedListIndex = 0
    $ownCts         = $null
    $registeredCallerCts = $false
    $messageQueue   = $null
    $pool           = $null
    $handles        = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted  = $false
    # Invoke-PkCallback's -PkContext: callbacks that used continue/break are
    # warned about once each, under this prefix.
    $pkCallbackContext = @{ Prefix = 'Invoke-PkRunspaceJobs: '; Warned = @{} }

    try {
        if ($null -eq $Cts) {
            $ownCts = [System.Threading.CancellationTokenSource]::new()
            Register-PkCancellationSource -Cts $ownCts
            $Cts = $ownCts
        } else {
            # The caller's own source: register it for the length of this
            # run so Ctrl+C cancels it too.
            Register-PkCancellationSource -Cts $Cts
            $registeredCallerCts = $true
        }
        $messageQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $allShared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in (Get-PkWorkerSafeFunctionNames)) { $null = $allShared.Add($n) }
        foreach ($n in $SharedFunctionNames)            { $null = $allShared.Add($n) }
        # The kit's worker functions come from this module; yours from where
        # you called this (a script's own functions, functions inside a
        # function, a module's private ones).
        $kitWorkerNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-PkWorkerSafeFunctionNames), [System.StringComparer]::OrdinalIgnoreCase)
        $callerFns = Get-PkCallerFunction -SessionState $PSCmdlet.SessionState -Name @($allShared | Where-Object { -not $kitWorkerNames.Contains($_) })
        foreach ($sharedFn in $allShared) {
            $fnInfo = $null
            if ($kitWorkerNames.Contains($sharedFn)) { $fnInfo = Get-Item -LiteralPath ("Function:\" + $sharedFn) -ErrorAction SilentlyContinue }
            else { $fnInfo = $callerFns[$sharedFn] }
            if ($null -eq $fnInfo) {
                throw ("Invoke-PkRunspaceJobs: -SharedFunctionNames entry '" + $sharedFn + "' does not resolve to a defined function - check for a typo, or that the file defining it was dot-sourced before this call.")
            }
            $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($sharedFn, $fnInfo.Definition))
        }
        # Global variables in every worker runspace: how kit functions know
        # they're in a worker, and where they find the run's token.
        $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('PkWorkerQueue', $messageQueue, 'ParallelKit worker message queue'))
        $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('PkCancelToken', $Cts.Token, 'ParallelKit run cancellation token'))

        $pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $iss, $Host)
        $pool.Open()

        # Each job starts in the caller's current location: the real folder,
        # since a New-PSDrive drive doesn't exist in the worker.
        $workerLocation = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
        # Every job runs this: move to that folder, then run the worker in its
        # own scope with the job's values. Per job, because runspaces are
        # reused. One script, not a Set-Location statement before the worker:
        # with a second statement a pool runspace's pipeline never completed
        # (5.1 and 7). The prefix shares the worker's first line, so error line
        # numbers match its code. If the folder is gone, the job runs wherever
        # its runspace is.
        $jobScript = 'param([string]$PkJobLocation, [hashtable]$PkJobValues) if ($PkJobLocation) { Set-Location -LiteralPath $PkJobLocation -ErrorAction SilentlyContinue }; & {' +
            $WorkerScript.ToString() + "`n} @PkJobValues"

        while ((-not $scanExhausted -or $handles.Count -gt 0) -and -not $Cts.Token.IsCancellationRequested) {

            while (-not $scanExhausted -and $handles.Count -lt $MaxParallel -and -not $Cts.Token.IsCancellationRequested) {
                if ($null -ne $JobParams) {
                    if ($fixedListIndex -lt $JobParams.Count) {
                        $nextJob = $JobParams[$fixedListIndex]
                        $fixedListIndex++
                    } else {
                        $nextJob = $null
                    }
                } else {
                    # A job is one hashtable, so the last value decides: $null
                    # ends the run, otherwise the last hashtable is the job.
                    # Anything else the provider let out (a leaked index, or a
                    # hashtable before its answer) is ignored, with a warning.
                    $nextRaw = Invoke-PkCallback -PkCallback $NextJobProvider -PkName '-NextJobProvider' -PkContext $pkCallbackContext
                    $nextJob = $null
                    $rawItems = @($nextRaw)   # empty when it output nothing: the end
                    $jobIndex = -1
                    if ($rawItems.Count -gt 0 -and $null -ne $rawItems[-1]) {
                        for ($rawIndex = $rawItems.Count - 1; $rawIndex -ge 0 -and $jobIndex -lt 0; $rawIndex--) {
                            if ($rawItems[$rawIndex] -is [hashtable]) { $jobIndex = $rawIndex }
                        }
                    }
                    if ($jobIndex -ge 0) { $nextJob = $rawItems[$jobIndex] }
                    $strayCount = 0
                    for ($rawIndex = 0; $rawIndex -lt $rawItems.Count; $rawIndex++) {
                        if ($rawIndex -ne $jobIndex -and $null -ne $rawItems[$rawIndex]) { $strayCount++ }
                    }
                    if ($strayCount -gt 0) {
                        Invoke-PkMessageHandler -Level Warn -Message ("Invoke-PkRunspaceJobs: -NextJobProvider output " + $strayCount + " value(s) besides its job hashtable or `$null - ignored. Output only the next job, or `$null when there are no more (`$null = ... discards a value you don't want).")
                    }
                }
                if ($null -eq $nextJob) { $scanExhausted = $true; break }

                foreach ($key in $nextJob.Keys) {
                    if (-not $declaredParams.Contains([string]$key)) {
                        throw ("Invoke-PkRunspaceJobs: a job supplies '" + $key + "', but -WorkerScript's param() block doesn't declare it.")
                    }
                }
                if ($checkSafety -and $null -eq $JobParams) {
                    $sbKey = Get-PkScriptBlockJobKey -Job $nextJob
                    if ($null -ne $sbKey) { throw (Get-PkScriptBlockJobMessage -Job "a job from -NextJobProvider" -Key $sbKey) }
                }

                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                $jobValues = @{}
                foreach ($key in $nextJob.Keys) { $jobValues[$key] = $nextJob[$key] }
                if ($declaredParams.Contains('CancelToken') -and -not $nextJob.ContainsKey('CancelToken')) {
                    $jobValues['CancelToken'] = $Cts.Token
                }
                $jobLocation = ""
                if ([System.IO.Directory]::Exists($workerLocation)) { $jobLocation = $workerLocation }
                # A local scope too, so variables a job sets (preference
                # variables included) don't carry over to the next job.
                $null = $ps.AddScript($jobScript, $true).AddParameter('PkJobLocation', $jobLocation).AddParameter('PkJobValues', $jobValues)
                $handles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Job = $nextJob })
            }

            $null = Test-PkAbortSignal
            Receive-PkWorkerMessages -Queue $messageQueue
            if ($null -ne $PollCallback) { $null = Invoke-PkCallback -PkCallback $PollCallback -PkName '-PollCallback' -PkContext $pkCallbackContext }

            $stillPending = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $handles) {
                if ($h.Handle.IsCompleted) {
                    $pkWorkerOutput = $null
                    $pkCrash = $null
                    try {
                        try { $pkWorkerOutput = $h.PS.EndInvoke($h.Handle) } catch { $pkCrash = $_ }
                        # Same as Receive-PkCompletedHandles: its errors, then
                        # the crash, in the order they happened.
                        Add-PkJobErrors -PkOutcome $outcome -PkJob $h['Job'] -PkErrors $h.PS.Streams.Error
                        if ($null -ne $pkCrash) {
                            # The worker itself threw - there is no result, so
                            # -ResultHandler is never called for this job.
                            Add-PkCrashedJob -PkOutcome $outcome -PkJob $h['Job'] -PkError $pkCrash -PkHandler $JobCrashedHandler -PkCallbackContext $pkCallbackContext
                        }
                    } finally {
                        $h.PS.Dispose()
                    }
                    if ($null -ne $pkWorkerOutput) {
                        foreach ($r in $pkWorkerOutput) {
                            # Invoke-PkCallback, inlined: this runs per result.
                            $pkCbDone = $false
                            $null = do { & $ResultHandler $r; $pkCbDone = $true } while ($false)
                            if (-not $pkCbDone) { Write-PkCallbackLoopWarning -PkName '-ResultHandler' -PkContext $pkCallbackContext }
                        }
                    }
                } else {
                    $stillPending.Add($h)
                }
            }
            $handles = $stillPending
            if ($handles.Count -gt 0 -and ($scanExhausted -or $handles.Count -ge $MaxParallel)) {
                # Until a worker finishes or the token is canceled. The 100 ms cap
                # keeps worker messages, -PollCallback and the abort flag moving.
                # WaitAny holds 63 handles at most on an STA thread, one of them the
                # token; a worker past that is only noticed when the time is up.
                $workerWaits = [System.Collections.Generic.List[System.Threading.WaitHandle]]::new()
                foreach ($h in $handles) {
                    if ($workerWaits.Count -ge 62) { break }
                    $workerWaits.Add($h.Handle.AsyncWaitHandle)
                }
                $workerWaits.Add($Cts.Token.WaitHandle)
                $null = [System.Threading.WaitHandle]::WaitAny($workerWaits.ToArray(), 100)
            }
        }

        if ($Cts.Token.IsCancellationRequested) {
            $drainArgs = @{ Handles = $handles; ResultHandler = $ResultHandler; MessageQueue = $messageQueue; TimeoutSeconds = $DrainTimeoutSeconds; Outcome = $outcome; JobCrashedHandler = $JobCrashedHandler; CallbackContext = $pkCallbackContext }
            if ($PSBoundParameters.ContainsKey('AbortWaitMessage')) { $drainArgs.AbortWaitMessage = $AbortWaitMessage }
            $drainResult = Invoke-PkGracefulDrain @drainArgs
            $outcome.ForceStoppedCount = $drainResult.ForceStoppedCount
            $outcome.Aborted = $true
        }

        Receive-PkWorkerMessages -Queue $messageQueue
        if ($null -ne $PollCallback) { $null = Invoke-PkCallback -PkCallback $PollCallback -PkName '-PollCallback' -PkContext $pkCallbackContext }
    } finally {
        # Best-effort teardown; whatever exception is already in flight is the one to surface.
        $stillRunning = $false
        foreach ($h in $handles) {
            try {
                if (-not $h.Handle.IsCompleted) { $stillRunning = $true; $null = $h.PS.BeginStop($null, $null) }
            } catch { }   # one worker that can't be asked to stop mustn't keep the rest from being asked
        }
        if ($null -ne $pool) {
            # A worker stuck in a .NET call can't be stopped, and Dispose()
            # would wait for it, so close in the background.
            if ($stillRunning) {
                # An abandoned worker can run on to its last line once its call
                # returns. Cancel the token so one that checks
                # Test-PkCancelRequested before an irreversible step is told,
                # even on a non-abort exit (one of your callbacks threw).
                try { $Cts.Cancel() } catch { }   # already disposed by its owner: nothing left to tell
                try { $null = $pool.BeginClose($null, $null) } catch { }   # teardown only; the exception in flight, if any, is the one to surface
            }
            else               { try { $pool.Dispose() } catch { } }   # teardown only; the exception in flight, if any, is the one to surface
        }
        if ($null -ne $messageQueue) { try { Receive-PkWorkerMessages -Queue $messageQueue } catch { } }   # last messages are best effort; the exception in flight, if any, is the one to surface
        if ($null -ne $ownCts) {
            Unregister-PkCancellationSource -Cts $ownCts
            $ownCts.Dispose()
        }
        if ($registeredCallerCts) { Unregister-PkCancellationSource -Cts $Cts }
    }

    return [pscustomobject]$outcome
}

# ==============================================================================
#  Worker-safety check (see README.md, "The two rules")
# ==============================================================================

function Get-PkCallerFunction {
    # Looks function names up in the caller's session state, from its current
    # scope: a script's own functions, functions defined inside the calling
    # function, a calling module's private ones. Get-Item Function: here would
    # search this module, and InvokeCommand.GetCommand only finds global ones.
    # A scriptblock made from text and run with InvokeScript(SessionState) is
    # dot-sourced into the caller's scope, so the work happens inside & { }
    # with the names as quoted literals: nothing is assigned there.
    # -FollowAlias follows an alias to its function. Returns a hashtable:
    # name -> FunctionInfo (missing = not found).
    param(
        [Parameter(Mandatory)][System.Management.Automation.SessionState]$SessionState,
        [string[]]$Name,
        [switch]$FollowAlias
    )
    $found = @{}
    $names = @($Name | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($names.Count -eq 0) { return $found }
    $q = [string][char]39
    $quoted = foreach ($n in $names) { $q + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($n) + $q }
    $follow = '$false'
    if ($FollowAlias) { $follow = '$true' }
    $text = @'
& {
    foreach ($pkName in @(__NAMES__)) {
        $pkCmd = $pkName
        if (__FOLLOW__) {
            $pkHops = 0
            $pkAlias = Get-Item -LiteralPath ('Alias:' + $pkCmd) -ErrorAction SilentlyContinue
            while ($null -ne $pkAlias -and $pkHops -lt 5) {
                $pkCmd = $pkAlias.Definition
                $pkAlias = Get-Item -LiteralPath ('Alias:' + $pkCmd) -ErrorAction SilentlyContinue
                $pkHops++
            }
        }
        $pkFn = Get-Item -LiteralPath ('Function:' + $pkCmd) -ErrorAction SilentlyContinue
        if ($null -ne $pkFn) { [pscustomobject]@{ Name = $pkName; Fn = $pkFn } }
    }
}
'@
    $text = $text.Replace('__NAMES__', ($quoted -join ', ')).Replace('__FOLLOW__', $follow)
    $lookup = [scriptblock]::Create($text)
    foreach ($hit in $ExecutionContext.InvokeCommand.InvokeScript($SessionState, $lookup, @())) {
        $found[[string]$hit.Name] = $hit.Fn
    }
    return $found
}

function Get-PkCommandKind {
    # What a worker would need to run a command, given what the caller's
    # session resolves its name to ($Fn from Get-PkCallerFunction -FollowAlias,
    # or $null): 'Function' (one of your session's functions - must be
    # shared), 'UnloadableModuleFunction' (from a module a worker can't
    # autoload), or 'Other' (cmdlet, program, autoloadable module function,
    # or unknown). Uses the Alias: and Function: drives, not Get-Command,
    # which searches every module on $env:PSModulePath for a name that
    # doesn't resolve, on every Invoke-PkRunspaceJobs call.
    param([System.Management.Automation.FunctionInfo]$Fn)
    if ($null -eq $Fn) { return 'Other' }
    if ([string]::IsNullOrEmpty($Fn.ModuleName)) { return 'Function' }
    # The kit's own: a worker gets only the worker-safe ones, so the rest are
    # treated like your own functions.
    if ($Fn.ModuleName -eq 'ParallelKit') { return 'Function' }
    # A module function (Get-FileHash, say) autoloads in a worker like a
    # cmdlet does - but only if the module can be found by name. One imported
    # by path from elsewhere can't.
    if ($null -ne (Get-Module -ListAvailable -Name $Fn.ModuleName -ErrorAction SilentlyContinue | Select-Object -First 1)) { return 'Other' }
    return 'UnloadableModuleFunction'
}

function Get-PkScriptBlockJobKey {
    # The first key of a job hashtable whose value is a scriptblock, or holds
    # one up to three levels down (in arrays, lists, dictionaries and
    # [pscustomobject]s), else $null. A scriptblock belongs to the runspace
    # that made it: run in a worker it executes against the main thread's
    # session state, which can corrupt it (the kit's own functions vanish
    # mid-run), crash, or hang.
    param([Parameter(Mandatory)][hashtable]$Job)
    foreach ($key in $Job.Keys) {
        if (Test-PkHoldsScriptBlock -Value $Job[$key] -Depth 3) { return [string]$key }
    }
    return $null
}

function Test-PkHoldsScriptBlock {
    # Get-PkScriptBlockJobKey's walk. Leaves (strings, numbers) are checked
    # inline rather than through a call, so a big object[] stays cheap, and
    # a collection whose element type can't hold anything (byte[], string[],
    # List[int]) isn't walked at all.
    param($Value, [int]$Depth)
    if ($null -eq $Value) { return $false }
    if ($Value -is [scriptblock]) { return $true }
    if ($Depth -le 0) { return $false }
    $type = $Value.GetType()
    if ($Value -is [System.Collections.IDictionary]) {
        $items = $Value.Values
    } elseif ($Value -is [System.Collections.IList]) {
        $items = $Value
    } elseif ($type.FullName -eq 'System.Management.Automation.PSCustomObject') {
        $items = foreach ($p in $Value.PSObject.Properties) { if ($p -is [System.Management.Automation.PSNoteProperty]) { $p.Value } }
    } else {
        return $false
    }
    $elementType = $null
    if ($type.IsArray) { $elementType = $type.GetElementType() }
    elseif ($type.IsGenericType) { $genericArgs = $type.GetGenericArguments(); $elementType = $genericArgs[$genericArgs.Length - 1] }
    if ($null -ne $elementType -and ($elementType.IsValueType -or $elementType -eq [string])) { return $false }
    try {
        foreach ($inner in $items) {
            if ($null -eq $inner -or $inner -is [string] -or $inner -is [System.ValueType]) { continue }
            if ($inner -is [scriptblock]) { return $true }
            if ($Depth -gt 1 -and (Test-PkHoldsScriptBlock -Value $inner -Depth ($Depth - 1))) { return $true }
        }
    } catch {
        # A collection other threads are changing (a results sink shared by
        # workers) can't be enumerated safely, and PowerShell may wrap the
        # error, so catch anything. Skip it: such sinks hold results, not code.
        return $false
    }
    return $false
}

function Get-PkScriptBlockJobMessage {
    # Shared by the fixed-list and -NextJobProvider checks in Invoke-PkRunspaceJobs.
    param([string]$Job, [string]$Key)
    return ("Invoke-PkRunspaceJobs: " + $Job + " passes a scriptblock in '" + $Key + "'. A scriptblock made on the main thread and run in a worker can corrupt, crash or hang the run. " +
        "Pass its text instead (`$sb.ToString()) and rebuild it in the worker with [scriptblock]::Create(`$text), or pass -CheckWorkerSafety:`$false to skip this check.")
}

function Test-PkWorkerSafety {
    # .SYNOPSIS
    # Checks worker code against the worker rules without running it.
    # .DESCRIPTION
    # Invoke-PkRunspaceJobs runs this check itself; call it directly from your own
    # tests. Each finding has a Rule:
    #   MissingFunction  the worker calls a function of yours that isn't shared
    #   ScriptVariable   a shared function, or a nested block or function in the
    #                    worker, uses $script:
    #   DelegateCast     a scriptblock is cast to a .NET delegate, or passed into
    #                    a .NET method or constructor that turns it into one
    # Put "# pk:ignore" on a line to accept a finding there. Commands run through a
    # variable (& $cmd) aren't seen.
    # .PARAMETER WorkerScript
    # The worker scriptblock.
    # .PARAMETER SharedFunctionNames
    # The functions you'd pass to -SharedFunctionNames.
    # .OUTPUTS
    # A list of findings (empty when clean), each an object with Rule, Where, Line
    # and Text.

    # Scriptblocks handed to a worker as job values are refused separately,
    # by Invoke-PkRunspaceJobs (see Get-PkScriptBlockJobKey).
    param(
        [Parameter(Mandatory)]
        [scriptblock]$WorkerScript,
        [string[]]$SharedFunctionNames = @()
    )
    # Your functions are looked up where you called this from.
    return ,(Test-PkWorkerSafetyCore -WorkerScript $WorkerScript -SharedFunctionNames $SharedFunctionNames -SessionState $PSCmdlet.SessionState)
}

function Test-PkWorkerSafetyCore {
    # Test-PkWorkerSafety's body. -SessionState is the caller's, for finding
    # their functions (Invoke-PkRunspaceJobs passes its own caller's).
    param(
        [Parameter(Mandatory)][scriptblock]$WorkerScript,
        [string[]]$SharedFunctionNames = @(),
        [Parameter(Mandatory)][System.Management.Automation.SessionState]$SessionState
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $kitNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-PkWorkerSafeFunctionNames), [System.StringComparer]::OrdinalIgnoreCase)
    $listed   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $kitNames)            { $null = $listed.Add($n) }
    foreach ($n in $SharedFunctionNames) { $null = $listed.Add($n) }

    # What to check: the worker body, plus every shared function of yours.
    $targets = [System.Collections.Generic.List[hashtable]]::new()
    $targets.Add(@{ Where = 'worker script'; Ast = $WorkerScript.Ast; IsWorkerBody = $true })
    $callerFns = Get-PkCallerFunction -SessionState $SessionState -Name @($SharedFunctionNames | Where-Object { -not $kitNames.Contains($_) })
    foreach ($n in $SharedFunctionNames) {
        if ($kitNames.Contains($n)) { continue }
        $fn = $callerFns[$n]
        if ($null -eq $fn) {
            $findings.Add([pscustomobject][ordered]@{ Rule = 'MissingFunction'; Where = '-SharedFunctionNames'; Line = 0; Text = ("-SharedFunctionNames lists '" + $n + "', which is not a defined function") })
            continue
        }
        $targets.Add(@{ Where = ("function " + $n); Ast = $fn.ScriptBlock.Ast; IsWorkerBody = $false })
    }

    # Every command name the code calls, resolved in the caller's session in
    # one lookup rather than one per name.
    $cmdNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $targets) {
        foreach ($c in $t.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cmdName = $c.GetCommandName()
            if ($cmdName) { $null = $cmdNames.Add($cmdName) }
        }
    }
    $resolvedFns = Get-PkCallerFunction -SessionState $SessionState -Name @($cmdNames) -FollowAlias
    $kindCache = @{}
    foreach ($t in $targets) {
        $ast = $t.Ast

        foreach ($c in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cmdName = $c.GetCommandName()
            if (-not $cmdName) { continue }
            if ($c.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
            if (-not $kindCache.ContainsKey($cmdName)) {
                $fnForKind = $resolvedFns[$cmdName]
                if ($null -eq $fnForKind) {
                    # One of the kit's private helpers: invisible to the caller,
                    # but a worker can't run it unless it's worker-safe either.
                    $ownFn = Get-Item -LiteralPath ('Function:' + $cmdName) -ErrorAction SilentlyContinue
                    if ($null -ne $ownFn -and $ownFn.ModuleName -eq 'ParallelKit') { $fnForKind = $ownFn }
                }
                $kindCache[$cmdName] = Get-PkCommandKind -Fn $fnForKind
            }
            $kind = $kindCache[$cmdName]
            if ($kind -eq 'Function' -and -not $listed.Contains($cmdName)) {
                $findings.Add([pscustomobject][ordered]@{ Rule = 'MissingFunction'; Where = $t.Where; Line = $c.Extent.StartLineNumber
                                 Text = ($t.Where + " (line " + $c.Extent.StartLineNumber + ") calls '" + $cmdName + "', which is not in -SharedFunctionNames") })
            } elseif ($kind -eq 'UnloadableModuleFunction' -and -not $listed.Contains($cmdName)) {
                $findings.Add([pscustomobject][ordered]@{ Rule = 'MissingFunction'; Where = $t.Where; Line = $c.Extent.StartLineNumber
                                 Text = ($t.Where + " (line " + $c.Extent.StartLineNumber + ") calls '" + $cmdName + "', from a module a worker can't load by name (imported by path?) - put the module on `$env:PSModulePath, or list the function in -SharedFunctionNames") })
            }
        }

        # $script: - anywhere in a shared function; only inside NESTED
        # scriptblocks of the worker body (its own top level is fine).
        $scriptVarScopes = [System.Collections.Generic.List[object]]::new()
        if ($t.IsWorkerBody) {
            foreach ($nested in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) { $scriptVarScopes.Add($nested) }
            # A function defined inside the worker script is in the same
            # position as a shared one: called from a closure, its $script:
            # can read as empty.
            foreach ($innerFn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $scriptVarScopes.Add($innerFn.Body) }
        } else {
            $scriptVarScopes.Add($ast)
        }
        $seenRefs = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($scopeAst in $scriptVarScopes) {
            foreach ($ref in $scopeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.IsScript }, $true)) {
                if (-not $seenRefs.Add($ref.Extent.StartOffset)) { continue }
                if ($ref.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
                $findings.Add([pscustomobject][ordered]@{ Rule = 'ScriptVariable'; Where = $t.Where; Line = $ref.Extent.StartLineNumber
                                 Text = ($t.Where + " (line " + $ref.Extent.StartLineNumber + ") uses `$" + $ref.VariablePath.UserPath + " - it can silently read as empty in a worker") })
            }
        }

        foreach ($cv in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true)) {
            if ($cv.Type.TypeName.Name -notmatch '^(System\.)?(Func|Action|Predicate|Comparison|Converter)(\[|`|$)') { continue }
            if ($cv.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
            $findings.Add([pscustomobject][ordered]@{ Rule = 'DelegateCast'; Where = $t.Where; Line = $cv.Extent.StartLineNumber
                             Text = ($t.Where + " (line " + $cv.Extent.StartLineNumber + ") casts a scriptblock to the delegate [" + $cv.Type.TypeName.Name + "] - this can hang or crash a worker") })
        }

        # The implicit form: a scriptblock literal, or a variable assigned one
        # ({ }.GetNewClosure() included) anywhere in this code, passed to a
        # method or constructor: $dict.GetOrAdd($k, { }),
        # [System.Lazy[object]]::new($factory). .NET gets a delegate all the
        # same. Matched by variable name, not flow. .ForEach()/.Where() take
        # real scriptblocks. Storage methods ($list.Add($sb),
        # $queue.Enqueue($sb)) make no delegate and aren't flagged, so a
        # collection typed to hold delegates (List[Func[object]]) isn't caught.
        $storageMethods = @('Add', 'AddRange', 'Insert', 'Enqueue', 'Push', 'TryAdd', 'Contains', 'Remove', 'IndexOf', 'set_Item')
        $scriptBlockVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($assign in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $target = $assign.Left
            if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
            if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $rhs = $assign.Right
            if ($rhs -is [System.Management.Automation.Language.PipelineAst] -and $rhs.PipelineElements.Count -eq 1) { $rhs = $rhs.PipelineElements[0] }
            if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { $rhs = $rhs.Expression }
            if ($rhs -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$rhs.Member.Extent.Text -eq 'GetNewClosure') { $rhs = $rhs.Expression }
            if ($rhs -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $null = $scriptBlockVars.Add($target.VariablePath.UserPath) }
        }
        foreach ($call in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($null -eq $call.Arguments) { continue }
            $memberName = [string]$call.Member.Extent.Text
            if ($memberName -in @('ForEach', 'Where')) { continue }
            if ($memberName -in $storageMethods) { continue }
            $passed = $null
            foreach ($argument in $call.Arguments) {
                if ($argument -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $passed = 'a scriptblock' }
                elseif ($argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $scriptBlockVars.Contains($argument.VariablePath.UserPath)) {
                    $passed = ("the scriptblock in `$" + $argument.VariablePath.UserPath)
                }
            }
            if ($null -eq $passed) { continue }
            if ($call.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
            $findings.Add([pscustomobject][ordered]@{ Rule = 'DelegateCast'; Where = $t.Where; Line = $call.Extent.StartLineNumber
                             Text = ($t.Where + " (line " + $call.Extent.StartLineNumber + ") passes " + $passed + " to ." + $memberName + "() - .NET turns it into a delegate, which can hang or crash a worker (add '# pk:ignore' if this method really takes a scriptblock)") })
        }
    }

    return ,$findings
}

# ==============================================================================
#  Public functions (the ones README.md documents)
# ==============================================================================

# Imported globally: a .GetNewClosure() block only sees global functions,
# so this lets the batch's callbacks, and yours, call them. The same list is
# $publicFunctions in ParallelKit.Harness.ps1; keep the two in step.
Export-ModuleMember -Function @(
    'Set-PkMessageHandler', 'Write-PkMessage', 'Initialize-ParallelKit', 'Register-PkCancellationSource',
    'Unregister-PkCancellationSource', 'Reset-PkAbortState', 'Request-PkAbort', 'Test-PkAbortSignal', 'Test-PkCancelRequested',
    'Get-PkAbortTriggerLabel', 'Invoke-PkRun', 'ConvertTo-PkArgumentString', 'Start-PkProcess', 'Stop-PkProcessTree',
    'Wait-PkProcess', 'Complete-PkProcess', 'Invoke-PkProcessWithTimeout', 'Invoke-PkProcessDispatch', 'Invoke-PkProcessBatch',
    'Invoke-PkRunspaceJobs', 'Test-PkWorkerSafety')

} | Import-Module -Global
