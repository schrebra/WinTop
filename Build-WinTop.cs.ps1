param([string]$ProjectName='WinTop',[ValidateSet('Auto','Console','WPF')][string]$ProjectType='Console',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$Script:StageName='Initialization';$Script:InstallerPath='';$Script:DotnetDir=Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet';$Script:AppKind='Console'
function Write-Info([string]$m){Write-Host $m -ForegroundColor Cyan}
function Write-Ok([string]$m){Write-Host $m -ForegroundColor Green}
function Write-Warn2([string]$m){Write-Host $m -ForegroundColor Yellow}
function Write-Err2([string]$m){Write-Host $m -ForegroundColor Red}
function Throw-Code([int]$c,[string]$m){throw "[$c] $m"}
function Write-Stage([string]$n,[string]$m){Write-Host '';Write-Host "[$n] $m" -ForegroundColor Cyan}
function Initialize-Tls{try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}catch{};try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13}catch{}}
function Get-SafeName([string]$n){$n=[regex]::Replace($n,'[^A-Za-z0-9_]','');if($n.Length -eq 0){return 'GeneratedApp'};if($n -match '^\d'){$n='App'+$n};$n=$n.Substring(0,1).ToUpperInvariant()+$n.Substring(1);$kw=@('abstract','as','async','await','base','bool','break','byte','case','catch','char','checked','class','const','continue','decimal','default','delegate','do','double','else','enum','event','explicit','extern','false','finally','fixed','float','for','foreach','goto','if','implicit','in','init','int','interface','internal','is','lock','long','namespace','new','null','object','operator','out','override','params','private','protected','public','readonly','record','ref','return','sbyte','sealed','short','sizeof','stackalloc','static','string','struct','switch','this','throw','true','try','typeof','uint','ulong','unchecked','unsafe','ushort','using','var','virtual','void','volatile','while');if($kw -contains $n.ToLowerInvariant()){$n=$n+'App'};return $n}
function Remove-Folder([string]$Path){$p=$Path.TrimEnd('\');if(-not (Test-Path -LiteralPath $p)){return $true};for($i=1;$i -le 3;$i++){try{Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {try{$_.Attributes=[IO.FileAttributes]::Normal}catch{}};Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop}catch{Start-Sleep -Seconds ([math]::Min(30,5*$i))};if(-not (Test-Path -LiteralPath $p)){return $true}};try{& cmd.exe /c rd /s /q "$p" | Out-Null}catch{};$gone=-not (Test-Path -LiteralPath $p);if(-not $gone){Write-Warn2 "cmd rd /s /q exited with code $LASTEXITCODE but '$p' still exists."};return $gone}
function Find-DotNetSdk{$cand=@();$local=Join-Path $Script:DotnetDir 'dotnet.exe';if(Test-Path -LiteralPath $local){$cand+=$local};$resolved=Get-Command dotnet.exe -ErrorAction SilentlyContinue;if($resolved -and ($cand -notcontains $resolved.Source)){$cand+=$resolved.Source};foreach($d in $cand){$prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $d --version 2>$null);if($LASTEXITCODE -eq 0){$sdks=@(& $d --list-sdks 2>$null);if($LASTEXITCODE -eq 0 -and (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)){return $d}}}catch{}finally{$ErrorActionPreference=$prev}};return $null}
function Test-SdkWorks([string]$DotNetPath){if([string]::IsNullOrWhiteSpace($DotNetPath) -or -not (Test-Path -LiteralPath $DotNetPath)){return $false};$prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $DotNetPath --version 2>$null);if($LASTEXITCODE -ne 0){return $false};$sdks=@(& $DotNetPath --list-sdks 2>$null);if($LASTEXITCODE -ne 0){return $false};return (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)}catch{return $false}finally{$ErrorActionPreference=$prev}}
function Save-FileWithRetry([string]$Url,[string]$Dest){for($i=1;$i -le $MaxRetries;$i++){if(Test-Path -LiteralPath $Dest){Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue};try{if($env:HTTPS_PROXY){Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -Proxy $env:HTTPS_PROXY -ErrorAction Stop}else{Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop};if((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 1000)){$head=((Get-Content -LiteralPath $Dest -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ');if($head -notmatch '(?i)<\s*html|<!doctype'){return $true}}}catch{};Write-Warn2 "Download attempt $i failed for: $Url";if($i -lt $MaxRetries){Write-Warn2 "Retrying in $([math]::Min(30,5*$i)) seconds...";Start-Sleep -Seconds ([math]::Min(30,5*$i))}};return $false}
function Install-DotNetSdk{$Script:InstallerPath=Join-Path $env:TEMP 'dotnet-install.ps1';$urls=@('https://dot.net/v1/dotnet-install.ps1','https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.ps1');$got=$false;foreach($u in $urls){if(Save-FileWithRetry -Url $u -Dest $Script:InstallerPath){$got=$true;break}};if(-not $got){Throw-Code 2 "Could not download dotnet-install.ps1 from any known mirror after repeated retries."};try{Unblock-File -LiteralPath $Script:InstallerPath -ErrorAction SilentlyContinue}catch{};Write-Info "Installing the .NET 8 SDK user-local under: $($Script:DotnetDir)";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallerPath -Channel 8.0 -Architecture x64 -InstallDir $Script:DotnetDir;if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet-install.ps1 exited with code $LASTEXITCODE."}}
function Set-DotNetEnv([string]$Dir){if(-not (Test-Path -LiteralPath $Dir)){Throw-Code 3 "Expected dotnet directory '$Dir' does not exist after installation."};$env:DOTNET_ROOT=$Dir;$env:DOTNET_MULTILEVEL_LOOKUP='0';$env:DOTNET_NOLOGO='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';if(@($env:Path -split ';') -notcontains $Dir){$env:Path="$Dir;$env:Path"}}
function Invoke-DotNet{param([string]$ExePath,[int]$FailCode=5,[string[]]$CliArgs=@());& $ExePath @CliArgs;if($LASTEXITCODE -ne 0){Throw-Code $FailCode "dotnet $($CliArgs -join ' ') failed with exit code $LASTEXITCODE."}}
function Test-DiskSpace([string]$Path){$gb=$null;try{$di=New-Object IO.DriveInfo($Path.Substring(0,1));if($di.IsReady){$gb=[math]::Round($di.AvailableFreeSpace/1GB,2)}}catch{};if($null -eq $gb){Write-Warn2 'Could not determine free disk space; continuing.';return};$L=$Path.Substring(0,1);if($gb -lt 0.5){Throw-Code 1 "Only $gb GB free on drive ${L}: - at least 0.5 GB is required."}elseif($gb -lt 2){Write-Warn2 "Low disk space: $gb GB free on drive ${L}:"}else{Write-Ok "Disk space OK: $gb GB free on drive ${L}:"}}
function Write-SourceFiles([string]$Dir,[string]$Name,[string]$Kind){
$projCon=@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><SelfContained>true</SelfContained><RuntimeIdentifier>win-x64</RuntimeIdentifier><PublishSingleFile>true</PublishSingleFile><IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract><EnableCompressionInSingleFile>true</EnableCompressionInSingleFile><PublishReadyToRun>true</PublishReadyToRun><DebugType>embedded</DebugType><RootNamespace>__APPNAME__</RootNamespace><AssemblyName>__APPNAME__</AssemblyName><SatelliteResourceLanguages>en</SatelliteResourceLanguages></PropertyGroup></Project>
'@
$progCs=@'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace __APPNAME__
{
    internal sealed class ProcInfo
    {
        public int Pid;
        public string Name = "";
        public string Path = "";
        public double Cpu;
        public double Mem;
        public double ReadMBps;
        public double WriteMBps;
        public bool IsSystem;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    internal static class Program
    {
        static readonly object Sync = new object();
        static readonly Dictionary<int, TimeSpan> PrevCpu = new Dictionary<int, TimeSpan>();
        static readonly Dictionary<int, ulong> PrevRead = new Dictionary<int, ulong>();
        static readonly Dictionary<int, ulong> PrevWrite = new Dictionary<int, ulong>();
        static List<ProcInfo> AllProcs = new List<ProcInfo>();
        static List<ProcInfo> FullList = new List<ProcInfo>();
        static int Selected;
        static int ScrollOffset;
        static string Filter = "";
        static string SortBy = "CPU";
        static bool SortDesc = true;
        static bool Running = true;
        static bool Paused;
        static bool NeedRedraw = true;
        static bool ShowAllProcesses = true;
        static DateTime NextRefresh = DateTime.UtcNow;
        static double LastSysCpu;
        static double LastMemUsed;
        static double LastMemTot;
        static double LastMemPct;
        static List<(string Name, double UsedGb, double TotGb, double Pct)> FixedDrives = new List<(string, double, double, double)>();
        static int TotalProcesses;
        static readonly string[] SortColumns = new[] { "CPU", "MEM", "READ", "WRITE", "NAME", "PID" };
        static string HostName = Environment.MachineName;
        static string CurrentUser = Environment.UserDomainName + "\\" + Environment.UserName;
        static DateTime lastSample = DateTime.UtcNow;
        static readonly Queue<double> CpuSamples = new Queue<double>();
        static readonly HashSet<string> CriticalNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "System", "Idle", "Registry", "smss", "csrss", "wininit", "services", "lsass",
            "winlogon", "fontdrvhost", "dwm", "svchost", "Memory Compression", "Secure System"
        };
        static Thread? SamplerThread;
        static volatile bool SamplerStop;
        static int LastWinW = -1;
        static int LastWinH = -1;
        static int OrigBufferW;
        static int OrigBufferH;
        static bool BufferLocked;
        static uint OrigConsoleMode;
        static bool HaveOrigConsoleMode;
        static ConsoleColor OrigBg = ConsoleColor.Black;
        static ConsoleColor OrigFg = ConsoleColor.Gray;

        const int PROCESS_QUERY_INFORMATION = 0x0400;
        const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        const int BAR_WIDTH = 30;   // fixed width so every bar starts at the same column

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS counters);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool QueryFullProcessImageName(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

        const int STD_INPUT_HANDLE = -10;
        const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
        const uint ENABLE_EXTENDED_FLAGS = 0x0080;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        static int Main()
        {
            Console.CursorVisible = false;
            Console.Title = "WinTop";

            // Remember the original scrollback buffer so we can restore it on exit,
            // then lock the buffer to the window: no scrollbar, no scroll history,
            // and (0,0) is always the visible top-left corner.
            try { OrigBufferW = Console.BufferWidth; OrigBufferH = Console.BufferHeight; } catch { }
            FitBufferToWindow();
            DisableQuickEdit();

            // Remember the console's original colors so we can put them back on
            // exit, then switch to our own palette and paint the whole buffer
            // with it. (Without this, the host's default background - dark blue
            // in PowerShell - shows through anywhere the app does not paint.)
            try { OrigBg = Console.BackgroundColor; OrigFg = Console.ForegroundColor; }
            catch { OrigBg = ConsoleColor.Black; OrigFg = ConsoleColor.Gray; }
            SetDrawColors();
            try { Console.Clear(); } catch { }

            LoadSettings();

            SamplerStop = false;
            // FIX: sample once on this thread BEFORE the sampler thread starts.
            // PrevCpu/PrevRead/PrevWrite are plain Dictionaries, so having the
            // main thread and the sampler thread touch them at the same time
            // can throw (or silently corrupt the readings).
            SampleProcesses();
            SamplerThread = new Thread(SamplerLoop) { IsBackground = true, Name = "wintop-sampler" };
            SamplerThread.Start();

            ApplyFilterAndSort();
            Draw();
            NeedRedraw = false;

            int code = 0;
            try
            {
                while (Running)
                {
                    int ww = Console.WindowWidth;
                    int wh = Console.WindowHeight;
                    if (ww != LastWinW || wh != LastWinH)
                    {
                        LastWinW = ww;
                        LastWinH = wh;
                        FitBufferToWindow();
                        // Wipe on resize: narrowing can leave wrapped/truncated
                        // remnants past the new width that a repaint would not cover.
                        try { Console.Clear(); } catch { }
                        NeedRedraw = true;
                    }

                    while (Console.KeyAvailable) HandleKey();

                    if (!Paused && DateTime.UtcNow >= NextRefresh)
                    {
                        ApplyFilterAndSort();
                        NextRefresh = DateTime.UtcNow.AddSeconds(5);
                        NeedRedraw = true;
                    }

                    if (NeedRedraw)
                    {
                        Draw();
                        NeedRedraw = false;
                    }

                    Thread.Sleep(15);
                }
            }
            catch (Exception ex)
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("Fatal: " + ex.Message);
                SetDrawColors();
                code = 1;
            }
            finally
            {
                Console.CursorVisible = true;
                SamplerStop = true;
                try { SamplerThread?.Join(1500); } catch { }
                // Persist preferences, then restore the console to how we found
                // it: original colors, original buffer size, clean screen.
                SaveSettings();
                RestoreConsoleMode();
                try
                {
                    Console.BackgroundColor = OrigBg;
                    Console.ForegroundColor = OrigFg;
                }
                catch { }
                try
                {
                    if (BufferLocked)
                        Console.SetBufferSize(OrigBufferW, OrigBufferH);
                }
                catch { }
                try { Console.Clear(); } catch { }
            }

            Console.WriteLine();
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("WinTop ended. Press any key to close...");
            try { Console.BackgroundColor = OrigBg; Console.ForegroundColor = OrigFg; } catch { }
            if (Console.IsInputRedirected) Console.ReadLine();
            else Console.ReadKey(true);
            return code;
        }

        static void SamplerLoop()
        {
            while (!SamplerStop)
            {
                try { SampleProcesses(); } catch { }
                for (int i = 0; i < 125 && !SamplerStop; i++) Thread.Sleep(40); // ~5s between samples
            }
        }

        static void FitBufferToWindow()
        {
            // Lock the scrollback buffer to the visible window size so the console
            // can never scroll: no scrollbar, no history to scroll through, and
            // (0,0) is always the visible top-left corner. Safe to call repeatedly;
            // it only resizes when something actually changed.
            try
            {
                int w = Console.WindowWidth;
                int h = Console.WindowHeight;
                if (w > 0 && h > 0 && (Console.BufferWidth != w || Console.BufferHeight != h))
                {
                    Console.SetBufferSize(w, h);
                    BufferLocked = true;
                }
            }
            catch { /* redirected/no console or terminal quirk: just draw anyway */ }
        }

        static void DisableQuickEdit()
        {
            // Turn off QuickEdit mark/select mode: clicking the console no longer
            // drops the app into "Select WinTop" (freezing the display) or paints
            // little selection-highlight squares on the screen.
            try
            {
                IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
                if (h == IntPtr.Zero || h == new IntPtr(-1)) return;
                if (GetConsoleMode(h, out uint mode))
                {
                    if (!HaveOrigConsoleMode) { OrigConsoleMode = mode; HaveOrigConsoleMode = true; }
                    SetConsoleMode(h, (mode & ~ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS);
                }
            }
            catch { }
        }

        static void RestoreConsoleMode()
        {
            try
            {
                if (!HaveOrigConsoleMode) return;
                IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
                if (h == IntPtr.Zero || h == new IntPtr(-1)) return;
                SetConsoleMode(h, OrigConsoleMode);
            }
            catch { }
        }

        static void SetDrawColors()
        {
            // Our palette for the whole app: black background, gray text.
            // Used everywhere instead of Console.ResetColor(), which would
            // restore the HOST's default colors (dark blue background in
            // PowerShell) and make the app look wrong there.
            try
            {
                Console.BackgroundColor = ConsoleColor.Black;
                Console.ForegroundColor = ConsoleColor.Gray;
            }
            catch { }
        }

        static string SettingsPath => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "WinTop", "settings.cfg");

        static void LoadSettings()
        {
            // Restore the user's preferences (view mode, sort column/direction).
            // A missing or corrupt file just means defaults - never a crash.
            try
            {
                string path = SettingsPath;
                if (!File.Exists(path)) return;
                foreach (var raw in File.ReadAllLines(path))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string key = line.Substring(0, eq).Trim();
                    string val = line.Substring(eq + 1).Trim();
                    if (key.Equals("ShowAllProcesses", StringComparison.OrdinalIgnoreCase))
                        ShowAllProcesses = val.Equals("true", StringComparison.OrdinalIgnoreCase);
                    else if (key.Equals("SortBy", StringComparison.OrdinalIgnoreCase))
                    {
                        string upper = val.ToUpperInvariant();
                        if (SortColumns.Contains(upper)) SortBy = upper;
                    }
                    else if (key.Equals("SortDesc", StringComparison.OrdinalIgnoreCase))
                        SortDesc = val.Equals("true", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch { }
        }

        static void SaveSettings()
        {
            // Written on every preference change, so it survives even a kill.
            try
            {
                string path = SettingsPath;
                string? dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                File.WriteAllLines(path, new[]
                {
                    "# WinTop settings - safe to edit by hand",
                    $"ShowAllProcesses={ShowAllProcesses.ToString().ToLowerInvariant()}",
                    $"SortBy={SortBy}",
                    $"SortDesc={SortDesc.ToString().ToLowerInvariant()}",
                });
            }
            catch { }
        }

        static string FormatUptime()
        {
            var ts = TimeSpan.FromMilliseconds(Environment.TickCount64);
            if (ts.TotalDays >= 1) return $"{(int)ts.TotalDays}d {ts.Hours}h {ts.Minutes}m";
            if (ts.TotalHours >= 1) return $"{ts.Hours}h {ts.Minutes}m {ts.Seconds}s";
            return $"{ts.Minutes}m {ts.Seconds}s";
        }

        static bool IsProtected(ProcInfo p)
        {
            if (p.Pid <= 8 || p.Pid == Environment.ProcessId) return true;
            if (CriticalNames.Contains(p.Name)) return true;
            if (!string.IsNullOrEmpty(p.Path) &&
                (p.Path.IndexOf("\\Windows\\System32\\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 p.Path.IndexOf("\\Windows\\SysWOW64\\", StringComparison.OrdinalIgnoreCase) >= 0) &&
                CriticalNames.Contains(Path.GetFileNameWithoutExtension(p.Path)))
                return true;
            return false;
        }

        static bool ComputeIsSystem(int pid, string name, string path, int sessionId)
        {
            if (pid <= 8) return true;
            // Session 0 is the services session: nothing interactive runs there,
            // so everything in it is a service or a system component.
            if (sessionId == 0) return true;
            // Well-known Windows core processes, matched by name too: this keeps
            // them classified as system even when the image path cannot be read
            // (protected processes, or a token that cannot open the process).
            if (CriticalNames.Contains(name)) return true;
            if (!string.IsNullOrEmpty(path) && !path.Equals("-"))
            {
                string lower = path.ToLowerInvariant();
                if (lower.Contains("\\windows\\system32\\") ||
                    lower.Contains("\\windows\\syswow64\\") ||
                    lower.Contains("\\windows\\winsxs\\") ||
                    lower.Contains("\\windows\\servicing\\") ||
                    lower.Contains("\\windows\\systemapps\\"))
                    return true;
            }
            return false;
        }

        static bool MatchesFilter(string name, string pidStr, string path, string filter)
        {
            if (string.IsNullOrEmpty(filter)) return true;
            if (filter.IndexOf('*') >= 0)
            {
                string pattern = "^" + Regex.Escape(filter).Replace("\\*", ".*") + "$";
                try
                {
                    return Regex.IsMatch(name, pattern, RegexOptions.IgnoreCase) ||
                           Regex.IsMatch(pidStr, pattern, RegexOptions.IgnoreCase) ||
                           Regex.IsMatch(path, pattern, RegexOptions.IgnoreCase);
                }
                catch { return false; }
            }
            return name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0 ||
                   pidStr.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0 ||
                   path.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        static string MakeBar(double pct)
        {
            int f = Math.Max(0, Math.Min(BAR_WIDTH, (int)Math.Round(pct / 100.0 * BAR_WIDTH)));
            return new string('|', f) + new string(' ', BAR_WIDTH - f);
        }

        static string FormatDiskPair(double usedGb, double totGb)
        {
            // Sub-GB volumes (small VHDs, USB sticks): show MB so the numbers stay
            // meaningful - "0.0 / 0.1 GB" next to "12.0%" looks broken,
            // "11.8 / 98.0 MB" does not.
            if (totGb < 1.0)
                return $"{usedGb * 1024.0:0.0} / {totGb * 1024.0:0.0} MB";
            return $"{usedGb:0.0} / {totGb:0.0} GB";
        }

        static void SampleProcesses()
        {
            var now = DateTime.UtcNow;
            double elapsed = Math.Max(0.5, (now - lastSample).TotalSeconds);

            double memUsedMb = 0, memTotMb = 0, memPct = 0;
            try
            {
                var ms = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
                if (GlobalMemoryStatusEx(ref ms))
                {
                    memTotMb = Math.Round(ms.ullTotalPhys / 1048576.0, 0);
                    memUsedMb = Math.Round((ms.ullTotalPhys - ms.ullAvailPhys) / 1048576.0, 0);
                    memPct = ms.dwMemoryLoad;
                }
            }
            catch { }

            var drives = new List<(string Name, double UsedGb, double TotGb, double Pct)>();
            try
            {
                foreach (var d in DriveInfo.GetDrives())
                {
                    if (!d.IsReady || d.DriveType != DriveType.Fixed) continue;
                    double tot = d.TotalSize / 1073741824.0;
                    double free = d.AvailableFreeSpace / 1073741824.0;
                    double used = tot - free;
                    double pct = tot > 0 ? used / tot * 100.0 : 0;
                    drives.Add((d.Name.TrimEnd('\\'), used, tot, pct));
                }
            }
            catch { }

            Process[] all;
            try { all = Process.GetProcesses(); }
            catch { return; }

            int total = all.Length;
            var list = new List<ProcInfo>(all.Length);
            double sumCpu = 0;
            int cores = Math.Max(1, Environment.ProcessorCount);
            var liveIds = new HashSet<int>(all.Length);

            foreach (var p in all)
            {
                try
                {
                    liveIds.Add(p.Id);

                    // Session 0 = the services session. Grab it per-process so
                    // ComputeIsSystem can tell services apart from user apps.
                    // (ProcessIdToSessionId needs no handle, so this works for
                    // every process, including protected ones.)
                    int sessId = -1;
                    try { sessId = p.SessionId; } catch { }

                    string pname = "";
                    try { pname = p.ProcessName ?? ""; } catch { pname = "?"; }

                    double cpu = 0;
                    TimeSpan tpt = TimeSpan.Zero;
                    bool hasCpu = false;
                    try { tpt = p.TotalProcessorTime; hasCpu = true; } catch { }

                    if (hasCpu)
                    {
                        if (PrevCpu.TryGetValue(p.Id, out var prev))
                        {
                            var delta = (tpt - prev).TotalSeconds;
                            cpu = Math.Max(0, Math.Round(delta / elapsed / cores * 100.0, 1));
                        }
                        PrevCpu[p.Id] = tpt;
                        sumCpu += cpu;
                    }

                    double memMb = 0;
                    try { memMb = Math.Round(p.WorkingSet64 / 1048576.0, 1); } catch { }

                    double readMBps = 0, writeMBps = 0;
                    string fullPath = "-";

                    // FIX: request QUERY_LIMITED_INFORMATION only. Asking for the
                    // full QUERY_INFORMATION right at the same time is all-or-nothing:
                    // SYSTEM-owned and protected processes deny the full right to a
                    // non-elevated token, so the whole open failed, the image path
                    // stayed "-", and the system/user classification missed them.
                    // Limited rights are enough for the path and the IO counters.
                    IntPtr hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, p.Id);
                    if (hProc != IntPtr.Zero)
                    {
                        try
                        {
                            var sb = new StringBuilder(1024);
                            int size = sb.Capacity;
                            if (QueryFullProcessImageName(hProc, 0, sb, ref size) && size > 0)
                                fullPath = sb.ToString(0, size);

                            if (GetProcessIoCounters(hProc, out IO_COUNTERS io))
                            {
                                // FIX: guard against PID reuse. A recycled PID can have
                                // smaller counters than the stale dictionary entry, which
                                // would underflow the ulong subtraction and display an
                                // astronomical MB/s for one sample.
                                if (PrevRead.TryGetValue(p.Id, out var prevR) && io.ReadTransferCount >= prevR)
                                    readMBps = Math.Max(0, Math.Round((io.ReadTransferCount - prevR) / elapsed / 1048576.0, 2));
                                if (PrevWrite.TryGetValue(p.Id, out var prevW) && io.WriteTransferCount >= prevW)
                                    writeMBps = Math.Max(0, Math.Round((io.WriteTransferCount - prevW) / elapsed / 1048576.0, 2));
                                PrevRead[p.Id] = io.ReadTransferCount;
                                PrevWrite[p.Id] = io.WriteTransferCount;
                            }
                        }
                        finally { CloseHandle(hProc); }
                    }

                    bool isSys = ComputeIsSystem(p.Id, pname, fullPath, sessId);

                    list.Add(new ProcInfo
                    {
                        Pid = p.Id,
                        Name = pname,
                        Path = fullPath,
                        Cpu = cpu,
                        Mem = memMb,
                        ReadMBps = readMBps,
                        WriteMBps = writeMBps,
                        IsSystem = isSys
                    });
                }
                catch { }
                // FIX: Process.GetProcesses() hands out Process objects that own
                // native handles. Without Dispose() every sample leaks hundreds
                // of handles until the process runs out.
                finally { try { p.Dispose(); } catch { } }
            }

            if (PrevCpu.Count > liveIds.Count + 32)
            {
                var toRemove = new List<int>();
                foreach (var key in PrevCpu.Keys)
                    if (!liveIds.Contains(key)) toRemove.Add(key);
                foreach (var key in toRemove)
                {
                    PrevCpu.Remove(key);
                    PrevRead.Remove(key);
                    PrevWrite.Remove(key);
                }
            }

            double rawCpu = Math.Min(100.0, Math.Round(sumCpu, 1));
            lock (Sync)
            {
                CpuSamples.Enqueue(rawCpu);
                while (CpuSamples.Count > 3) CpuSamples.Dequeue();
                LastSysCpu = Math.Round(CpuSamples.Average(), 1);
                LastMemUsed = memUsedMb;
                LastMemTot = memTotMb;
                LastMemPct = memPct;
                FixedDrives = drives;
                TotalProcesses = total;
                AllProcs = list;
                lastSample = now;
            }
        }
        static void ApplyFilterAndSort()
        {
            List<ProcInfo> src;
            lock (Sync) { src = AllProcs; }

            List<ProcInfo> list = new List<ProcInfo>(src.Count);
            string f = Filter;

            foreach (var x in src)
            {
                if (!ShowAllProcesses && x.IsSystem) continue;
                if (!string.IsNullOrEmpty(f) && !MatchesFilter(x.Name, x.Pid.ToString(), x.Path, f)) continue;
                list.Add(x);
            }

            list.Sort((a, b) =>
            {
                int cmp = SortBy switch
                {
                    "MEM" => a.Mem.CompareTo(b.Mem),
                    "PID" => a.Pid.CompareTo(b.Pid),
                    "NAME" => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase),
                    "READ" => a.ReadMBps.CompareTo(b.ReadMBps),
                    "WRITE" => a.WriteMBps.CompareTo(b.WriteMBps),
                    _ => a.Cpu.CompareTo(b.Cpu)
                };
                return SortDesc ? -cmp : cmp;
            });

            FullList = list;

            int headerLines = 8 + Math.Max(1, FixedDrives.Count);
            int maxRows = Math.Max(3, Console.WindowHeight - headerLines - 2);
            if (ScrollOffset > Math.Max(0, FullList.Count - maxRows))
                ScrollOffset = Math.Max(0, FullList.Count - maxRows);
            if (Selected >= FullList.Count) Selected = Math.Max(0, FullList.Count - 1);
            if (Selected < ScrollOffset) ScrollOffset = Selected;
            if (Selected >= ScrollOffset + maxRows) ScrollOffset = Selected - maxRows + 1;
        }

        static void WriteHeaderCell(string text, string sortKey, int width)
        {
            bool active = string.Equals(SortBy, sortKey, StringComparison.OrdinalIgnoreCase);
            if (active)
            {
                Console.BackgroundColor = ConsoleColor.Yellow;
                Console.ForegroundColor = ConsoleColor.Black;
            }
            else
            {
                Console.BackgroundColor = ConsoleColor.DarkGray;
                Console.ForegroundColor = ConsoleColor.Black;
            }
            Console.Write(text.PadRight(width).Substring(0, width));
        }

        static void Draw()
        {
            // The whole frame is wrapped: a resize landing mid-draw can throw
            // (cursor/window races). Swallow it; the next frame redraws in ~15ms.
            try
            {
            int rawW = Console.WindowWidth;
            int rawH = Console.WindowHeight;

            // Too small to draw the dashboard: say so instead of garbling it.
            if (rawW < 70 || rawH < 14)
            {
                try
                {
                    Console.SetCursorPosition(0, 0);
                    Console.BackgroundColor = ConsoleColor.Black;
                    Console.ForegroundColor = ConsoleColor.Yellow;
                    Console.WriteLine("Window too small - make it larger to use WinTop.");
                    Console.WriteLine($"Need at least 70x14, have {rawW}x{rawH}.");
                    SetDrawColors();
                }
                catch { }
                return;
            }

            int winW = Math.Max(70, rawW - 1);
            int winH = Math.Max(14, rawH);

            try { Console.SetCursorPosition(0, 0); } catch { try { Console.Clear(); } catch { } }

            string mode = ShowAllProcesses ? "ALL" : "USER";
            string uptime = FormatUptime();

            // Title
            Console.BackgroundColor = ConsoleColor.DarkBlue;
            Console.ForegroundColor = ConsoleColor.White;
            string title = $"  WinTop  {DateTime.Now:HH:mm:ss}{(Paused ? "  [PAUSED]" : "")}  [{mode}]";
            Console.Write(title.PadRight(winW).Substring(0, winW));
            SetDrawColors();
            Console.WriteLine();

            // Host line
            Console.BackgroundColor = ConsoleColor.Black;
            string hostLine = $"  Host {HostName}   User {CurrentUser}   Uptime {uptime}";
            Console.ForegroundColor = ConsoleColor.Cyan;
            Console.Write(hostLine.PadRight(winW).Substring(0, winW));
            Console.WriteLine();
            Console.WriteLine(new string(' ', winW));

            // ============================================================
            // CPU / MEM / Disks - bars start at the exact same column
            // Format:  LABEL  [BAR]  xx.x%  extra
            // ============================================================

            // CPU
            string cpuBar = MakeBar(LastSysCpu);
            Console.ForegroundColor = ConsoleColor.Green;
            Console.Write("  CPU  ");
            Console.ForegroundColor = LastSysCpu >= 80 ? ConsoleColor.Red : LastSysCpu >= 50 ? ConsoleColor.Yellow : ConsoleColor.Green;
            Console.Write($"[{cpuBar}]");
            Console.ForegroundColor = ConsoleColor.Green;
            Console.Write($" {LastSysCpu,5:0.0}%  {Environment.ProcessorCount} CPU  procs {TotalProcesses}");
            Console.WriteLine(new string(' ', Math.Max(0, winW - Console.CursorLeft)));

            // MEM
            string memBar = MakeBar(LastMemPct);
            Console.ForegroundColor = ConsoleColor.Cyan;
            Console.Write("  Mem  ");
            Console.ForegroundColor = LastMemPct >= 80 ? ConsoleColor.Red : LastMemPct >= 50 ? ConsoleColor.Yellow : ConsoleColor.Cyan;
            Console.Write($"[{memBar}]");
            Console.ForegroundColor = ConsoleColor.Cyan;
            Console.Write($" {LastMemPct,5:0.0}%  {LastMemUsed / 1024.0:0.0} / {LastMemTot / 1024.0:0.0} GB");
            Console.WriteLine(new string(' ', Math.Max(0, winW - Console.CursorLeft)));

            // Disks header
            Console.ForegroundColor = ConsoleColor.Magenta;
            Console.WriteLine("  Disks");

            if (FixedDrives.Count == 0)
            {
                Console.WriteLine("  (scanning...)".PadRight(winW).Substring(0, winW));
            }
            else
            {
                foreach (var d in FixedDrives)
                {
                    string bar = MakeBar(d.Pct);
                    Console.ForegroundColor = d.Pct >= 90 ? ConsoleColor.Red : d.Pct >= 75 ? ConsoleColor.Yellow : ConsoleColor.Magenta;
                    // FIX: label field is "  " + name padded to 3 + "  " = 7 chars,
                    // exactly like "  CPU  " / "  Mem  ", so every '[' starts at
                    // the same column with no indentation on the disk bars.
                    Console.Write($"  {d.Name,-3}  ");
                    Console.Write($"[{bar}]");
                    Console.Write($" {d.Pct,5:0.0}%  {FormatDiskPair(d.UsedGb, d.TotGb)}");
                    Console.WriteLine(new string(' ', Math.Max(0, winW - Console.CursorLeft)));
                }
            }

            SetDrawColors();
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.WriteLine(new string('-', winW));
            SetDrawColors();

            // Column headers
            Console.Write("  ");
            WriteHeaderCell("PID", "PID", 6); Console.Write(" ");
            WriteHeaderCell("CPU%", "CPU", 6); Console.Write(" ");
            WriteHeaderCell("MEM(MB)", "MEM", 8); Console.Write(" ");
            WriteHeaderCell("R-MB/s", "READ", 7); Console.Write(" ");
            WriteHeaderCell("W-MB/s", "WRITE", 7); Console.Write(" ");
            WriteHeaderCell("Name", "NAME", 18); Console.Write(" ");
            int pathWidth = Math.Max(8, winW - 62);
            WriteHeaderCell("Path", "NAME", pathWidth);
            SetDrawColors();
            Console.WriteLine();

            int headerLines = 8 + Math.Max(1, FixedDrives.Count);
            int maxRows = Math.Max(3, winH - headerLines - 2);
            int pathMax = Math.Max(8, winW - 62);

            var visible = FullList.Skip(ScrollOffset).Take(maxRows).ToList();
            for (int i = 0; i < visible.Count; i++)
            {
                var pr = visible[i];
                int realIdx = ScrollOffset + i;
                string nameShow = pr.Name.Length > 18 ? pr.Name.Substring(0, 15) + "..." : pr.Name;
                string pathShow = pr.Path.Length > pathMax ? "..." + pr.Path.Substring(pr.Path.Length - pathMax + 3) : pr.Path;

                string line = $"  {pr.Pid,6} {pr.Cpu,6:0.0} {pr.Mem,8:0.0} {pr.ReadMBps,7:0.00} {pr.WriteMBps,7:0.00} {nameShow,-18} {pathShow}";
                line = line.PadRight(winW).Substring(0, winW);

                if (realIdx == Selected)
                {
                    Console.BackgroundColor = ConsoleColor.Cyan;
                    Console.ForegroundColor = ConsoleColor.Black;
                }
                else if (pr.IsSystem)
                {
                    Console.BackgroundColor = ConsoleColor.Black;
                    Console.ForegroundColor = ConsoleColor.DarkGray;
                }
                else
                {
                    Console.BackgroundColor = ConsoleColor.Black;
                    Console.ForegroundColor = pr.Cpu >= 40 ? ConsoleColor.Red : pr.Cpu >= 10 ? ConsoleColor.Yellow : ConsoleColor.Gray;
                }
                Console.WriteLine(line);
                SetDrawColors();
            }

            bool atEnd = ScrollOffset + visible.Count >= FullList.Count;
            if (atEnd && FullList.Count > 0)
            {
                Console.ForegroundColor = ConsoleColor.DarkGray;
                Console.WriteLine(("  -- end of processes --").PadRight(winW).Substring(0, winW));
                SetDrawColors();
            }

            // Fill remaining lines - this completely prevents the terminal from scrolling.
            // Pure arithmetic (no CursorTop): immune to any wrapped-line weirdness.
            int linesWritten = headerLines + visible.Count + ((atEnd && FullList.Count > 0) ? 1 : 0);
            int left = winH - 1 - linesWritten;
            if (left < 0) left = 0;
            Console.BackgroundColor = ConsoleColor.Black;
            Console.ForegroundColor = ConsoleColor.Black;
            for (int j = 0; j < left; j++) Console.WriteLine(new string(' ', winW));
            SetDrawColors();

            // Scroll position indicator: thin scrollbar on the right edge of the
            // process-list area. Dark track, bright thumb shows where you are.
            try
            {
                int listTop = headerLines;
                int listH = maxRows;
                int count = FullList.Count;
                int thumbH = count <= listH ? listH : Math.Max(1, (int)Math.Round((double)listH * listH / count));
                int maxStart = Math.Max(0, listH - thumbH);
                int thumbStart = 0;
                if (count > listH)
                    thumbStart = (int)Math.Round((double)ScrollOffset / (count - listH) * maxStart);
                thumbStart = Math.Max(0, Math.Min(maxStart, thumbStart));
                for (int r = 0; r < listH; r++)
                {
                    int row = listTop + r;
                    if (row >= winH - 1) break;
                    Console.SetCursorPosition(winW - 1, row);
                    bool isThumb = r >= thumbStart && r < thumbStart + thumbH;
                    Console.ForegroundColor = isThumb ? ConsoleColor.Gray : ConsoleColor.DarkGray;
                    Console.BackgroundColor = ConsoleColor.Black;
                    Console.Write(isThumb ? '\u2588' : '\u2502');
                }
                SetDrawColors();
            }
            catch { }

            // Status bar (always on the last line): prioritized tokens, condensed.
            // Only what fits the width is shown - an item is either fully shown
            // or dropped, never cut in half. State first, then hotkeys most-used-first.
            // (RUN/[ALL] live in the title bar already, so they are not repeated here.)
            try
            {
                var pieces = new List<(string text, ConsoleColor fg)>();
                if (!string.IsNullOrEmpty(Filter))
                {
                    string fshow = Filter.Length > 12 ? Filter.Substring(0, 12) + ".." : Filter;
                    pieces.Add(($"find:'{fshow}'", ConsoleColor.Yellow));
                }
                pieces.Add(("q=quit", ConsoleColor.Black));
                pieces.Add(("space=pause", ConsoleColor.Black));
                pieces.Add(("/=find", ConsoleColor.Black));
                pieces.Add(("<->=sort", ConsoleColor.Black));
                pieces.Add(("k=kill", ConsoleColor.Black));
                pieces.Add(("P=all/user", ConsoleColor.Black));
                pieces.Add(("r=reverse", ConsoleColor.Black));
                pieces.Add(("c=clear", ConsoleColor.Black));
                pieces.Add(("h=help", ConsoleColor.Black));

                Console.SetCursorPosition(0, winH - 1);
                Console.BackgroundColor = ConsoleColor.DarkCyan;
                int col = 0;
                foreach (var (text, fg) in pieces)
                {
                    string add = col == 0 ? text : "  " + text;
                    if (col + add.Length > winW) break;
                    Console.ForegroundColor = fg;
                    Console.Write(add);
                    col += add.Length;
                }
                Console.ForegroundColor = ConsoleColor.Black;
                if (col < winW) Console.Write(new string(' ', winW - col));
                SetDrawColors();
            }
            catch { }
            }
            catch { try { SetDrawColors(); } catch { } }
        }

        static void CycleSort(int direction)
        {
            int idx = Array.IndexOf(SortColumns, SortBy);
            if (idx < 0) idx = 0;
            idx = (idx + direction + SortColumns.Length) % SortColumns.Length;
            SortBy = SortColumns[idx];

            // Each column gets its natural direction on landing: names A-Z,
            // everything else highest-value-first. (Previously the A-Z from
            // NAME stuck for every column cycled to after it.)
            SortDesc = !string.Equals(SortBy, "NAME", StringComparison.OrdinalIgnoreCase);

            ApplyFilterAndSort();
            SaveSettings();
            NeedRedraw = true;
        }

        static void HandleKey()
        {
            var key = Console.ReadKey(true);
            if ((key.Modifiers & ConsoleModifiers.Control) != 0 &&
                (key.Key == ConsoleKey.R || key.KeyChar == 'r' || key.KeyChar == 'R'))
            {
                DoRun();
                return;
            }

            int headerLines = 8 + Math.Max(1, FixedDrives.Count);
            int maxRows = Math.Max(3, Console.WindowHeight - headerLines - 2);

            switch (key.Key)
            {
                case ConsoleKey.Q:
                case ConsoleKey.F10:
                    Running = false;
                    break;
                case ConsoleKey.Escape:
                    if (!string.IsNullOrEmpty(Filter))
                    {
                        Filter = "";
                        Selected = 0;
                        ScrollOffset = 0;
                        ApplyFilterAndSort();
                        NeedRedraw = true;
                    }
                    break;
                case ConsoleKey.Spacebar:
                    Paused = !Paused;
                    NeedRedraw = true;
                    if (!Paused) NextRefresh = DateTime.UtcNow;
                    break;
                case ConsoleKey.UpArrow:
                    if (Selected > 0)
                    {
                        Selected--;
                        if (Selected < ScrollOffset) ScrollOffset = Selected;
                        NeedRedraw = true;
                    }
                    break;
                case ConsoleKey.DownArrow:
                    if (Selected < FullList.Count - 1)
                    {
                        Selected++;
                        if (Selected >= ScrollOffset + maxRows) ScrollOffset = Selected - maxRows + 1;
                        NeedRedraw = true;
                    }
                    break;
                case ConsoleKey.PageUp:
                    Selected = Math.Max(0, Selected - maxRows);
                    if (Selected < ScrollOffset) ScrollOffset = Selected;
                    NeedRedraw = true;
                    break;
                case ConsoleKey.PageDown:
                    // FIX: clamp at 0 too - with an empty list this used to set Selected = -1.
                    Selected = Math.Max(0, Math.Min(FullList.Count - 1, Selected + maxRows));
                    if (Selected >= ScrollOffset + maxRows) ScrollOffset = Selected - maxRows + 1;
                    NeedRedraw = true;
                    break;
                case ConsoleKey.Home:
                    Selected = 0;
                    ScrollOffset = 0;
                    NeedRedraw = true;
                    break;
                case ConsoleKey.End:
                    Selected = Math.Max(0, FullList.Count - 1);
                    ScrollOffset = Math.Max(0, FullList.Count - maxRows);
                    NeedRedraw = true;
                    break;
                case ConsoleKey.LeftArrow:
                    CycleSort(-1);
                    break;
                case ConsoleKey.RightArrow:
                    CycleSort(1);
                    break;
                case ConsoleKey.K:
                case ConsoleKey.F9:
                    DoKillConfirm();
                    break;
                case ConsoleKey.Oem2:
                case ConsoleKey.F3:
                    DoSearch();
                    break;
                case ConsoleKey.S:
                case ConsoleKey.F6:
                    CycleSort(1);
                    break;
                case ConsoleKey.R:
                    SortDesc = !SortDesc;
                    ApplyFilterAndSort();
                    SaveSettings();
                    NeedRedraw = true;
                    break;
                case ConsoleKey.C:
                    Filter = "";
                    Selected = 0;
                    ScrollOffset = 0;
                    ApplyFilterAndSort();
                    NeedRedraw = true;
                    break;
                case ConsoleKey.P:
                    ShowAllProcesses = !ShowAllProcesses;
                    Selected = 0;
                    ScrollOffset = 0;
                    ApplyFilterAndSort();
                    SaveSettings();
                    NeedRedraw = true;
                    break;
                case ConsoleKey.H:
                case ConsoleKey.F1:
                    Console.Clear();
                    Console.WriteLine("WinTop keys");
                    Console.WriteLine("  Up/Down        move selection");
                    Console.WriteLine("  PageUp/PageDn  jump one page");
                    Console.WriteLine("  Home/End       jump to first/last");
                    Console.WriteLine("  Left/Right     change sort column");
                    Console.WriteLine("                 (Name always starts A?Z)");
                    Console.WriteLine("  r              reverse current sort");
                    Console.WriteLine("  s              next sort column");
                    Console.WriteLine("  Space          pause/resume");
                    Console.WriteLine("  / or F3        live search (* ok)");
                    Console.WriteLine("  P              toggle All/User processes");
                    Console.WriteLine("  k / F9         kill selected");
                    Console.WriteLine("  c / Esc        clear filter");
                    Console.WriteLine("  q / F10        quit");
                    Console.WriteLine();
                    Console.WriteLine("Press any key...");
                    Console.ReadKey(true);
                    Console.Clear();
                    NeedRedraw = true;
                    break;
            }
        }

        static string ReadConfirm(string prompt, int winW)
        {
            var sb = new StringBuilder();
            Console.CursorVisible = true;
            while (true)
            {
                string full = prompt + sb.ToString() + "_";
                if (full.Length > winW) full = full.Substring(0, winW);
                full = full.PadRight(winW);
                try
                {
                    Console.SetCursorPosition(0, Console.WindowHeight - 1);
                    Console.BackgroundColor = ConsoleColor.DarkRed;
                    Console.ForegroundColor = ConsoleColor.White;
                    Console.Write(full);
                    SetDrawColors();
                }
                catch { }
                var k = Console.ReadKey(true);
                if (k.Key == ConsoleKey.Enter) { Console.CursorVisible = false; return sb.ToString().Trim(); }
                if (k.Key == ConsoleKey.Escape) { Console.CursorVisible = false; return ""; }
                if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) sb.Length--; }
                else if (!char.IsControl(k.KeyChar)) sb.Append(k.KeyChar);
            }
        }

        static void KillAsync(IEnumerable<int> pids)
        {
            var ids = pids.ToArray();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                foreach (var id in ids)
                {
                    if (id == Environment.ProcessId) continue;
                    // FIX: dispose the Process - GetProcessById also owns a native handle.
                    try { using (var proc = Process.GetProcessById(id)) proc.Kill(); } catch { }
                }
            });
        }

        static void DoKillConfirm()
        {
            if (FullList.Count == 0 || Selected < 0 || Selected >= FullList.Count) return;
            var pr = FullList[Selected];
            int winW = Math.Max(70, Console.WindowWidth - 1);
            bool multi = !string.IsNullOrEmpty(Filter) && FullList.Count > 1;
            bool anyProtected = multi ? FullList.Any(IsProtected) : IsProtected(pr);

            string msg = multi
                ? $"Kill (s)elected {pr.Pid} or (a)ll {FullList.Count}? s/a/n: "
                : $"Kill PID {pr.Pid} ({pr.Name})? y/n: ";
            msg = msg.PadRight(winW).Substring(0, winW);

            try
            {
                Console.SetCursorPosition(0, Console.WindowHeight - 1);
                Console.BackgroundColor = ConsoleColor.DarkRed;
                Console.ForegroundColor = ConsoleColor.White;
                Console.Write(msg);
                SetDrawColors();
            }
            catch { }

            Console.CursorVisible = true;
            var k = Console.ReadKey(true);
            Console.CursorVisible = false;

            bool doSingle = false;
            bool doAll = false;
            if (multi)
            {
                if (k.Key == ConsoleKey.S || k.KeyChar == 's' || k.KeyChar == 'S') doSingle = true;
                else if (k.Key == ConsoleKey.A || k.KeyChar == 'a' || k.KeyChar == 'A') doAll = true;
                else { NeedRedraw = true; return; }
            }
            else
            {
                if (k.Key == ConsoleKey.Y || k.KeyChar == 'y' || k.KeyChar == 'Y') doSingle = true;
                else { NeedRedraw = true; return; }
            }

            if (doSingle)
            {
                if (pr.Pid == Environment.ProcessId) { NeedRedraw = true; return; }
                if (IsProtected(pr))
                {
                    string conf = ReadConfirm($"CRITICAL system process! Type KILL to confirm PID {pr.Pid}: ", winW);
                    if (!string.Equals(conf, "KILL", StringComparison.OrdinalIgnoreCase)) { NeedRedraw = true; return; }
                }
                KillAsync(new[] { pr.Pid });
                NextRefresh = DateTime.UtcNow;
            }
            else if (doAll)
            {
                if (FullList.Count > 50 || anyProtected || string.IsNullOrEmpty(Filter) || Filter == "*")
                {
                    string conf = ReadConfirm($"DANGER: kill ALL {FullList.Count} matching '{Filter}'? Type YES: ", winW);
                    if (!string.Equals(conf, "YES", StringComparison.OrdinalIgnoreCase)) { NeedRedraw = true; return; }
                }
                else
                {
                    string conf = ReadConfirm($"Confirm kill ALL {FullList.Count}? Type YES: ", winW);
                    if (!string.Equals(conf, "YES", StringComparison.OrdinalIgnoreCase)) { NeedRedraw = true; return; }
                }

                var toKill = new List<int>();
                foreach (var item in FullList)
                {
                    if (item.Pid == Environment.ProcessId) continue;
                    if (IsProtected(item))
                    {
                        string conf2 = ReadConfirm($"Skip critical {item.Name} (PID {item.Pid})? y=skip n=force: ", winW);
                        if (string.Equals(conf2, "n", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(conf2, "KILL", StringComparison.OrdinalIgnoreCase))
                        {
                            string conf3 = ReadConfirm($"FORCE kill critical {item.Name}? Type KILL: ", winW);
                            if (!string.Equals(conf3, "KILL", StringComparison.OrdinalIgnoreCase)) continue;
                            toKill.Add(item.Pid);
                        }
                        continue;
                    }
                    toKill.Add(item.Pid);
                }
                KillAsync(toKill);
                NextRefresh = DateTime.UtcNow;

                // Clear filter after mass kill
                Filter = "";
                Selected = 0;
                ScrollOffset = 0;
                ApplyFilterAndSort();
            }
            NeedRedraw = true;
        }

        static void DoSearch()
        {
            int winW = Math.Max(70, Console.WindowWidth - 1);
            var sb = new StringBuilder(Filter ?? "");
            Console.CursorVisible = true;
            while (true)
            {
                Filter = sb.ToString();
                Selected = 0;
                ScrollOffset = 0;
                ApplyFilterAndSort();
                Draw();

                string prompt = "LIVE SEARCH (* ok  Esc=cancel  Enter=done) > " + sb.ToString() + "_";
                if (prompt.Length > winW) prompt = prompt.Substring(0, winW);
                prompt = prompt.PadRight(winW);
                try
                {
                    Console.SetCursorPosition(0, Console.WindowHeight - 1);
                    Console.BackgroundColor = ConsoleColor.DarkYellow;
                    Console.ForegroundColor = ConsoleColor.Black;
                    Console.Write(prompt);
                    SetDrawColors();
                }
                catch { }

                var k = Console.ReadKey(true);
                if (k.Key == ConsoleKey.Enter) { Filter = sb.ToString().Trim(); break; }
                if (k.Key == ConsoleKey.Escape) { Filter = ""; break; }
                if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) sb.Length--; }
                else if (!char.IsControl(k.KeyChar)) sb.Append(k.KeyChar);
            }
            Console.CursorVisible = false;
            ApplyFilterAndSort();
            NextRefresh = DateTime.UtcNow;
            NeedRedraw = true;
        }

        static void DoRun()
        {
            int winW = Math.Max(70, Console.WindowWidth - 1);
            var sb = new StringBuilder();
            Console.CursorVisible = true;
            while (true)
            {
                string prompt = "CONSOLE RUN (Esc=cancel Enter=start) > " + sb.ToString();
                if (prompt.Length > winW) prompt = prompt.Substring(0, winW);
                prompt = prompt.PadRight(winW);
                try
                {
                    Console.SetCursorPosition(0, Console.WindowHeight - 1);
                    Console.BackgroundColor = ConsoleColor.DarkGreen;
                    Console.ForegroundColor = ConsoleColor.Black;
                    Console.Write(prompt);
                    SetDrawColors();
                }
                catch { }

                var k = Console.ReadKey(true);
                if (k.Key == ConsoleKey.Enter)
                {
                    string cmd = sb.ToString().Trim();
                    if (cmd.Length > 0)
                    {
                        try { Process.Start(new ProcessStartInfo { FileName = cmd, UseShellExecute = true }); }
                        catch (Exception ex)
                        {
                            try
                            {
                                Console.SetCursorPosition(0, Console.WindowHeight - 1);
                                Console.BackgroundColor = ConsoleColor.DarkRed;
                                Console.ForegroundColor = ConsoleColor.White;
                                Console.Write(("ERROR: " + ex.Message).PadRight(winW).Substring(0, winW));
                                SetDrawColors();
                                Thread.Sleep(2000);
                            }
                            catch { }
                        }
                    }
                    NextRefresh = DateTime.UtcNow;
                    break;
                }
                if (k.Key == ConsoleKey.Escape) break;
                if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) sb.Length--; }
                else if (!char.IsControl(k.KeyChar)) sb.Append(k.KeyChar);
            }
            Console.CursorVisible = false;
            NeedRedraw = true;
        }
    }
}
'@
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projCon.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progCs.Replace('__APPNAME__',$Name) -Encoding UTF8
}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir,[string]$Kind){$tpl='console';Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new',$tpl,'-n',$Name,'-o',$Dir);if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the .csproj file is missing from the project directory.'}}
function Publish-Project([string]$ExePath,[string]$Dir,[string]$Out){Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore',$Dir);Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish',$Dir,'-c','Release','-r','win-x64','--self-contained','true','-o',$Out)}
function Start-PublishedApp([string]$Exe,[string]$WorkDir){try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable itself is valid and complete - start it manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
if($ProjectType -eq 'Auto'){$Script:AppKind='Console'}else{$Script:AppKind=$ProjectType}
$ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set on this machine.'}
$ProjectDir=Join-Path $BaseDir $ProjectName
$PublishDir=Join-Path $ProjectDir 'publish'
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' ($($Script:AppKind) app, .NET 8, single-file exe)" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Initialize-Tls
$Script:StageName='Environment checks'
Write-Stage '1/8' 'Initializing TLS and checking free disk space'
Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced; target framework net8.0."
Test-DiskSpace -Path $BaseDir
$Script:StageName='Clean slate'
Write-Stage '2/8' "Preparing a clean workspace: $ProjectDir"
if(Test-Path -LiteralPath $ProjectDir){Write-Info 'Existing project folder found; destroying it completely for a clean slate...';if(-not (Remove-Folder -Path $ProjectDir)){Write-Err2 "Could not delete '$ProjectDir' after repeated attempts.";Write-Err2 'Usual culprits: the folder is open in an editor, terminal or Explorer window, an antivirus scan holds a lock, OneDrive is syncing, or an app from a previous run is still running.';Write-Err2 'Next step: close everything that uses this folder (or reboot) and run the script again.';exit 7}Write-Ok 'Old project folder removed and verified gone.'}
try{[void][IO.Directory]::CreateDirectory($BaseDir)}catch{Throw-Code 7 "Could not create base directory '$BaseDir': $($_.Exception.Message)"}
try{[void][IO.Directory]::CreateDirectory($ProjectDir)}catch{Throw-Code 7 "Could not create project directory '$ProjectDir': $($_.Exception.Message)"}
if(-not (Test-Path -LiteralPath $ProjectDir)){Throw-Code 7 "Project directory '$ProjectDir' could not be created or verified."}
Write-Ok 'Fresh, empty project directory is ready.'
$Script:StageName='.NET SDK detection/install'
Write-Stage '3/8' 'Detecting or installing the .NET 8 SDK (user-local, zero elevation)'
$DotNetExe=Find-DotNetSdk
if($DotNetExe){$sdkSource='pre-existing .NET 8 SDK already on this machine';Write-Ok "Using verified 8.x SDK: $DotNetExe"}
else{Write-Info "No functional .NET 8 SDK detected; installing a user-local copy under: $($Script:DotnetDir)";Install-DotNetSdk;Set-DotNetEnv -Dir $Script:DotnetDir;$DotNetExe=Join-Path $Script:DotnetDir 'dotnet.exe';if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){Write-Warn2 'SDK verification failed; wiping and reinstalling once...';if(-not (Remove-Folder -Path $Script:DotnetDir)){Throw-Code 3 "Could not delete the corrupt SDK directory."};Install-DotNetSdk;Set-DotNetEnv -Dir $Script:DotnetDir;if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){Throw-Code 3 'The .NET 8 SDK was installed but still fails verification.'}};$sdkSource='freshly installed user-local SDK'}
$v=(& $DotNetExe --version);if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet --version failed with exit code $LASTEXITCODE."}
Write-Ok "Verified .NET SDK version: $v"
Write-Ok "SDK source: $sdkSource"
$Script:StageName='Project creation'
Write-Stage '4/8' "Creating the $($Script:AppKind) project from the official template"
New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir -Kind $Script:AppKind
Write-Ok 'Template scaffolded.'
$Script:StageName='Writing sources'
Write-Stage '5/8' "Writing application source files ($($Script:AppKind))"
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName -Kind $Script:AppKind
Write-Ok "All application source files written for the $($Script:AppKind) template."
$Script:StageName='Restore/build/publish'
Write-Stage '6/8' 'Publishing: Release / win-x64 / self-contained single-file (this can take several minutes)'
Publish-Project -ExePath $DotNetExe -Dir $ProjectDir -Out $PublishDir
Write-Ok 'Publish completed with exit code 0.'
$Script:StageName='Artifact verification'
Write-Stage '7/8' 'Verifying the published executable'
$exe=Join-Path $PublishDir ($ProjectName+'.exe')
if(-not (Test-Path -LiteralPath $exe)){Start-Sleep -Seconds 3}
if(-not (Test-Path -LiteralPath $exe)){Throw-Code 5 "Publish reported success but '$exe' does not exist. Antivirus may have quarantined it."}
$size=(Get-Item -LiteralPath $exe).Length
if($size -lt 1MB){Throw-Code 5 "The published exe is only $size bytes - far too small for a self-contained single-file build."}
$sizeMb=[math]::Round($size/1MB,1)
Write-Ok "Executable verified: $exe ($sizeMb MB)"
$Script:StageName='Launch'
if($NoLaunch){Write-Stage '8/8' 'Auto-launch skipped (-NoLaunch was provided)';Write-Info "Run the app anytime by double-clicking: $exe"}
else{Write-Stage '8/8' 'Launching the freshly built application';if(-not (Start-PublishedApp -Exe $exe -WorkDir $PublishDir)){exit 6}}
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '  SUCCESS - application built, verified and ready' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Ok "Project folder : $ProjectDir"
Write-Ok "Publish folder : $PublishDir"
Write-Ok "Executable     : $exe ($sizeMb MB)"
Write-Ok "SDK source     : $sdkSource"
Write-Ok ("Elapsed time   : {0:hh\:mm\:ss}" -f $sw.Elapsed)
Write-Ok 'The exe is fully self-contained: it runs on any Windows 10/11/Server 2016+ x64 machine with no .NET prerequisites.'
exit 0
}
catch{$code=1;if($_.Exception.Message -match '^\[(\d)\]'){$code=[int]$Matches[1]};Write-Host '';Write-Err2 "FAILED during stage: $($Script:StageName)";Write-Err2 "Error: $($_.Exception.Message)";Write-Err2 'Likely cause: the issue named above (no internet, proxy/TLS blocking, antivirus, locked folder, missing permissions or low disk space).';Write-Err2 'Next step: fix that issue and run this script again - it always starts from a clean slate.';exit $code}
finally{if($Script:InstallerPath -and (Test-Path -LiteralPath $Script:InstallerPath)){Remove-Item -LiteralPath $Script:InstallerPath -Force -ErrorAction SilentlyContinue}}
