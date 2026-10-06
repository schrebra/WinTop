param([string]$ProjectName='WinTop',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$Script:StageName='Initialization';$Script:ToolchainDir=Join-Path $env:LOCALAPPDATA 'WinTopToolchain';$Script:Compiler=$null
function Write-Info([string]$m){Write-Host $m -ForegroundColor Cyan}
function Write-Ok([string]$m){Write-Host $m -ForegroundColor Green}
function Write-Warn2([string]$m){Write-Host $m -ForegroundColor Yellow}
function Write-Err2([string]$m){Write-Host $m -ForegroundColor Red}
function Throw-Code([int]$c,[string]$m){throw "[$c] $m"}
function Write-Stage([string]$n,[string]$m){Write-Host '';Write-Host "[$n] $m" -ForegroundColor Cyan}
function Initialize-Tls{try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}catch{};try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13}catch{}}
function Get-SafeName([string]$n){$n=[regex]::Replace($n,'[^A-Za-z0-9_]','');if($n.Length -eq 0){return 'GeneratedApp'};if($n -match '^\d'){$n='App'+$n};return $n.Substring(0,1).ToUpperInvariant()+$n.Substring(1)}
function Remove-Folder([string]$Path){$p=$Path.TrimEnd('\');if(-not (Test-Path -LiteralPath $p)){return $true};for($i=1;$i -le 3;$i++){try{Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {try{$_.Attributes=[IO.FileAttributes]::Normal}catch{}};Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop}catch{Start-Sleep -Seconds ([math]::Min(30,5*$i))};if(-not (Test-Path -LiteralPath $p)){return $true}};try{& cmd.exe /c rd /s /q "$p" | Out-Null}catch{};$gone=-not (Test-Path -LiteralPath $p);if(-not $gone){Write-Warn2 "cmd rd /s /q exited with code $LASTEXITCODE but '$p' still exists."};return $gone}
function Save-FileWithRetry([string]$Url,[string]$Dest){for($i=1;$i -le $MaxRetries;$i++){if(Test-Path -LiteralPath $Dest){Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue};try{if($env:HTTPS_PROXY){Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 180 -Proxy $env:HTTPS_PROXY -ErrorAction Stop}else{Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop};if((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 1000)){$head=((Get-Content -LiteralPath $Dest -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ');if($head -notmatch '(?i)<\s*html|<!doctype'){return $true}}}catch{};Write-Warn2 "Download attempt $i failed for: $Url";if($i -lt $MaxRetries){Write-Warn2 "Retrying in $([math]::Min(30,5*$i)) seconds...";Start-Sleep -Seconds ([math]::Min(30,5*$i))}};return $false}
function Test-DiskSpace([string]$Path){$gb=$null;try{$di=New-Object IO.DriveInfo($Path.Substring(0,1));if($di.IsReady){$gb=[math]::Round($di.AvailableFreeSpace/1GB,2)}}catch{};if($null -eq $gb){Write-Warn2 'Could not determine free disk space; continuing.';return};$L=$Path.Substring(0,1);if($gb -lt 0.5){Throw-Code 1 "Only $gb GB free on drive ${L}: - at least 0.5 GB is required."}elseif($gb -lt 2){Write-Warn2 "Low disk space: $gb GB free on drive ${L}:"}else{Write-Ok "Disk space OK: $gb GB free on drive ${L}:"}}
function Install-ZigToolchain{
  # Portable Zig toolchain: a plain .zip (w64devkit now ships 7z self-extractors,
  # which need 7-Zip). zig c++ targets x86_64-windows-gnu with no extra DLLs.
  $dest=$Script:ToolchainDir
  $found=Get-ChildItem -LiteralPath $dest -Recurse -Filter 'zig.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if($found){
    Write-Ok "Reusing previously downloaded toolchain: $($found.FullName)"
    return @{Kind='zig';Exe=$found.FullName;Desc='Zig toolchain (previously downloaded)'}
  }
  Write-Info 'No C++ compiler found on this machine.'
  Write-Info 'Downloading a portable Zig toolchain (user-local, no admin needed)...'
  Initialize-Tls
  $url=$null
  for($i=1;$i -le $MaxRetries -and -not $url;$i++){
    try{
      $idx=((Invoke-WebRequest -Uri 'https://ziglang.org/download/index.json' -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content | ConvertFrom-Json)
      $vers=@($idx.PSObject.Properties.Name | Where-Object {$_ -match '^\d+\.\d+\.\d+$'} | ForEach-Object {[version]$_} | Sort-Object)
      if($vers.Count -gt 0){
        $v=$vers[-1].ToString()
        $tb=$idx.$v.'x86_64-windows'.tarball
        if($tb){$url=$tb;Write-Info "Latest stable Zig: $v"}
      }
    }catch{Write-Warn2 "Version index attempt $i failed."}
    if(-not $url -and $i -lt $MaxRetries){Start-Sleep -Seconds ([math]::Min(30,5*$i))}
  }
  if(-not $url){$url='https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip';Write-Warn2 'Version index unreachable; falling back to pinned Zig 0.17.0.'}
  Write-Info "Downloading: $url"
  $zip=Join-Path $env:TEMP 'zig-windows.zip'
  if(-not (Save-FileWithRetry -Url $url -Dest $zip)){Throw-Code 2 'Could not download the Zig toolchain.'}
  Write-Info "Extracting to: $dest"
  try{[void][IO.Directory]::CreateDirectory($dest)}catch{}
  try{Expand-Archive -Path $zip -DestinationPath $dest -Force -ErrorAction Stop}catch{Throw-Code 3 "Toolchain extraction failed: $($_.Exception.Message)"}
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  $found=Get-ChildItem -LiteralPath $dest -Recurse -Filter 'zig.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $found){Throw-Code 3 'Toolchain extracted but zig.exe was not found inside it.'}
  $prev=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$v=(& $found.FullName version 2>$null)}catch{$v=''}finally{$ErrorActionPreference=$prev}
  Write-Ok "Portable toolchain ready: Zig $v"
  return @{Kind='zig';Exe=$found.FullName;Desc="Zig $v (portable, downloaded user-local)"}
}
function Find-Compiler{
  # 1) MSVC via vswhere (Visual Studio / Build Tools install)
  $vswhere=$null
  foreach($p in @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),(Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'))){
    if(Test-Path -LiteralPath $p){$vswhere=$p;break}
  }
  if($vswhere){
    $prev=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{
      $inst=(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools -property installationPath 2>$null | Select-Object -First 1)
      if($inst -and (Test-Path -LiteralPath $inst)){
        $vcvars=Join-Path $inst 'VC\Auxiliary\Build\vcvars64.bat'
        if(Test-Path -LiteralPath $vcvars){return @{Kind='msvc';VcVars=$vcvars;Desc="MSVC (Visual Studio at $inst)"}}
      }
    }catch{}finally{$ErrorActionPreference=$prev}
  }
  # 2) cl.exe already on PATH with a working env (e.g. Developer Command Prompt)
  $cl=Get-Command cl.exe -ErrorAction SilentlyContinue
  if($cl -and $env:INCLUDE){
    $prev=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{& $cl.Source /? >$null 2>$null;if($LASTEXITCODE -eq 0){return @{Kind='msvc';VcVars='';Desc='MSVC cl.exe (already on PATH)'}}}catch{}finally{$ErrorActionPreference=$prev}
  }
  # 3) g++ on PATH (MinGW-w64, msys2)
  $gxx=Get-Command g++.exe -ErrorAction SilentlyContinue
  if($gxx){
    $prev=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$v=(& $gxx.Source --version 2>$null | Select-Object -First 1);if($LASTEXITCODE -eq 0){return @{Kind='gcc';Exe=$gxx.Source;Desc="g++ on PATH ($v)"}}}catch{}finally{$ErrorActionPreference=$prev}
  }
  # 4) portable Zig toolchain, downloaded user-local, zero elevation
  return Install-ZigToolchain
}
function Write-SourceFiles([string]$Dir,[string]$Name){
  # The application icon is no longer baked in at compile time: Set-ExeIcon
  # stamps it into the finished exe afterwards, which works on every compiler
  # path (the Zig toolchain has no resource compiler, so the old .rc approach
  # could never cover it).
  $utf8NoBom=New-Object System.Text.Utf8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $Dir ($Name+'.cpp')),$cppCode.Replace('__APPNAME__',$Name),$utf8NoBom)
}
function Build-WithMsvc([hashtable]$C,[string]$Dir,[string]$Name){
  $lines=New-Object Collections.Generic.List[string]
  if($C.VcVars){$lines.Add('call "'+$C.VcVars+'" >NUL')}
  $lines.Add('cl /nologo /O2 /EHsc /std:c++17 /utf-8 /DUNICODE /D_UNICODE "'+$Name+'.cpp" /Fe:"'+$Name+'.exe"')
  $lines.Add('if errorlevel 1 exit /b 1')
  [IO.File]::WriteAllLines((Join-Path $Dir 'build.bat'),$lines,[Text.Encoding]::ASCII)
  Push-Location -LiteralPath $Dir
  try{& cmd.exe /c build.bat;if($LASTEXITCODE -ne 0){Throw-Code 5 "C++ compilation failed (exit code $LASTEXITCODE). See the compiler output above."}}
  finally{Pop-Location}
}
function Invoke-Gcc([string]$Exe,[string[]]$GccArgs,[string]$Dir){Push-Location -LiteralPath $Dir;try{& $Exe @GccArgs}finally{Pop-Location};return $LASTEXITCODE}
function Build-WithGcc([hashtable]$C,[string]$Dir,[string]$Name){
  $gccArgs=@('-O2','-std=c++17','-municode','-static','-static-libgcc','-static-libstdc++','-o',($Name+'.exe'),($Name+'.cpp'))
  $gccArgs+=@('-lpsapi')
  $code=Invoke-Gcc -Exe $C.Exe -GccArgs $gccArgs -Dir $Dir
  if($code -ne 0){
    Write-Warn2 "Static build failed (exit $code); retrying as a dynamic build..."
    $gccArgs2=@($gccArgs | Where-Object {$_ -notlike '-static*'})
    $code=Invoke-Gcc -Exe $C.Exe -GccArgs $gccArgs2 -Dir $Dir
    if($code -ne 0){Throw-Code 5 "C++ compilation failed (exit code $code). See the compiler output above."}
  }
}
function Build-WithZig([hashtable]$C,[string]$Dir,[string]$Name){
  Write-Info 'First Zig build compiles its bundled C runtime - can take a few minutes, then it is cached.'
  Push-Location -LiteralPath $Dir
  try{& $C.Exe c++ -O2 -std=c++17 -target x86_64-windows-gnu -municode -o ($Name+'.exe') ($Name+'.cpp') -lpsapi;if($LASTEXITCODE -ne 0){Throw-Code 5 "C++ compilation failed (exit code $LASTEXITCODE). See the compiler output above."}}
  finally{Pop-Location}
}
function Start-BuiltApp([string]$Exe,[string]$WorkDir){try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable itself is valid and complete - start it manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
# ----------------------------------------------------------------------------
# Embedded application icon: the official htop logo (htop.svg, htop-dev/htop),
# pre-rendered to 16/32/48/256 px and packed as a classic .ico, base64 below.
# Set-ExeIcon stamps it into the finished exe as icon resource #1 through the
# Win32 resource-update API (BeginUpdateResource/UpdateResource/EndUpdateResource).
# That single icon feeds BOTH the taskbar button and the console window's
# title-bar icon (Windows uses the exe's first icon for both), and it works
# identically on the MSVC, MinGW and Zig build paths -- the Zig toolchain has
# no resource compiler, so the old .rc approach could never cover it.
# ----------------------------------------------------------------------------
$Script:WinTopIconB64=@'
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
AABJRU5ErkJggg==
'@
function Set-ExeIcon([string]$Exe){
  Write-Info 'Stamping the htop icon into the executable (taskbar + window icon)...'
  $raw=[Convert]::FromBase64String(($Script:WinTopIconB64 -replace '\s',''))
  if([BitConverter]::ToUInt16($raw,0) -ne 0 -or [BitConverter]::ToUInt16($raw,2) -ne 1){Throw-Code 5 'Embedded icon data is corrupt (not an .ico file).'}
  $count=[BitConverter]::ToUInt16($raw,4)
  if($count -lt 1 -or $count -gt 32){Throw-Code 5 "Embedded icon data is corrupt (image count $count)."}
  $cs=@'
using System;
using System.Runtime.InteropServices;
public static class WinTopIconStamper {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr BeginUpdateResource(string fileName, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool UpdateResource(IntPtr hUpdate, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool EndUpdateResource(IntPtr hUpdate, bool discard);
    public static bool WriteIconImage(IntPtr h, int id, byte[] data) {
        return UpdateResource(h, new IntPtr(3), new IntPtr(id), 0, data, (uint)data.Length);
    }
    public static bool WriteIconGroup(IntPtr h, byte[] data) {
        return UpdateResource(h, new IntPtr(14), new IntPtr(1), 0, data, (uint)data.Length);
    }
    public static int LastError() { return Marshal.GetLastWin32Error(); }
}
'@
  try{Add-Type -TypeDefinition $cs -ErrorAction Stop}
  catch{Throw-Code 5 "Could not compile the icon-stamping helper: $($_.Exception.Message)"}
  # Parse the .ico directory: ICONDIR + one 16-byte ICONDIRENTRY per image.
  $imgs=@()
  for($i=0;$i -lt $count;$i++){
    $o=6+$i*16
    $len=[BitConverter]::ToUInt32($raw,$o+8)
    $off=[BitConverter]::ToUInt32($raw,$o+12)
    if(($off+$len) -gt $raw.Length){Throw-Code 5 "Embedded icon data is corrupt (image $i out of range)."}
    $bytes=New-Object byte[] $len
    [Buffer]::BlockCopy($raw,[int]$off,$bytes,0,[int]$len)
    $imgs+=[pscustomobject]@{W=$raw[$o];H=$raw[$o+1];CC=$raw[$o+2];Planes=[BitConverter]::ToUInt16($raw,$o+4);Bpp=[BitConverter]::ToUInt16($raw,$o+6);Len=$len;Data=$bytes}
  }
  $h=[WinTopIconStamper]::BeginUpdateResource($Exe,$false)
  if($h -eq [IntPtr]::Zero){Throw-Code 5 "Could not open '$Exe' for icon stamping (Win32 error $([WinTopIconStamper]::LastError()))."}
  try{
    # Each image becomes an RT_ICON (type 3) resource with a numeric id...
    $id=1
    foreach($im in $imgs){
      if(-not [WinTopIconStamper]::WriteIconImage($h,$id,$im.Data)){Throw-Code 5 "Failed writing icon image $id (Win32 error $([WinTopIconStamper]::LastError()))."}
      $id++
    }
    # ...and the RT_GROUP_ICON (type 14) directory points at those ids.
    $ms=New-Object IO.MemoryStream
    $bw=New-Object IO.BinaryWriter($ms)
    $bw.Write([uint16]0);$bw.Write([uint16]1);$bw.Write([uint16]$count)
    $id=1
    foreach($im in $imgs){
      $bw.Write([byte]$im.W);$bw.Write([byte]$im.H);$bw.Write([byte]$im.CC);$bw.Write([byte]0)
      $bw.Write([uint16]$im.Planes);$bw.Write([uint16]$im.Bpp);$bw.Write([uint32]$im.Len);$bw.Write([uint16]$id)
      $id++
    }
    $bw.Flush()
    if(-not [WinTopIconStamper]::WriteIconGroup($h,$ms.ToArray())){Throw-Code 5 "Failed writing the icon directory (Win32 error $([WinTopIconStamper]::LastError()))."}
    if(-not [WinTopIconStamper]::EndUpdateResource($h,$false)){Throw-Code 5 "Failed committing the icon resources (Win32 error $([WinTopIconStamper]::LastError()))."}
  }catch{
    try{[WinTopIconStamper]::EndUpdateResource($h,$true)|Out-Null}catch{}
    throw
  }
  Write-Ok 'Icon stamped: the taskbar button and the console window now use the htop artwork.'
}
# ----------------------------------------------------------------------------
# Embedded application source (native C++, no .NET). __APPNAME__ is replaced
# with the project name when the sources are written out.
# ----------------------------------------------------------------------------
$cppCode=@'
// __APPNAME__.cpp — native C++ port of the WinTop terminal system monitor.
// Built by the WinTop PowerShell bootstrap using MSVC (cl) or MinGW-w64 (g++).
// No .NET, no runtime: the exe runs on any Windows 10/11/Server 2016+ x64 box.

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <conio.h>
#include <cwctype>
#include <cstdio>
#include <string>
#include <vector>
#include <queue>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <cmath>
#include <regex>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <iostream>
#include <climits>

#ifdef _MSC_VER
#pragma comment(lib, "psapi.lib")
#endif

static const wchar_t* APPNAME = L"__APPNAME__";

// Console palette (same 16 colors as the C# ConsoleColor set).
enum {
    C_BLACK = 0, C_DBLUE = 1, C_DGREEN = 2, C_DCYAN = 3, C_DRED = 4,
    C_DMAG = 5, C_DYELLOW = 6, C_GRAY = 7, C_DGRAY = 8, C_BLUE = 9,
    C_GREEN = 10, C_CYAN = 11, C_RED = 12, C_MAG = 13, C_YELLOW = 14, C_WHITE = 15
};

static const int BAR_WIDTH = 30;

// Special-key codes returned by ReadKey() (0x100 + scan code).
enum {
    K_UP = 0x100 + 72, K_DOWN = 0x100 + 80, K_LEFT = 0x100 + 75, K_RIGHT = 0x100 + 77,
    K_HOME = 0x100 + 71, K_END = 0x100 + 79, K_PGUP = 0x100 + 73, K_PGDN = 0x100 + 81,
    K_F1 = 0x100 + 59, K_F3 = 0x100 + 61, K_F6 = 0x100 + 64,
    K_F9 = 0x100 + 67, K_F10 = 0x100 + 68
};

struct ProcInfo {
    int pid = 0;
    std::wstring name;
    std::wstring path;
    double cpu = 0.0;
    double mem = 0.0;
    double readMBps = 0.0;
    double writeMBps = 0.0;
    bool isSystem = false;
    bool isNew = false;
};

struct DriveInfo2 {
    std::wstring name;
    double usedGb = 0.0, totGb = 0.0, pct = 0.0;
};

// ---- global state (UI thread owns everything except the sampler-owned maps) ----
static HANDLE hOut = NULL, hIn = NULL;
static std::mutex g_sync;
static std::unordered_map<int, unsigned long long> g_prevCpu;   // 100ns units
static std::unordered_map<int, unsigned long long> g_prevRead;
static std::unordered_map<int, unsigned long long> g_prevWrite;
struct PathCacheEntry { unsigned long long createTime; std::wstring path; };
static std::unordered_map<int, PathCacheEntry> g_pathCache; // sampler thread only
static std::unordered_set<int> g_prevLiveIds;   // sampler thread only
static std::unordered_map<int, std::chrono::steady_clock::time_point> g_newProcs; // pid -> green-highlight expiry
static bool g_firstSample = true;
static const int NEW_PROC_HIGHLIGHT_SECS = 10;   // Process Explorer-style new-process flash
static std::vector<ProcInfo> g_allProcs;      // written by sampler under lock
static std::vector<ProcInfo> g_fullList;      // filtered+sorted, UI thread only
static int g_selected = 0, g_scrollOffset = 0;
static std::wstring g_filter;
static std::wstring g_sortBy = L"CPU";
static bool g_sortDesc = true;
static bool g_running = true, g_paused = false, g_needRedraw = true;
static bool g_showAll = true;
static std::chrono::steady_clock::time_point g_nextRefresh;
static double g_lastSysCpu = 0.0, g_lastMemUsed = 0.0, g_lastMemTot = 0.0, g_lastMemPct = 0.0;
static std::vector<DriveInfo2> g_drives;
static int g_totalProcesses = 0;
static int g_userProcs = 0, g_sysProcs = 0;
static const wchar_t* SORT_COLUMNS[] = { L"CPU", L"MEM", L"READ", L"WRITE", L"NAME", L"PID" };
static std::wstring g_host, g_user;
static std::chrono::steady_clock::time_point g_lastSample;
static std::queue<double> g_cpuSamples;
static std::atomic<bool> g_samplerStop{ false };
static int g_lastWinW = -1, g_lastWinH = -1;
static int g_origBufW = 80, g_origBufH = 25;
static bool g_bufferLocked = false;
static DWORD g_origConsoleMode = 0;
static bool g_haveOrigConsoleMode = false;
static WORD g_origAttr = 0x07;
static DWORD g_ownPid = 0;

static const wchar_t* CRITICAL_NAMES[] = {
    L"system", L"idle", L"registry", L"smss", L"csrss", L"wininit", L"services",
    L"lsass", L"winlogon", L"fontdrvhost", L"dwm", L"svchost",
    L"memory compression", L"secure system"
};

// ---------------- console helpers ----------------
static void Colors(int fg, int bg) {
    SetConsoleTextAttribute(hOut, (WORD)(((bg & 0xF) << 4) | (fg & 0xF)));
}
static void SetDrawColors() { Colors(C_GRAY, C_BLACK); }   // our palette, never the host's
static void W(const std::wstring& s) {
    if (s.empty()) return;
    DWORD w = 0;
    WriteConsoleW(hOut, s.c_str(), (DWORD)s.size(), &w, NULL);
}
static void WL(const std::wstring& s) { W(s); W(L"\r\n"); }
static void GotoXY(int x, int y) {
    COORD c; c.X = (SHORT)x; c.Y = (SHORT)y;
    SetConsoleCursorPosition(hOut, c);
}
static void ShowCursor(bool v) {
    CONSOLE_CURSOR_INFO ci;
    if (GetConsoleCursorInfo(hOut, &ci)) { ci.bVisible = v ? TRUE : FALSE; SetConsoleCursorInfo(hOut, &ci); }
}
static void GetWinSize(int& w, int& h) {
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (GetConsoleScreenBufferInfo(hOut, &bi)) {
        w = bi.srWindow.Right - bi.srWindow.Left + 1;
        h = bi.srWindow.Bottom - bi.srWindow.Top + 1;
    } else { w = 80; h = 25; }
}
static void ClearAll() {
    // Repaint the whole buffer with our palette (kills the host's dark-blue bleed).
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (!GetConsoleScreenBufferInfo(hOut, &bi)) return;
    DWORD cells = (DWORD)bi.dwSize.X * (DWORD)bi.dwSize.Y;
    COORD home = { 0, 0 };
    DWORD w = 0;
    FillConsoleOutputCharacterW(hOut, L' ', cells, home, &w);
    FillConsoleOutputAttribute(hOut, 0x07, cells, home, &w);
    GotoXY(0, 0);
}
static void FitBufferToWindow() {
    // Lock the scrollback buffer to the visible window: no scrollbar, no history.
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (!GetConsoleScreenBufferInfo(hOut, &bi)) return;
    int w = bi.srWindow.Right - bi.srWindow.Left + 1;
    int h = bi.srWindow.Bottom - bi.srWindow.Top + 1;
    if (w > 0 && h > 0 && (bi.dwSize.X != w || bi.dwSize.Y != h)) {
        COORD sz; sz.X = (SHORT)w; sz.Y = (SHORT)h;
        if (SetConsoleScreenBufferSize(hOut, sz)) g_bufferLocked = true;
    }
}
static void DisableQuickEdit() {
    // Clicking the console must not freeze the app in "Select" mark mode.
    if (hIn == NULL || hIn == INVALID_HANDLE_VALUE) return;
    DWORD mode = 0;
    if (GetConsoleMode(hIn, &mode)) {
        if (!g_haveOrigConsoleMode) { g_origConsoleMode = mode; g_haveOrigConsoleMode = true; }
        SetConsoleMode(hIn, (mode & ~ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS);
    }
}
static void RestoreConsoleMode() {
    if (!g_haveOrigConsoleMode) return;
    if (hIn == NULL || hIn == INVALID_HANDLE_VALUE) return;
    SetConsoleMode(hIn, g_origConsoleMode);
}
static int ReadKey() {
    // _getwch: no echo, Unicode. Arrows/F-keys come as 0/224 + scan code.
    wint_t c = _getwch();
    if (c == 0 || c == 224) { wint_t s = _getwch(); return 0x100 + (int)s; }
    return (int)c;
}

// ---------------- string helpers ----------------
static std::wstring PadR(std::wstring s, size_t n) {
    if (s.size() < n) s.append(n - s.size(), L' ');
    else if (s.size() > n) s.resize(n);
    return s;
}
static double R1(double v) { return std::round(v * 10.0) / 10.0; }
static double R2(double v) { return std::round(v * 100.0) / 100.0; }
static std::wstring ToLower(std::wstring s) {
    for (size_t i = 0; i < s.size(); i++) s[i] = (wchar_t)towlower(s[i]);
    return s;
}
static bool CritName(const std::wstring& name) {
    std::wstring l = ToLower(name);
    for (size_t i = 0; i < sizeof(CRITICAL_NAMES) / sizeof(CRITICAL_NAMES[0]); i++)
        if (l == CRITICAL_NAMES[i]) return true;
    return false;
}
static std::wstring Trim(std::wstring s) {
    size_t a = s.find_first_not_of(L" \t\r\n");
    if (a == std::wstring::npos) return L"";
    size_t b = s.find_last_not_of(L" \t\r\n");
    return s.substr(a, b - a + 1);
}
static std::wstring FileNameNoExt(const std::wstring& path) {
    size_t p = path.find_last_of(L"\\/");
    std::wstring f = (p == std::wstring::npos) ? path : path.substr(p + 1);
    size_t d = f.find_last_of(L'.');
    if (d != std::wstring::npos) f.resize(d);
    return f;
}

// ---------------- settings ----------------
static std::wstring SettingsPath() {
    wchar_t buf[MAX_PATH] = { 0 };
    GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    return std::wstring(buf) + L"\\" + APPNAME + L"\\settings.cfg";
}
static void LoadSettings() {
    // Missing or corrupt file just means defaults — never a crash.
    FILE* f = NULL;
    _wfopen_s(&f, SettingsPath().c_str(), L"r, ccs=UTF-8");
    if (!f) return;
    wchar_t line[512];
    while (fgetws(line, 512, f)) {
        std::wstring s = line;
        while (!s.empty() && (s.back() == L'\n' || s.back() == L'\r')) s.pop_back();
        size_t a = s.find_first_not_of(L" \t");
        if (a == std::wstring::npos || s[a] == L'#') continue;
        size_t eq = s.find(L'=', a);
        if (eq == std::wstring::npos) continue;
        std::wstring key = s.substr(a, eq - a), val = s.substr(eq + 1);
        while (!key.empty() && (key.back() == L' ' || key.back() == L'\t')) key.pop_back();
        a = val.find_first_not_of(L" \t"); val = (a == std::wstring::npos) ? L"" : val.substr(a);
        while (!val.empty() && (val.back() == L' ' || val.back() == L'\t')) val.pop_back();
        std::wstring lk = ToLower(key), lv = ToLower(val);
        if (lk == L"showallprocesses") g_showAll = (lv == L"true");
        else if (lk == L"sortby") {
            std::wstring up = val;
            for (size_t i = 0; i < up.size(); i++) up[i] = (wchar_t)towupper(up[i]);
            for (size_t i = 0; i < 6; i++)
                if (up == SORT_COLUMNS[i]) { g_sortBy = up; break; }
        }
        else if (lk == L"sortdesc") g_sortDesc = (lv == L"true");
    }
    fclose(f);
}
static void SaveSettings() {
    // Written on every preference change, so it survives even a kill.
    std::wstring path = SettingsPath();
    size_t p = path.find_last_of(L"\\/");
    if (p != std::wstring::npos) {
        std::wstring dir = path.substr(0, p);
        CreateDirectoryW(dir.c_str(), NULL);
    }
    FILE* f = NULL;
    _wfopen_s(&f, path.c_str(), L"w, ccs=UTF-8");
    if (!f) return;
    fwprintf(f, L"# %s settings - safe to edit by hand\n", APPNAME);
    fwprintf(f, L"ShowAllProcesses=%s\n", g_showAll ? L"true" : L"false");
    fwprintf(f, L"SortBy=%s\n", g_sortBy.c_str());
    fwprintf(f, L"SortDesc=%s\n", g_sortDesc ? L"true" : L"false");
    fclose(f);
}

// ---------------- classification ----------------
static bool IsProtected(const ProcInfo& pr) {
    if (pr.pid <= 8 || (DWORD)pr.pid == g_ownPid) return true;
    if (CritName(pr.name)) return true;
    if (!pr.path.empty() && pr.path != L"-") {
        std::wstring l = ToLower(pr.path);
        if ((l.find(L"\\windows\\system32\\") != std::wstring::npos ||
             l.find(L"\\windows\\syswow64\\") != std::wstring::npos) &&
            CritName(FileNameNoExt(pr.path)))
            return true;
    }
    return false;
}
// Windowless per-session Windows infrastructure hosts. Only consulted for
// exes under a Windows system directory without a visible window.
static const wchar_t* INFRA_NAMES[] = {
    L"sihost", L"ctfmon", L"runtimebroker", L"dllhost", L"taskhostw", L"taskhost",
    L"conhost", L"searchhost", L"startmenuexperiencehost", L"shellexperiencehost",
    L"applicationframehost", L"textinputhost", L"searchindexer", L"wmiprvse",
    L"spoolsv"
};
static bool InfraName(const std::wstring& name) {
    std::wstring l = ToLower(name);
    for (size_t i = 0; i < sizeof(INFRA_NAMES) / sizeof(INFRA_NAMES[0]); i++)
        if (l == INFRA_NAMES[i]) return true;
    return false;
}
static bool IsWindowsSystemPath(const std::wstring& path) {
    if (path.empty() || path == L"-") return false;
    std::wstring l = ToLower(path);
    return l.find(L"\\windows\\system32\\") != std::wstring::npos ||
           l.find(L"\\windows\\syswow64\\") != std::wstring::npos ||
           l.find(L"\\windows\\winsxs\\") != std::wstring::npos ||
           l.find(L"\\windows\\servicing\\") != std::wstring::npos ||
           l.find(L"\\windows\\systemapps\\") != std::wstring::npos;
}
static bool ComputeIsSystem(int pid, const std::wstring& name, const std::wstring& path, int sessionId, bool hasWindow) {
    if (pid <= 8) return true;
    // Session 0 is the services session: nothing interactive runs there.
    if (sessionId == 0) return true;
    // Well-known core processes, matched by name too: keeps them classified as
    // system even when the image path cannot be read (protected processes).
    if (CritName(name)) return true;
    // A visible top-level window means an interactive app the user launched,
    // even if the exe happens to live in System32 (mstsc, notepad, ...).
    if (hasWindow) return false;
    // Windowless Windows-shipped binaries are OS infrastructure
    // (sihost, ctfmon, RuntimeBroker, ...). Anything else defaults to user:
    // better to show a process than to hide one he launched.
    if (IsWindowsSystemPath(path) && InfraName(name)) return true;
    return false;
}
static BOOL CALLBACK EnumWindowPids(HWND hwnd, LPARAM lParam) {
    if (!IsWindowVisible(hwnd)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid) ((std::unordered_set<DWORD>*)lParam)->insert(pid);
    return TRUE;
}
static bool WildMatch(const std::wstring& text, const std::wstring& filter) {
    if (filter.empty()) return true;
    if (filter.find(L'*') == std::wstring::npos)
        return ToLower(text).find(ToLower(filter)) != std::wstring::npos;
    std::wstring rx = L"^";
    for (size_t i = 0; i < filter.size(); i++) {
        wchar_t ch = filter[i];
        if (ch == L'*') rx += L".*";
        else {
            if (wcschr(L".^$+?()[]{}|\\", ch)) rx += L'\\';
            rx += ch;
        }
    }
    rx += L"$";
    try {
        return std::regex_match(text, std::wregex(rx, std::regex_constants::icase));
    } catch (...) { return false; }
}
static bool MatchesFilter(const ProcInfo& pr, const std::wstring& filter) {
    if (filter.empty()) return true;
    return WildMatch(pr.name, filter) ||
           WildMatch(std::to_wstring(pr.pid), filter) ||
           WildMatch(pr.path, filter);
}
static std::wstring MakeBar(double pct) {
    int f = (int)std::round(pct / 100.0 * BAR_WIDTH);
    if (f < 0) f = 0;
    if (f > BAR_WIDTH) f = BAR_WIDTH;
    return std::wstring((size_t)f, L'|') + std::wstring((size_t)(BAR_WIDTH - f), L' ');
}
static std::wstring FormatDiskPair(double usedGb, double totGb) {
    // Sub-GB volumes: show MB so the numbers stay meaningful.
    wchar_t b[64];
    if (totGb < 1.0) swprintf(b, 64, L"%.1f / %.1f MB", usedGb * 1024.0, totGb * 1024.0);
    else swprintf(b, 64, L"%.1f / %.1f GB", usedGb, totGb);
    return b;
}
static std::wstring FormatUptime() {
    unsigned long long ms = GetTickCount64();
    unsigned long long s = ms / 1000;
    wchar_t b[64];
    if (s >= 86400) swprintf(b, 64, L"%llud %lluh %llum", s / 86400, (s / 3600) % 24, (s / 60) % 60);
    else if (s >= 3600) swprintf(b, 64, L"%lluh %llum %llus", s / 3600, (s / 60) % 60, s % 60);
    else swprintf(b, 64, L"%llum %llus", s / 60, s % 60);
    return b;
}
static std::wstring NowHM() {
    SYSTEMTIME st; GetLocalTime(&st);
    wchar_t b[16]; swprintf(b, 16, L"%02d:%02d:%02d", st.wHour, st.wMinute, st.wSecond);
    return b;
}

// ---------------- sampling ----------------
static void SampleProcesses() {
    auto now = std::chrono::steady_clock::now();
    double elapsed;
    {
        std::lock_guard<std::mutex> lk(g_sync);
        elapsed = std::chrono::duration<double>(now - g_lastSample).count();
    }
    if (elapsed < 0.5) elapsed = 0.5;

    double memUsedMb = 0, memTotMb = 0, memPct = 0;
    MEMORYSTATUSEX ms; ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) {
        memTotMb = std::round(ms.ullTotalPhys / 1048576.0);
        memUsedMb = std::round((ms.ullTotalPhys - ms.ullAvailPhys) / 1048576.0);
        memPct = (double)ms.dwMemoryLoad;
    }

    std::vector<DriveInfo2> drives;
    DWORD dmask = GetLogicalDrives();
    for (int i = 0; i < 26; i++) {
        if (!(dmask & (1u << i))) continue;
        wchar_t root[4] = { (wchar_t)(L'A' + i), L':', L'\\', 0 };
        if (GetDriveTypeW(root) != DRIVE_FIXED) continue;
        ULARGE_INTEGER freeB, totB, totFree;
        if (!GetDiskFreeSpaceExW(root, &freeB, &totB, &totFree)) continue;
        double tot = totB.QuadPart / 1073741824.0;
        double fr = freeB.QuadPart / 1073741824.0;
        double used = tot - fr;
        DriveInfo2 d;
        d.name = std::wstring(1, (wchar_t)(L'A' + i)) + L":";
        d.usedGb = used; d.totGb = tot;
        d.pct = tot > 0 ? used / tot * 100.0 : 0;
        drives.push_back(d);
    }

    // One window enumeration per sample: which PIDs own a visible top-level
    // window (used to tell user-launched GUI apps apart from OS plumbing).
    std::unordered_set<DWORD> windowPids;
    EnumWindows(EnumWindowPids, (LPARAM)&windowPids);

    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    std::vector<ProcInfo> list;
    int total = 0, userCount = 0, sysCount = 0;
    double sumCpu = 0;
    int cores = 1;
    SYSTEM_INFO si; GetSystemInfo(&si);
    cores = si.dwNumberOfProcessors > 0 ? (int)si.dwNumberOfProcessors : 1;
    std::unordered_set<int> liveIds;

    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe; pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) {
            do {
                int pid = (int)pe.th32ProcessID;
                liveIds.insert(pid);
                total++;

                // Process Explorer-style "new process" highlight: a PID never
                // seen before flashes green for a few seconds.
                bool pidIsNew = false;
                if (!g_firstSample && g_prevLiveIds.find(pid) == g_prevLiveIds.end()) {
                    g_newProcs[pid] = now + std::chrono::seconds(NEW_PROC_HIGHLIGHT_SECS);
                    pidIsNew = true;
                } else {
                    auto nit = g_newProcs.find(pid);
                    pidIsNew = (nit != g_newProcs.end() && now < nit->second);
                }

                int sessId = -1;
                DWORD s = 0;
                if (ProcessIdToSessionId((DWORD)pid, &s)) sessId = (int)s;

                std::wstring pname = pe.szExeFile;

                // QUERY_LIMITED_INFORMATION only: asking for the full right is
                // all-or-nothing, and SYSTEM/protected processes deny it to a
                // non-elevated token — which used to leave the path as "-".
                HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
                double cpu = 0;
                unsigned long long createTime = 0;
                if (h) {
                    FILETIME fc, fe, fk, fu;
                    if (GetProcessTimes(h, &fc, &fe, &fk, &fu)) {
                        ULARGE_INTEGER ct;
                        ct.LowPart = fc.dwLowDateTime; ct.HighPart = fc.dwHighDateTime;
                        createTime = ct.QuadPart;
                        ULARGE_INTEGER k, u;
                        k.LowPart = fk.dwLowDateTime; k.HighPart = fk.dwHighDateTime;
                        u.LowPart = fu.dwLowDateTime; u.HighPart = fu.dwHighDateTime;
                        unsigned long long tpt = k.QuadPart + u.QuadPart; // 100ns
                        auto it = g_prevCpu.find(pid);
                        if (it != g_prevCpu.end())
                            cpu = std::max(0.0, R1((tpt - it->second) / 1e7 / elapsed / cores * 100.0));
                        g_prevCpu[pid] = tpt;
                        sumCpu += cpu;
                    }
                }

                double memMb = 0;
                std::wstring fullPath = L"-";
                double readMBps = 0, writeMBps = 0;
                if (h) {
                    PROCESS_MEMORY_COUNTERS pmc;
                    if (GetProcessMemoryInfo(h, &pmc, sizeof(pmc)))
                        memMb = R1(pmc.WorkingSetSize / 1048576.0);
                    // A PID's exe path never changes during the process's lifetime,
                    // so cache it: QueryFullProcessImageNameW is the most expensive
                    // call in the sample loop. The creation time guards against
                    // PID reuse (a recycled PID gets a fresh query).
                    auto pcit = g_pathCache.find(pid);
                    if (createTime && pcit != g_pathCache.end() && pcit->second.createTime == createTime) {
                        fullPath = pcit->second.path;
                    } else {
                        wchar_t ibuf[1024]; DWORD isz = 1024;
                        if (QueryFullProcessImageNameW(h, 0, ibuf, &isz) && isz > 0)
                            fullPath.assign(ibuf, isz);
                        if (createTime) g_pathCache[pid] = { createTime, fullPath };
                    }
                    IO_COUNTERS io;
                    if (GetProcessIoCounters(h, &io)) {
                        // Guard against PID reuse: a recycled PID can have smaller
                        // counters than the stale entry, which would underflow.
                        auto it = g_prevRead.find(pid);
                        if (it != g_prevRead.end() && io.ReadTransferCount >= it->second)
                            readMBps = std::max(0.0, R2((io.ReadTransferCount - it->second) / elapsed / 1048576.0));
                        it = g_prevWrite.find(pid);
                        if (it != g_prevWrite.end() && io.WriteTransferCount >= it->second)
                            writeMBps = std::max(0.0, R2((io.WriteTransferCount - it->second) / elapsed / 1048576.0));
                        g_prevRead[pid] = io.ReadTransferCount;
                        g_prevWrite[pid] = io.WriteTransferCount;
                    }
                    CloseHandle(h);
                }

                ProcInfo pi;
                pi.pid = pid; pi.name = pname; pi.path = fullPath;
                pi.cpu = cpu; pi.mem = memMb;
                pi.readMBps = readMBps; pi.writeMBps = writeMBps;
                bool hasWindow = windowPids.find((DWORD)pid) != windowPids.end();
                pi.isSystem = ComputeIsSystem(pid, pname, fullPath, sessId, hasWindow);
                pi.isNew = pidIsNew;
                if (pi.isSystem) sysCount++; else userCount++;
                list.push_back(pi);
            } while (Process32NextW(snap, &pe));
        }
        CloseHandle(snap);
    }

    if (g_prevCpu.size() > liveIds.size() + 32) {
        std::vector<int> dead;
        for (auto& kv : g_prevCpu)
            if (liveIds.find(kv.first) == liveIds.end()) dead.push_back(kv.first);
        for (int k : dead) { g_prevCpu.erase(k); g_prevRead.erase(k); g_prevWrite.erase(k); g_pathCache.erase(k); }
    }

    // Expire old "new process" highlights and drop PIDs that are gone.
    // (The very first sample marks nothing, so the whole list doesn't flash.)
    for (auto it = g_newProcs.begin(); it != g_newProcs.end(); ) {
        if (now >= it->second || liveIds.find(it->first) == liveIds.end())
            it = g_newProcs.erase(it);
        else
            ++it;
    }
    g_firstSample = false;
    g_prevLiveIds = liveIds;

    double rawCpu = std::min(100.0, R1(sumCpu));
    {
        std::lock_guard<std::mutex> lk(g_sync);
        g_cpuSamples.push(rawCpu);
        while (g_cpuSamples.size() > 3) g_cpuSamples.pop();
        double acc = 0; size_t n = 0;
        std::queue<double> tmp = g_cpuSamples;
        while (!tmp.empty()) { acc += tmp.front(); tmp.pop(); n++; }
        g_lastSysCpu = n ? R1(acc / n) : 0;
        g_lastMemUsed = memUsedMb; g_lastMemTot = memTotMb; g_lastMemPct = memPct;
        g_drives = drives;
        g_totalProcesses = total;
        g_userProcs = userCount; g_sysProcs = sysCount;
        g_allProcs = list;
        g_lastSample = now;
    }
}
static void SamplerLoop() {
    while (!g_samplerStop) {
        try { SampleProcesses(); } catch (...) {}
        for (int i = 0; i < 125 && !g_samplerStop; i++)
            std::this_thread::sleep_for(std::chrono::milliseconds(40)); // ~5s between samples
    }
}

// ---------------- filter / sort ----------------
static int HeaderLines() {
    std::lock_guard<std::mutex> lk(g_sync);
    return 8 + std::max(1, (int)g_drives.size());
}
// keepPid: INT_MIN (default) = keep the currently selected process;
// -1 = no pinning (selection resets to the top); any other value = pin that PID.
static bool g_pinSelection = false;   // set once the user moves the cursor
static void ApplyFilterAndSort(int keepPid = INT_MIN) {
    if (keepPid == -1) g_pinSelection = false;   // explicit reset also unpins
    int anchor = keepPid;
    if (anchor == INT_MIN) {
        int n = (int)g_fullList.size();
        anchor = (g_selected >= 0 && g_selected < n) ? g_fullList[g_selected].pid : -1;
    }

    std::vector<ProcInfo> src;
    { std::lock_guard<std::mutex> lk(g_sync); src = g_allProcs; }

    std::vector<ProcInfo> list;
    list.reserve(src.size());
    for (auto& x : src) {
        if (!g_showAll && x.isSystem) continue;
        if (!MatchesFilter(x, g_filter)) continue;
        list.push_back(x);
    }
    std::wstring sb = g_sortBy; bool desc = g_sortDesc;
    std::sort(list.begin(), list.end(), [&](const ProcInfo& a, const ProcInfo& b) {
        int cmp = 0;
        if (sb == L"MEM") cmp = (a.mem < b.mem) ? -1 : (a.mem > b.mem) ? 1 : 0;
        else if (sb == L"PID") cmp = (a.pid < b.pid) ? -1 : (a.pid > b.pid) ? 1 : 0;
        else if (sb == L"NAME") {
            std::wstring x = ToLower(a.name), y = ToLower(b.name);
            cmp = (x < y) ? -1 : (x > y) ? 1 : 0;
        }
        else if (sb == L"READ") cmp = (a.readMBps < b.readMBps) ? -1 : (a.readMBps > b.readMBps) ? 1 : 0;
        else if (sb == L"WRITE") cmp = (a.writeMBps < b.writeMBps) ? -1 : (a.writeMBps > b.writeMBps) ? 1 : 0;
        else cmp = (a.cpu < b.cpu) ? -1 : (a.cpu > b.cpu) ? 1 : 0;
        return desc ? (cmp > 0) : (cmp < 0);
    });
    g_fullList = list;

    int ww, wh; GetWinSize(ww, wh);
    int maxRows = std::max(3, wh - HeaderLines() - 2);
    int count = (int)g_fullList.size();

    // Pin the selected process at its current row: the list keeps auto-sorting
    // around it, but the process you arrowed to never slides out from under
    // the cursor, so kill always hits the process you picked. 'c' unpins.
    if (anchor >= 0 && g_pinSelection && count > 0) {
        int from = -1;
        for (int i = 0; i < count; i++)
            if (g_fullList[i].pid == anchor) { from = i; break; }
        if (from >= 0) {
            int at = g_selected;
            if (at < 0) at = 0;
            if (at >= count) at = count - 1;
            if (from != at) {
                ProcInfo pinned = g_fullList[from];
                g_fullList.erase(g_fullList.begin() + from);
                g_fullList.insert(g_fullList.begin() + at, pinned);
            }
            g_selected = at;
            if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
            if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
            return;
        }
        // That process exited or got filtered out: fall through to clamping.
    }
    if (g_scrollOffset > std::max(0, count - maxRows)) g_scrollOffset = std::max(0, count - maxRows);
    if (g_selected >= count) g_selected = std::max(0, count - 1);
    if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
    if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
}

// ---------------- draw ----------------
// LineBuilder: colored segments, then pad to full width. Tracks visible width
// itself (no cursor reads), so wrapped-line weirdness cannot break padding.
struct LB {
    int col = 0, winW = 80;
    void seg(const std::wstring& s, int fg, int bg) { Colors(fg, bg); W(s); col += (int)s.size(); }
    void pad() {
        if (col < winW) { W(std::wstring((size_t)(winW - col), L' ')); col = winW; }
    }
    void nl() { W(L"\r\n"); col = 0; }
};
static void WriteHeaderCell(LB& lb, const std::wstring& text, const std::wstring& sortKey, int width) {
    bool active = (ToLower(g_sortBy) == ToLower(sortKey));
    lb.seg(PadR(text, (size_t)width), C_BLACK, active ? C_YELLOW : C_DGRAY);
}

static void Draw() {
    int rawW, rawH; GetWinSize(rawW, rawH);
    if (rawW < 70 || rawH < 14) {
        GotoXY(0, 0);
        Colors(C_YELLOW, C_BLACK);
        wchar_t b[128];
        swprintf(b, 128, L"Window too small - make it larger to use %s.", APPNAME);
        WL(b);
        swprintf(b, 128, L"Need at least 70x14, have %dx%d.", rawW, rawH);
        WL(b);
        SetDrawColors();
        return;
    }
    int winW = std::max(70, rawW - 1);
    int winH = std::max(14, rawH);
    GotoXY(0, 0);

    double sysCpu, memUsed, memTot, memPct; int totalProcs, userProcs;
    std::vector<DriveInfo2> drives;
    {
        std::lock_guard<std::mutex> lk(g_sync);
        sysCpu = g_lastSysCpu; memUsed = g_lastMemUsed; memTot = g_lastMemTot;
        memPct = g_lastMemPct; totalProcs = g_totalProcesses; userProcs = g_userProcs; drives = g_drives;
    }

    LB lb; lb.winW = winW;
    std::wstring mode = g_showAll ? L"ALL" : L"USER";

    // Title
    {
        std::wstring t = L"  " + std::wstring(APPNAME) + L"  " + NowHM() +
                          (g_paused ? L"  [PAUSED]" : L"") + L"  [" + mode + L"]";
        lb.seg(PadR(t, (size_t)winW), C_WHITE, C_DBLUE);
        SetDrawColors(); lb.nl();
    }
    // Host line
    {
        std::wstring h = L"  Host " + g_host + L"   User " + g_user + L"   Uptime " + FormatUptime();
        lb.seg(PadR(h, (size_t)winW), C_CYAN, C_BLACK); lb.nl();
        lb.seg(std::wstring((size_t)winW, L' '), C_GRAY, C_BLACK); lb.nl();
    }
    // CPU / MEM / Disks — every '[' starts at the same column.
    {
        lb.seg(L"  CPU  ", C_GREEN, C_BLACK);
        int fg = sysCpu >= 80 ? C_RED : sysCpu >= 50 ? C_YELLOW : C_GREEN;
        lb.seg(L"[" + MakeBar(sysCpu) + L"]", fg, C_BLACK);
        wchar_t b[128];
        swprintf(b, 128, L" %5.1f%%  %d CPU  procs %d", sysCpu,
                 []() { SYSTEM_INFO si; GetSystemInfo(&si); return (int)si.dwNumberOfProcessors; }(),
                 g_showAll ? totalProcs : userProcs);
        lb.seg(b, C_GREEN, C_BLACK); lb.pad(); SetDrawColors(); lb.nl();
    }
    {
        lb.seg(L"  Mem  ", C_CYAN, C_BLACK);
        int fg = memPct >= 80 ? C_RED : memPct >= 50 ? C_YELLOW : C_CYAN;
        lb.seg(L"[" + MakeBar(memPct) + L"]", fg, C_BLACK);
        wchar_t b[128];
        swprintf(b, 128, L" %5.1f%%  %.1f / %.1f GB", memPct, memUsed / 1024.0, memTot / 1024.0);
        lb.seg(b, C_CYAN, C_BLACK); lb.pad(); SetDrawColors(); lb.nl();
    }
    lb.seg(L"  Disks", C_MAG, C_BLACK); lb.pad(); SetDrawColors(); lb.nl();
    if (drives.empty()) {
        lb.seg(PadR(L"  (scanning...)", (size_t)winW), C_GRAY, C_BLACK); lb.nl();
    } else {
        for (auto& d : drives) {
            int fg = d.pct >= 90 ? C_RED : d.pct >= 75 ? C_YELLOW : C_MAG;
            wchar_t lab[16]; swprintf(lab, 16, L"  %-3s  ", d.name.c_str());
            lb.seg(lab, fg, C_BLACK);
            lb.seg(L"[" + MakeBar(d.pct) + L"]", fg, C_BLACK);
            wchar_t b[128];
            swprintf(b, 128, L" %5.1f%%  %s", d.pct, FormatDiskPair(d.usedGb, d.totGb).c_str());
            lb.seg(b, fg, C_BLACK); lb.pad(); SetDrawColors(); lb.nl();
        }
    }
    lb.seg(std::wstring((size_t)winW, L'-'), C_DGRAY, C_BLACK); lb.nl();
    SetDrawColors();

    // Column headers
    lb.seg(L"  ", C_GRAY, C_BLACK);
    WriteHeaderCell(lb, L"PID", L"PID", 6); lb.seg(L" ", C_GRAY, C_BLACK);
    WriteHeaderCell(lb, L"CPU%", L"CPU", 6); lb.seg(L" ", C_GRAY, C_BLACK);
    WriteHeaderCell(lb, L"MEM(MB)", L"MEM", 8); lb.seg(L" ", C_GRAY, C_BLACK);
    WriteHeaderCell(lb, L"R-MB/s", L"READ", 7); lb.seg(L" ", C_GRAY, C_BLACK);
    WriteHeaderCell(lb, L"W-MB/s", L"WRITE", 7); lb.seg(L" ", C_GRAY, C_BLACK);
    WriteHeaderCell(lb, L"Name", L"NAME", 18); lb.seg(L" ", C_GRAY, C_BLACK);
    int pathWidth = std::max(8, winW - 62);
    WriteHeaderCell(lb, L"Path", L"NAME", pathWidth);
    SetDrawColors(); lb.nl();

    int headerLines = 8 + std::max(1, (int)drives.size());
    int maxRows = std::max(3, winH - headerLines - 2);
    int pathMax = std::max(8, winW - 62);
    int count = (int)g_fullList.size();

    int linesWritten = headerLines;
    for (int i = 0; i < maxRows && g_scrollOffset + i < count; i++) {
        const ProcInfo& pr = g_fullList[g_scrollOffset + i];
        int realIdx = g_scrollOffset + i;
        std::wstring nameShow = pr.name.size() > 18 ? pr.name.substr(0, 15) + L"..." : pr.name;
        std::wstring pathShow = pr.path.size() > (size_t)pathMax
            ? L"..." + pr.path.substr(pr.path.size() - pathMax + 3) : pr.path;
        wchar_t b[64];
        swprintf(b, 64, L"%6d %6.1f %8.1f %7.2f %7.2f ", pr.pid, pr.cpu, pr.mem, pr.readMBps, pr.writeMBps);
        std::wstring line = L"  " + std::wstring(b) + PadR(nameShow, 18) + L" " + pathShow;
        line = PadR(line, (size_t)winW);
        if (realIdx == g_selected) lb.seg(line, C_BLACK, C_CYAN);
        else if (pr.isNew) lb.seg(line, C_GREEN, C_BLACK);
        else if (pr.isSystem) lb.seg(line, C_DGRAY, C_BLACK);
        else {
            int fg = pr.cpu >= 40 ? C_RED : pr.cpu >= 10 ? C_YELLOW : C_GRAY;
            lb.seg(line, fg, C_BLACK);
        }
        lb.nl();
        linesWritten++;
    }

    bool atEnd = g_scrollOffset + std::min(maxRows, count - g_scrollOffset) >= count;
    if (atEnd && count > 0) {
        lb.seg(PadR(L"  -- end of processes --", (size_t)winW), C_DGRAY, C_BLACK);
        lb.nl(); linesWritten++;
    }

    // Fill remaining lines — the terminal never scrolls.
    int left = winH - 1 - linesWritten;
    if (left < 0) left = 0;
    Colors(C_BLACK, C_BLACK);
    for (int j = 0; j < left; j++) WL(std::wstring((size_t)winW, L' '));
    SetDrawColors();

    // Scrollbar on the right edge of the process area.
    {
        int listTop = headerLines, listH = maxRows;
        int thumbH = count <= listH ? listH : std::max(1, (int)std::round((double)listH * listH / count));
        int maxStart = std::max(0, listH - thumbH);
        int thumbStart = 0;
        if (count > listH && count > listH)
            thumbStart = (int)std::round((double)g_scrollOffset / (count - listH) * maxStart);
        if (thumbStart < 0) thumbStart = 0;
        if (thumbStart > maxStart) thumbStart = maxStart;
        for (int r = 0; r < listH; r++) {
            int row = listTop + r;
            if (row >= winH - 1) break;
            GotoXY(winW - 1, row);
            bool isThumb = r >= thumbStart && r < thumbStart + thumbH;
            Colors(isThumb ? C_GRAY : C_DGRAY, C_BLACK);
            W(isThumb ? L"\u2588" : L"\u2502");
        }
        SetDrawColors();
    }

    // Status bar on the last line: state first, then hotkeys most-used-first.
    // An item is either fully shown or dropped, never cut in half.
    {
        std::vector<std::pair<std::wstring, int>> pieces;
        if (!g_filter.empty()) {
            std::wstring fs = g_filter.size() > 12 ? g_filter.substr(0, 12) + L".." : g_filter;
            pieces.push_back({ L"find:'" + fs + L"'", C_YELLOW });
        }
        pieces.push_back({ L"q=quit", C_BLACK });
        pieces.push_back({ L"space=pause", C_BLACK });
        pieces.push_back({ L"/=find", C_BLACK });
        pieces.push_back({ L"<->=sort", C_BLACK });
        pieces.push_back({ L"k=kill", C_BLACK });
        pieces.push_back({ L"P=all/user", C_BLACK });
        pieces.push_back({ L"r=reverse", C_BLACK });
        pieces.push_back({ L"c=clear", C_BLACK });
        pieces.push_back({ L"h=help", C_BLACK });
        GotoXY(0, winH - 1);
        Colors(C_BLACK, C_DCYAN);
        int col = 0;
        for (size_t i = 0; i < pieces.size(); i++) {
            std::wstring add = (col == 0 ? pieces[i].first : L"  " + pieces[i].first);
            if (col + (int)add.size() > winW) break;
            Colors(pieces[i].second, C_DCYAN);
            W(add);
            col += (int)add.size();
        }
        Colors(C_BLACK, C_DCYAN);
        if (col < winW) W(std::wstring((size_t)(winW - col), L' '));
        SetDrawColors();
    }
}

// ---------------- actions ----------------
static void CycleSort(int direction) {
    int idx = 0;
    for (int i = 0; i < 6; i++)
        if (g_sortBy == SORT_COLUMNS[i]) { idx = i; break; }
    idx = (idx + direction + 6) % 6;
    g_sortBy = SORT_COLUMNS[idx];
    // Each column gets its natural direction on landing: names A-Z,
    // everything else highest-value-first.
    g_sortDesc = (g_sortBy != L"NAME");
    ApplyFilterAndSort();
    SaveSettings();
    g_needRedraw = true;
}

static std::wstring ReadConfirm(const std::wstring& prompt, int winW) {
    std::wstring sb;
    int ww, wh; GetWinSize(ww, wh);
    ShowCursor(true);
    while (true) {
        std::wstring full = PadR(prompt + sb + L"_", (size_t)winW);
        GotoXY(0, wh - 1);
        Colors(C_WHITE, C_DRED); W(full); SetDrawColors();
        int k = ReadKey();
        if (k == 13) { ShowCursor(false); return Trim(sb); }
        if (k == 27) { ShowCursor(false); return L""; }
        if (k == 8) { if (!sb.empty()) sb.pop_back(); }
        else if (k < 0x100 && !iswcntrl((wint_t)k)) sb.push_back((wchar_t)k);
    }
}

static void KillAsync(const std::vector<int>& pids) {
    std::thread([pids]() {
        for (int id : pids) {
            if ((DWORD)id == g_ownPid) continue;
            HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)id);
            if (h) { TerminateProcess(h, 1); CloseHandle(h); }
        }
    }).detach();
}

static void DoKillConfirm() {
    int count = (int)g_fullList.size();
    if (count == 0 || g_selected < 0 || g_selected >= count) return;
    ProcInfo pr = g_fullList[g_selected];
    int ww, wh; GetWinSize(ww, wh);
    int winW = std::max(70, ww - 1);
    bool multi = !g_filter.empty() && count > 1;
    bool anyProtected = false;
    if (multi) { for (auto& x : g_fullList) if (IsProtected(x)) { anyProtected = true; break; } }
    else anyProtected = IsProtected(pr);

    std::wstring msg;
    if (multi) {
        wchar_t b[128];
        swprintf(b, 128, L"Kill (s)elected %d or (a)ll %d? s/a/n: ", pr.pid, count);
        msg = b;
    } else {
        wchar_t b[160];
        swprintf(b, 160, L"Kill PID %d (%s)? y/n: ", pr.pid, pr.name.c_str());
        msg = b;
    }
    msg = PadR(msg, (size_t)winW);
    GotoXY(0, wh - 1);
    Colors(C_WHITE, C_DRED); W(msg); SetDrawColors();

    ShowCursor(true);
    int k = ReadKey();
    ShowCursor(false);

    bool doSingle = false, doAll = false;
    if (multi) {
        if (k == 's' || k == 'S') doSingle = true;
        else if (k == 'a' || k == 'A') doAll = true;
        else { g_needRedraw = true; return; }
    } else {
        if (k == 'y' || k == 'Y') doSingle = true;
        else { g_needRedraw = true; return; }
    }

    if (doSingle) {
        if ((DWORD)pr.pid == g_ownPid) { g_needRedraw = true; return; }
        if (IsProtected(pr)) {
            wchar_t b[128];
            swprintf(b, 128, L"CRITICAL system process! Type KILL to confirm PID %d: ", pr.pid);
            std::wstring conf = ReadConfirm(b, winW);
            if (ToLower(conf) != L"kill") { g_needRedraw = true; return; }
        }
        KillAsync(std::vector<int>{ pr.pid });
        g_nextRefresh = std::chrono::steady_clock::now();
    } else if (doAll) {
        std::wstring conf;
        if (count > 50 || anyProtected || g_filter.empty() || g_filter == L"*") {
            wchar_t b[160];
            swprintf(b, 160, L"DANGER: kill ALL %d matching '%s'? Type YES: ", count, g_filter.c_str());
            conf = ReadConfirm(b, winW);
        } else {
            wchar_t b[128];
            swprintf(b, 128, L"Confirm kill ALL %d? Type YES: ", count);
            conf = ReadConfirm(b, winW);
        }
        if (ToLower(conf) != L"yes") { g_needRedraw = true; return; }

        std::vector<int> toKill;
        for (auto& item : g_fullList) {
            if ((DWORD)item.pid == g_ownPid) continue;
            if (IsProtected(item)) {
                wchar_t b[160];
                swprintf(b, 160, L"Skip critical %s (PID %d)? y=skip n=force: ",
                         item.name.c_str(), item.pid);
                std::wstring c2 = ReadConfirm(b, winW);
                if (ToLower(c2) == L"n" || ToLower(c2) == L"kill") {
                    swprintf(b, 160, L"FORCE kill critical %s? Type KILL: ", item.name.c_str());
                    std::wstring c3 = ReadConfirm(b, winW);
                    if (ToLower(c3) != L"kill") continue;
                    toKill.push_back(item.pid);
                }
                continue;
            }
            toKill.push_back(item.pid);
        }
        KillAsync(toKill);
        g_nextRefresh = std::chrono::steady_clock::now();

        // Clear filter after mass kill
        g_filter.clear();
        g_selected = 0;
        g_scrollOffset = 0;
        ApplyFilterAndSort(-1);
    }
    g_needRedraw = true;
}

static void DoSearch() {
    int ww, wh; GetWinSize(ww, wh);
    int winW = std::max(70, ww - 1);
    std::wstring sb = g_filter;
    ShowCursor(true);
    while (true) {
        g_filter = sb;
        g_selected = 0;
        g_scrollOffset = 0;
        ApplyFilterAndSort(-1);
        Draw();

        std::wstring prompt = PadR(L"LIVE SEARCH (* ok  Esc=cancel  Enter=done) > " + sb + L"_",
                                   (size_t)winW);
        GotoXY(0, wh - 1);
        Colors(C_BLACK, C_DYELLOW); W(prompt); SetDrawColors();

        int k = ReadKey();
        if (k == 13) { g_filter = Trim(sb); break; }
        if (k == 27) { g_filter.clear(); break; }
        if (k == 8) { if (!sb.empty()) sb.pop_back(); }
        else if (k < 0x100 && !iswcntrl((wint_t)k)) sb.push_back((wchar_t)k);
    }
    ShowCursor(false);
    ApplyFilterAndSort(-1);
    g_nextRefresh = std::chrono::steady_clock::now();
    g_needRedraw = true;
}

static void DoRun() {
    int ww, wh; GetWinSize(ww, wh);
    int winW = std::max(70, ww - 1);
    std::wstring sb;
    ShowCursor(true);
    while (true) {
        std::wstring prompt = PadR(L"CONSOLE RUN (Esc=cancel Enter=start) > " + sb, (size_t)winW);
        GotoXY(0, wh - 1);
        Colors(C_BLACK, C_DGREEN); W(prompt); SetDrawColors();

        int k = ReadKey();
        if (k == 13) {
            std::wstring cmd = Trim(sb);
            if (!cmd.empty()) {
                HINSTANCE r = ShellExecuteW(NULL, L"open", cmd.c_str(), NULL, NULL, SW_SHOWNORMAL);
                if ((INT_PTR)r <= 32) {
                    wchar_t b[256];
                    swprintf(b, 256, L"ERROR: could not start '%s' (code %d)",
                             cmd.c_str(), (int)(INT_PTR)r);
                    std::wstring err = PadR(b, (size_t)winW);
                    GotoXY(0, wh - 1);
                    Colors(C_WHITE, C_DRED); W(err); SetDrawColors();
                    std::this_thread::sleep_for(std::chrono::milliseconds(2000));
                }
            }
            g_nextRefresh = std::chrono::steady_clock::now();
            break;
        }
        if (k == 27) break;
        if (k == 8) { if (!sb.empty()) sb.pop_back(); }
        else if (k < 0x100 && !iswcntrl((wint_t)k)) sb.push_back((wchar_t)k);
    }
    ShowCursor(false);
    g_needRedraw = true;
}

static void ShowHelp() {
    ClearAll();
    SetDrawColors();
    WL(L"WinTop keys");
    WL(L"  Up/Down        move selection");
    WL(L"  PageUp/PageDn  jump one page");
    WL(L"  Home/End       jump to first/last");
    WL(L"  Left/Right     change sort column");
    WL(L"                 (Name always starts A?Z)");
    WL(L"  r              reverse current sort");
    WL(L"  s              next sort column");
    WL(L"  Space          pause/resume");
    WL(L"  / or F3        live search (* ok)");
    WL(L"  P              toggle All/User processes");
    WL(L"  k / F9         kill selected");
    WL(L"  c / Esc        clear filter");
    WL(L"  Arrows pin the selected process at its row; c unpins.");
    WL(L"  New processes flash green, like Process Explorer.");
    WL(L"  Ctrl+R         console run (start a program)");
    WL(L"  q / F10        quit");
    WL(L"");
    WL(L"Press any key...");
    ReadKey();
    ClearAll();
    g_needRedraw = true;
}

static void HandleKey() {
    int key = ReadKey();
    if (key == 18) { DoRun(); return; }   // Ctrl+R

    int ww, wh; GetWinSize(ww, wh);
    int maxRows = std::max(3, wh - HeaderLines() - 2);
    int count = (int)g_fullList.size();

    switch (key) {
    case 'q': case 'Q': case K_F10:
        g_running = false;
        break;
    case 27: // Esc
        if (!g_filter.empty()) {
            g_filter.clear(); g_selected = 0; g_scrollOffset = 0;
            ApplyFilterAndSort(-1); g_needRedraw = true;
        }
        break;
    case 32: // Space
        g_paused = !g_paused;
        g_needRedraw = true;
        if (!g_paused) g_nextRefresh = std::chrono::steady_clock::now();
        break;
    case K_UP:
        g_pinSelection = true;   // any arrow-key navigation pins the selection
        if (g_selected > 0) {
            g_selected--;
            if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
            g_needRedraw = true;
        }
        break;
    case K_DOWN:
        g_pinSelection = true;
        if (g_selected < count - 1) {
            g_selected++;
            if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
            g_needRedraw = true;
        }
        break;
    case K_PGUP:
        g_pinSelection = true;
        g_selected = std::max(0, g_selected - maxRows);
        if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
        g_needRedraw = true;
        break;
    case K_PGDN:
        g_pinSelection = true;
        g_selected = std::max(0, std::min(count - 1, g_selected + maxRows));
        if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
        g_needRedraw = true;
        break;
    case K_HOME:
        g_pinSelection = true;
        g_selected = 0; g_scrollOffset = 0; g_needRedraw = true;
        break;
    case K_END:
        g_pinSelection = true;
        g_selected = std::max(0, count - 1);
        g_scrollOffset = std::max(0, count - maxRows);
        g_needRedraw = true;
        break;
    case K_LEFT:
        CycleSort(-1);
        break;
    case K_RIGHT:
        CycleSort(1);
        break;
    case 'k': case 'K': case K_F9:
        DoKillConfirm();
        break;
    case '/': case K_F3:
        DoSearch();
        break;
    case 's': case 'S': case K_F6:
        CycleSort(1);
        break;
    case 'r': case 'R':
        g_sortDesc = !g_sortDesc;
        ApplyFilterAndSort();
        SaveSettings();
        g_needRedraw = true;
        break;
    case 'c': case 'C':
        g_filter.clear(); g_selected = 0; g_scrollOffset = 0;
        ApplyFilterAndSort(-1); g_needRedraw = true;
        break;
    case 'p': case 'P':
        g_showAll = !g_showAll;
        g_selected = 0; g_scrollOffset = 0;
        ApplyFilterAndSort(-1);
        SaveSettings();
        g_needRedraw = true;
        break;
    case 'h': case 'H': case K_F1:
        ShowHelp();
        break;
    }
}

int wmain(int argc, wchar_t** argv) {
    (void)argc; (void)argv;
    hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    hIn = GetStdHandle(STD_INPUT_HANDLE);
    g_ownPid = GetCurrentProcessId();
    SetConsoleTitleW(APPNAME);
    ShowCursor(false);

    wchar_t host[256] = { 0 }; DWORD hsz = 256;
    GetComputerNameW(host, &hsz);
    g_host = host;
    wchar_t user[256] = { 0 }, dom[256] = { 0 };
    GetEnvironmentVariableW(L"USERNAME", user, 256);
    GetEnvironmentVariableW(L"USERDOMAIN", dom, 256);
    g_user = std::wstring(dom) + L"\\" + user;

    // Remember the original scrollback buffer so we can restore it on exit,
    // then lock the buffer to the window: no scrollbar, no scroll history.
    {
        CONSOLE_SCREEN_BUFFER_INFO bi;
        if (GetConsoleScreenBufferInfo(hOut, &bi)) {
            g_origBufW = bi.dwSize.X; g_origBufH = bi.dwSize.Y;
            g_origAttr = bi.wAttributes;
        }
    }
    FitBufferToWindow();
    DisableQuickEdit();

    // Remember the console's original colors, then switch to our own palette
    // and paint the whole buffer with it (stops the host's dark-blue bleed).
    SetDrawColors();
    ClearAll();

    LoadSettings();
    g_lastSample = std::chrono::steady_clock::now();

    // Sample once on this thread BEFORE the sampler thread starts: the
    // previous-sample maps are plain (non-atomic) structures, so two threads
    // must never touch them at the same time.
    try { SampleProcesses(); } catch (...) {}
    g_samplerStop = false;
    std::thread sampler(SamplerLoop);
    g_nextRefresh = std::chrono::steady_clock::now();

    ApplyFilterAndSort();
    try { Draw(); } catch (...) {}
    g_needRedraw = false;

    int code = 0;
    try {
        while (g_running) {
            int ww, wh; GetWinSize(ww, wh);
            if (ww != g_lastWinW || wh != g_lastWinH) {
                g_lastWinW = ww; g_lastWinH = wh;
                FitBufferToWindow();
                // Wipe on resize: narrowing can leave wrapped remnants past the
                // new width that a repaint would not cover.
                ClearAll();
                g_needRedraw = true;
            }
            while (_kbhit()) HandleKey();
            auto now = std::chrono::steady_clock::now();
            if (!g_paused && now >= g_nextRefresh) {
                ApplyFilterAndSort();
                g_nextRefresh = now + std::chrono::seconds(5);
                g_needRedraw = true;
            }
            if (g_needRedraw) {
                try { Draw(); } catch (...) {}
                g_needRedraw = false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
        }
    } catch (const std::exception& ex) {
        Colors(C_RED, C_BLACK);
        char mb[512];
        snprintf(mb, sizeof(mb), "Fatal: %s", ex.what());
        DWORD w = 0;
        WriteConsoleA(hOut, mb, (DWORD)strlen(mb), &w, NULL);
        W(L"\r\n");
        SetDrawColors();
        code = 1;
    } catch (...) {
        code = 1;
    }

    ShowCursor(true);
    g_samplerStop = true;
    if (sampler.joinable()) sampler.join();
    // Persist preferences, then restore the console to how we found it:
    // original colors, original buffer size, clean screen.
    SaveSettings();
    RestoreConsoleMode();
    Colors(g_origAttr & 0xF, (g_origAttr >> 4) & 0xF);
    if (g_bufferLocked) {
        COORD sz; sz.X = (SHORT)g_origBufW; sz.Y = (SHORT)g_origBufH;
        SetConsoleScreenBufferSize(hOut, sz);
    }
    ClearAll();
    Colors(g_origAttr & 0xF, (g_origAttr >> 4) & 0xF);

    WL(L"");
    Colors(C_GREEN, (g_origAttr >> 4) & 0xF);
    std::wstring done = std::wstring(APPNAME) + L" ended. Press any key to close...";
    WL(done);
    Colors(g_origAttr & 0xF, (g_origAttr >> 4) & 0xF);
    DWORD cm = 0;
    if (!GetConsoleMode(hIn, &cm)) {
        std::wstring dummy;   // input redirected: read a line instead of a key
        std::getline(std::wcin, dummy);
    } else {
        ReadKey();
    }
    return code;
}
'@
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
$ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set on this machine.'}
$ProjectDir=Join-Path $BaseDir $ProjectName
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' (native C++ console app, zero .NET)" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Initialize-Tls
$Script:StageName='Environment checks'
Write-Stage '1/7' 'Initializing TLS and checking free disk space'
Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced."
Test-DiskSpace -Path $BaseDir
$Script:StageName='Clean slate'
Write-Stage '2/7' "Preparing a clean workspace: $ProjectDir"
if(Test-Path -LiteralPath $ProjectDir){Write-Info 'Existing project folder found; destroying it completely for a clean slate...';if(-not (Remove-Folder -Path $ProjectDir)){Write-Err2 "Could not delete '$ProjectDir' after repeated attempts.";Write-Err2 'Usual culprits: the folder is open in an editor, terminal or Explorer window, an antivirus scan holds a lock, OneDrive is syncing, or an app from a previous run is still running.';Write-Err2 'Next step: close everything that uses this folder (or reboot) and run the script again.';exit 7}Write-Ok 'Old project folder removed and verified gone.'}
try{[void][IO.Directory]::CreateDirectory($BaseDir)}catch{Throw-Code 7 "Could not create base directory '$BaseDir': $($_.Exception.Message)"}
try{[void][IO.Directory]::CreateDirectory($ProjectDir)}catch{Throw-Code 7 "Could not create project directory '$ProjectDir': $($_.Exception.Message)"}
if(-not (Test-Path -LiteralPath $ProjectDir)){Throw-Code 7 "Project directory '$ProjectDir' could not be created or verified."}
Write-Ok 'Fresh, empty project directory is ready.'
$Script:StageName='Compiler detection/install'
Write-Stage '3/7' 'Detecting a C++ compiler (MSVC, g++, or portable Zig)'
$Script:Compiler=Find-Compiler
Write-Ok "Using: $($Script:Compiler.Desc)"
$Script:StageName='Writing sources'
Write-Stage '4/7' 'Writing the C++ application sources'
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName
Write-Ok 'Application sources written.'
$Script:StageName='Build'
Write-Stage '5/7' "Compiling with $($Script:Compiler.Kind) (Release, optimized)"
if($Script:Compiler.Kind -eq 'msvc'){Build-WithMsvc -C $Script:Compiler -Dir $ProjectDir -Name $ProjectName}
elseif($Script:Compiler.Kind -eq 'zig'){Build-WithZig -C $Script:Compiler -Dir $ProjectDir -Name $ProjectName}
else{Build-WithGcc -C $Script:Compiler -Dir $ProjectDir -Name $ProjectName}
Write-Ok 'Build completed with exit code 0.'
$Script:StageName='Artifact verification'
Write-Stage '6/7' 'Verifying the built executable and stamping the icon'
$exe=Join-Path $ProjectDir ($ProjectName+'.exe')
if(-not (Test-Path -LiteralPath $exe)){Start-Sleep -Seconds 3}
if(-not (Test-Path -LiteralPath $exe)){Throw-Code 5 "Build reported success but '$exe' does not exist. Antivirus may have quarantined it."}
$size=(Get-Item -LiteralPath $exe).Length
if($size -lt 100KB){Throw-Code 5 "The built exe is only $size bytes - far too small; the link step must have failed."}
$sizeMb=[math]::Round($size/1MB,1)
Write-Ok "Executable verified: $exe ($sizeMb MB)"
Set-ExeIcon -Exe $exe
$Script:StageName='Launch'
if($NoLaunch){Write-Stage '7/7' 'Auto-launch skipped (-NoLaunch was provided)';Write-Info "Run the app anytime by double-clicking: $exe"}
else{Write-Stage '7/7' 'Launching the freshly built application';if(-not (Start-BuiltApp -Exe $exe -WorkDir $ProjectDir)){exit 6}}
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '  SUCCESS - application built, verified and ready' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Ok "Project folder : $ProjectDir"
Write-Ok "Executable     : $exe ($sizeMb MB)"
Write-Ok "Compiler       : $($Script:Compiler.Desc)"
Write-Ok ("Elapsed time   : {0:hh\:mm\:ss}" -f $sw.Elapsed)
Write-Ok 'Native exe: runs on any Windows 10/11/Server 2016+ x64 machine, no .NET needed.'
exit 0
}
catch{$code=1;if($_.Exception.Message -match '^\[(\d)\]'){$code=[int]$Matches[1]};Write-Host '';Write-Err2 "FAILED during stage: $($Script:StageName)";Write-Err2 "Error: $($_.Exception.Message)";Write-Err2 'Likely cause: the issue named above (no internet, proxy/TLS blocking, antivirus, locked folder, missing permissions or low disk space).';Write-Err2 'Next step: fix that issue and run this script again - it always starts from a clean slate.';exit $code}
