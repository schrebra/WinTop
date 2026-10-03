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
function Write-SourceFiles([string]$Dir,[string]$Name,[bool]$WantIcon){
  $utf8NoBom=New-Object System.Text.Utf8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $Dir ($Name+'.cpp')),$cppCode.Replace('__APPNAME__',$Name),$utf8NoBom)
  if($WantIcon){
    if($PSScriptRoot){
      $icoSrc=Join-Path $PSScriptRoot 'wintop.ico'
      if(Test-Path -LiteralPath $icoSrc){Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $Dir 'wintop.ico') -Force;Write-Ok 'Embedded your wintop.ico as the application icon.'}
    }
    [IO.File]::WriteAllText((Join-Path $Dir ($Name+'.rc')),'1 ICON "wintop.ico"'+[Environment]::NewLine,[Text.Encoding]::ASCII)
  }
}
function Build-WithMsvc([hashtable]$C,[string]$Dir,[string]$Name,[bool]$HasRc){
  $lines=New-Object Collections.Generic.List[string]
  if($C.VcVars){$lines.Add('call "'+$C.VcVars+'" >NUL')}
  if($HasRc){$lines.Add('rc /nologo "'+$Name+'.rc"');$lines.Add('if errorlevel 1 exit /b 1')}
  $res=if($HasRc){' "'+$Name+'.res"'}else{''}
  $lines.Add('cl /nologo /O2 /EHsc /std:c++17 /utf-8 /DUNICODE /D_UNICODE "'+$Name+'.cpp"'+$res+' /Fe:"'+$Name+'.exe"')
  $lines.Add('if errorlevel 1 exit /b 1')
  [IO.File]::WriteAllLines((Join-Path $Dir 'build.bat'),$lines,[Text.Encoding]::ASCII)
  Push-Location -LiteralPath $Dir
  try{& cmd.exe /c build.bat;if($LASTEXITCODE -ne 0){Throw-Code 5 "C++ compilation failed (exit code $LASTEXITCODE). See the compiler output above."}}
  finally{Pop-Location}
}
function Invoke-Gcc([string]$Exe,[string[]]$GccArgs,[string]$Dir){Push-Location -LiteralPath $Dir;try{& $Exe @GccArgs}finally{Pop-Location};return $LASTEXITCODE}
function Build-WithGcc([hashtable]$C,[string]$Dir,[string]$Name,[bool]$HasRc){
  $gccArgs=@('-O2','-std=c++17','-municode','-static','-static-libgcc','-static-libstdc++','-o',($Name+'.exe'),($Name+'.cpp'))
  if($HasRc){$gccArgs+=($Name+'.rc')}
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
$wantIcon=$false
if($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'wintop.ico'))){
  if($Script:Compiler.Kind -eq 'zig'){Write-Warn2 'Note: the Zig toolchain has no resource compiler, so wintop.ico will not be embedded this run (app still builds fine).'}
  else{$wantIcon=$true}
}
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName -WantIcon $wantIcon
Write-Ok 'Application sources written.'
$Script:StageName='Build'
Write-Stage '5/7' "Compiling with $($Script:Compiler.Kind) (Release, optimized)"
if($Script:Compiler.Kind -eq 'msvc'){Build-WithMsvc -C $Script:Compiler -Dir $ProjectDir -Name $ProjectName -HasRc $wantIcon}
elseif($Script:Compiler.Kind -eq 'zig'){Build-WithZig -C $Script:Compiler -Dir $ProjectDir -Name $ProjectName}
else{Build-WithGcc -C $Script:Compiler -Dir $ProjectDir -Name $ProjectName -HasRc $wantIcon}
Write-Ok 'Build completed with exit code 0.'
$Script:StageName='Artifact verification'
Write-Stage '6/7' 'Verifying the built executable'
$exe=Join-Path $ProjectDir ($ProjectName+'.exe')
if(-not (Test-Path -LiteralPath $exe)){Start-Sleep -Seconds 3}
if(-not (Test-Path -LiteralPath $exe)){Throw-Code 5 "Build reported success but '$exe' does not exist. Antivirus may have quarantined it."}
$size=(Get-Item -LiteralPath $exe).Length
if($size -lt 100KB){Throw-Code 5 "The built exe is only $size bytes - far too small; the link step must have failed."}
$sizeMb=[math]::Round($size/1MB,1)
Write-Ok "Executable verified: $exe ($sizeMb MB)"
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
