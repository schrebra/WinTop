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
  Write-Info 'No C compiler found on this machine.'
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
  # 3) gcc on PATH (MinGW-w64, msys2)
  $gxx=Get-Command gcc.exe -ErrorAction SilentlyContinue
  if($gxx){
    $prev=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$v=(& $gxx.Source --version 2>$null | Select-Object -First 1);if($LASTEXITCODE -eq 0){return @{Kind='gcc';Exe=$gxx.Source;Desc="gcc on PATH ($v)"}}}catch{}finally{$ErrorActionPreference=$prev}
  }
  # 4) portable Zig toolchain, downloaded user-local, zero elevation
  return Install-ZigToolchain
}
function Write-SourceFiles([string]$Dir,[string]$Name,[bool]$WantIcon){
  $utf8NoBom=New-Object System.Text.Utf8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $Dir ($Name+'.c')),$cCode.Replace('__APPNAME__',$Name),$utf8NoBom)
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
  $lines.Add('cl /nologo /O2 /utf-8 /DUNICODE /D_UNICODE "'+$Name+'.c"'+$res+' /Fe:"'+$Name+'.exe"')
  $lines.Add('if errorlevel 1 exit /b 1')
  [IO.File]::WriteAllLines((Join-Path $Dir 'build.bat'),$lines,[Text.Encoding]::ASCII)
  Push-Location -LiteralPath $Dir
  try{& cmd.exe /c build.bat;if($LASTEXITCODE -ne 0){Throw-Code 5 "C compilation failed (exit code $LASTEXITCODE). See the compiler output above."}}
  finally{Pop-Location}
}
function Invoke-Gcc([string]$Exe,[string[]]$GccArgs,[string]$Dir){Push-Location -LiteralPath $Dir;try{& $Exe @GccArgs}finally{Pop-Location};return $LASTEXITCODE}
function Build-WithGcc([hashtable]$C,[string]$Dir,[string]$Name,[bool]$HasRc){
  $gccArgs=@('-O2','-std=c17','-municode','-static','-static-libgcc','-o',($Name+'.exe'),($Name+'.c'))
  if($HasRc){$gccArgs+=($Name+'.rc')}
  $gccArgs+=@('-lpsapi')
  $code=Invoke-Gcc -Exe $C.Exe -GccArgs $gccArgs -Dir $Dir
  if($code -ne 0){
    Write-Warn2 "Static build failed (exit $code); retrying as a dynamic build..."
    $gccArgs2=@($gccArgs | Where-Object {$_ -notlike '-static*'})
    $code=Invoke-Gcc -Exe $C.Exe -GccArgs $gccArgs2 -Dir $Dir
    if($code -ne 0){Throw-Code 5 "C compilation failed (exit code $code). See the compiler output above."}
  }
}
function Build-WithZig([hashtable]$C,[string]$Dir,[string]$Name){
  Write-Info 'First Zig build compiles its bundled C runtime - can take a few minutes, then it is cached.'
  Push-Location -LiteralPath $Dir
  try{& $C.Exe cc -O2 -std=c17 -target x86_64-windows-gnu -municode -o ($Name+'.exe') ($Name+'.c') -lpsapi;if($LASTEXITCODE -ne 0){Throw-Code 5 "C compilation failed (exit code $LASTEXITCODE). See the compiler output above."}}
  finally{Pop-Location}
}
function Start-BuiltApp([string]$Exe,[string]$WorkDir){try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable itself is valid and complete - start it manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
# ----------------------------------------------------------------------------
# Embedded application source (native C, no .NET). __APPNAME__ is replaced
# with the project name when the sources are written out.
# ----------------------------------------------------------------------------
$cCode=@'
/* __APPNAME__.c - native C port of the WinTop terminal system monitor.
   Built by the WinTop PowerShell bootstrap with MSVC (cl), MinGW-w64 (gcc)
   or Zig (zig cc). No C++ runtime, no .NET: the exe runs anywhere. */

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <conio.h>
#include <wctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <math.h>
#include <limits.h>

#ifdef _MSC_VER
#pragma comment(lib, "psapi.lib")
#endif

static const wchar_t *APPNAME = L"__APPNAME__";

/* Console palette (same 16 colors as the C# ConsoleColor set). */
enum {
    C_BLACK = 0, C_DBLUE = 1, C_DGREEN = 2, C_DCYAN = 3, C_DRED = 4,
    C_DMAG = 5, C_DYELLOW = 6, C_GRAY = 7, C_DGRAY = 8, C_BLUE = 9,
    C_GREEN = 10, C_CYAN = 11, C_RED = 12, C_MAG = 13, C_YELLOW = 14, C_WHITE = 15
};

#define BAR_WIDTH 30
#define NEW_PROC_HIGHLIGHT_SECS 10

/* Special-key codes returned by read_key() (0x100 + scan code). */
enum {
    K_UP = 0x100 + 72, K_DOWN = 0x100 + 80, K_LEFT = 0x100 + 75, K_RIGHT = 0x100 + 77,
    K_HOME = 0x100 + 71, K_END = 0x100 + 79, K_PGUP = 0x100 + 73, K_PGDN = 0x100 + 81,
    K_F1 = 0x100 + 59, K_F3 = 0x100 + 61, K_F6 = 0x100 + 64,
    K_F9 = 0x100 + 67, K_F10 = 0x100 + 68
};
#define KEEP_ANCHOR INT_MIN

typedef struct {
    int pid;
    wchar_t name[260];
    wchar_t path[1024];
    double cpu, mem, readMBps, writeMBps;
    int isSystem;
    int isNew;
} ProcInfo;

typedef struct {
    ProcInfo *v;
    int n, cap;
} ProcList;

typedef struct {
    wchar_t name[8];
    double usedGb, totGb, pct;
} DriveInfo;

/* Small open-addressing int->(u64,string) map. One type serves the previous-
   sample tables, the PID sets (value ignored) and the path cache. */
typedef struct {
    int key;
    unsigned long long num;
    wchar_t *str;          /* malloc'd per entry; only the path cache uses it */
    unsigned char state;   /* 0 empty, 1 live, 2 tombstone */
} MapEnt;
typedef struct {
    MapEnt *e;
    int cap, num;
} Map;

/* ---------------- globals ---------------- */
static HANDLE g_hOut, g_hIn;
static CRITICAL_SECTION g_cs;
static volatile LONG g_samplerStop = 0;
static HANDLE g_samplerThread = NULL;

static Map g_prevCpu, g_prevRead, g_prevWrite;   /* sampler thread only */
static Map g_pathCache;                          /* pid -> (createTime, path) */
static Map g_newProcs;                           /* pid -> green-flash expiry ms */
static Map g_prevLiveIds, g_liveIds, g_windowPids;

static ProcList g_allProcs;      /* sampler -> UI under lock */
static ProcList g_fullList;      /* filtered+sorted, UI thread only */
static int g_selected = 0, g_scrollOffset = 0;
static wchar_t g_filter[512] = L"";
static wchar_t g_sortBy[16] = L"CPU";
static int g_sortDesc = 1;
static int g_sortCol = 0;        /* qsort key derived from g_sortBy */
static int g_running = 1, g_paused = 0, g_needRedraw = 1;
static int g_showAll = 1;
static int g_pinSelection = 0;
static unsigned long long g_nextRefreshMs = 0;
static double g_lastSysCpu = 0.0, g_lastMemUsed = 0.0, g_lastMemTot = 0.0, g_lastMemPct = 0.0;
static DriveInfo g_drives[64];
static int g_driveCount = 0;
static int g_totalProcesses = 0, g_userProcs = 0, g_sysProcs = 0;
static const wchar_t *SORT_COLUMNS[6] = { L"CPU", L"MEM", L"READ", L"WRITE", L"NAME", L"PID" };
static wchar_t g_host[256], g_user[256];
static unsigned long long g_lastSampleMs = 0;
static double g_cpuRing[3]; static int g_cpuRingIdx = 0, g_cpuRingN = 0;
static int g_firstSample = 1;
static int g_lastWinW = -1, g_lastWinH = -1;
static int g_origBufW = 80, g_origBufH = 25;
static int g_bufferLocked = 0;
static DWORD g_origConsoleMode = 0;
static int g_haveOrigConsoleMode = 0;
static WORD g_origAttr = 0x07;
static DWORD g_ownPid = 0;

static const wchar_t *CRITICAL_NAMES[] = {
    L"system", L"idle", L"registry", L"smss", L"csrss", L"wininit", L"services",
    L"lsass", L"winlogon", L"fontdrvhost", L"dwm", L"svchost",
    L"memory compression", L"secure system"
};
/* Windowless per-session Windows infrastructure hosts. Only consulted for
   exes under a Windows system directory without a visible window. */
static const wchar_t *INFRA_NAMES[] = {
    L"sihost", L"ctfmon", L"runtimebroker", L"dllhost", L"taskhostw", L"taskhost",
    L"conhost", L"searchhost", L"startmenuexperiencehost", L"shellexperiencehost",
    L"applicationframehost", L"textinputhost", L"searchindexer", L"wmiprvse",
    L"spoolsv"
};

/* ---------------- console helpers ---------------- */
static void cons_color(int fg, int bg) {
    SetConsoleTextAttribute(g_hOut, (WORD)(((bg & 15) << 4) | (fg & 15)));
}
static void cons_drawcolor(void) { cons_color(C_GRAY, C_BLACK); } /* our palette, never the host's */
static void cons_write(const wchar_t *s) {
    if (s && *s) { DWORD w = 0; WriteConsoleW(g_hOut, s, (DWORD)wcslen(s), &w, NULL); }
}
static void cons_writeln(const wchar_t *s) { cons_write(s); cons_write(L"\r\n"); }
static void goto_xy(int x, int y) {
    COORD c; c.X = (SHORT)x; c.Y = (SHORT)y;
    SetConsoleCursorPosition(g_hOut, c);
}
static void show_cursor(int v) {
    CONSOLE_CURSOR_INFO ci;
    if (GetConsoleCursorInfo(g_hOut, &ci)) { ci.bVisible = v ? TRUE : FALSE; SetConsoleCursorInfo(g_hOut, &ci); }
}
static void get_win_size(int *w, int *h) {
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (GetConsoleScreenBufferInfo(g_hOut, &bi)) {
        *w = bi.srWindow.Right - bi.srWindow.Left + 1;
        *h = bi.srWindow.Bottom - bi.srWindow.Top + 1;
    } else { *w = 80; *h = 25; }
}
static void clear_all(void) {
    /* Repaint the whole buffer with our palette (kills the host's dark-blue bleed). */
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (!GetConsoleScreenBufferInfo(g_hOut, &bi)) return;
    DWORD cells = (DWORD)bi.dwSize.X * (DWORD)bi.dwSize.Y;
    COORD home = { 0, 0 };
    DWORD w = 0;
    FillConsoleOutputCharacterW(g_hOut, L' ', cells, home, &w);
    FillConsoleOutputAttribute(g_hOut, 0x07, cells, home, &w);
    goto_xy(0, 0);
}
static void fit_buffer_to_window(void) {
    /* Lock the scrollback buffer to the visible window: no scrollbar, no history. */
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (!GetConsoleScreenBufferInfo(g_hOut, &bi)) return;
    int w = bi.srWindow.Right - bi.srWindow.Left + 1;
    int h = bi.srWindow.Bottom - bi.srWindow.Top + 1;
    if (w > 0 && h > 0 && (bi.dwSize.X != w || bi.dwSize.Y != h)) {
        COORD sz; sz.X = (SHORT)w; sz.Y = (SHORT)h;
        if (SetConsoleScreenBufferSize(g_hOut, sz)) g_bufferLocked = 1;
    }
}
static void disable_quick_edit(void) {
    /* Clicking the console must not freeze the app in "Select" mark mode. */
    if (!g_hIn || g_hIn == INVALID_HANDLE_VALUE) return;
    DWORD mode = 0;
    if (GetConsoleMode(g_hIn, &mode)) {
        if (!g_haveOrigConsoleMode) { g_origConsoleMode = mode; g_haveOrigConsoleMode = 1; }
        SetConsoleMode(g_hIn, (mode & ~ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS);
    }
}
static void restore_console_mode(void) {
    if (!g_haveOrigConsoleMode) return;
    if (!g_hIn || g_hIn == INVALID_HANDLE_VALUE) return;
    SetConsoleMode(g_hIn, g_origConsoleMode);
}
static int read_key(void) {
    /* _getwch: no echo, Unicode. Arrows/F-keys come as 0/224 + scan code. */
    wint_t c = _getwch();
    if (c == 0 || c == 224) { wint_t s = _getwch(); return 0x100 + (int)s; }
    return (int)c;
}

/* ---------------- string helpers ---------------- */
static double r1(double v) { return round(v * 10.0) / 10.0; }
static double r2(double v) { return round(v * 100.0) / 100.0; }
/* copy src into dst, truncated or space-padded to exactly width cells */
static void fit_cell(wchar_t *dst, int dstn, const wchar_t *src, int width) {
    int i = 0;
    while (i < width && i < dstn - 1 && src[i]) { dst[i] = src[i]; i++; }
    while (i < width && i < dstn - 1) { dst[i] = L' '; i++; }
    dst[i] = 0;
}
static int wcs_icmp(const wchar_t *a, const wchar_t *b) {
    while (*a && *b) {
        wchar_t ca = (wchar_t)towlower(*a), cb = (wchar_t)towlower(*b);
        if (ca != cb) return ca < cb ? -1 : 1;
        a++; b++;
    }
    if (*a == *b) return 0;
    return *a ? 1 : -1;
}
static void wcs_tolower_buf(wchar_t *dst, int dstn, const wchar_t *src) {
    int i = 0;
    while (i < dstn - 1 && src[i]) { dst[i] = (wchar_t)towlower(src[i]); i++; }
    dst[i] = 0;
}
static int str_contains_i(const wchar_t *hay, const wchar_t *needle) {
    size_t hn = wcslen(hay), nn = wcslen(needle), i, j;
    if (nn == 0) return 1;
    if (nn > hn) return 0;
    for (i = 0; i + nn <= hn; i++) {
        for (j = 0; j < nn; j++)
            if (towlower(hay[i + j]) != towlower(needle[j])) break;
        if (j == nn) return 1;
    }
    return 0;
}
/* case-insensitive full match; '*' matches any run (no '?' support, like before) */
static int wild_match(const wchar_t *t, const wchar_t *p) {
    const wchar_t *star = NULL, *ss = t;
    while (*t) {
        if (*p == L'*') { star = p++; ss = t; }
        else if (towlower(*p) == towlower(*t)) { p++; t++; }
        else if (star) { p = star + 1; t = ++ss; }
        else return 0;
    }
    while (*p == L'*') p++;
    return *p == L'\0';
}

/* ---------------- dynamic array + hash map ---------------- */
static void proclist_init(ProcList *L) { L->v = NULL; L->n = 0; L->cap = 0; }
static void proclist_free(ProcList *L) { free(L->v); L->v = NULL; L->n = L->cap = 0; }
static void proclist_push(ProcList *L, const ProcInfo *p) {
    if (L->n == L->cap) {
        int nc = L->cap ? L->cap * 2 : 256;
        ProcInfo *nv = (ProcInfo*)realloc(L->v, (size_t)nc * sizeof(ProcInfo));
        if (!nv) return; /* OOM: drop the entry */
        L->v = nv; L->cap = nc;
    }
    L->v[L->n++] = *p;
}

static unsigned int hash_int(int k) {
    unsigned int x = (unsigned int)k;
    x ^= x >> 16; x *= 0x7feb352d; x ^= x >> 15; x *= 0x846ca68b; x ^= x >> 16;
    return x;
}
static void map_init(Map *m) { m->e = NULL; m->cap = 0; m->num = 0; }
static void map_free(Map *m) {
    if (m->e) { int i; for (i = 0; i < m->cap; i++) free(m->e[i].str); free(m->e); }
    m->e = NULL; m->cap = m->num = 0;
}
static void map_rehash(Map *m, int newcap) {
    MapEnt *newe = (MapEnt*)calloc((size_t)newcap, sizeof(MapEnt));
    int i, j;
    MapEnt *old;
    int oldcap;
    if (!newe) return;
    old = m->e; oldcap = m->cap;
    m->e = newe; m->cap = newcap; m->num = 0;
    for (i = 0; i < oldcap; i++) {
        if (old[i].state == 1) {
            unsigned int h = hash_int(old[i].key) & (unsigned int)(newcap - 1);
            for (j = 0; j < newcap; j++) {
                MapEnt *e = &m->e[(h + j) & (unsigned int)(newcap - 1)];
                if (e->state == 0) { *e = old[i]; m->num++; break; }
            }
        } else free(old[i].str);
    }
    free(old);
}
static void map_ensure(Map *m) {
    if (m->cap == 0) { map_rehash(m, 64); return; }
    if ((m->num + 1) * 4 > m->cap * 3) map_rehash(m, m->cap * 2);
}
static MapEnt *map_slot(Map *m, int key) {
    /* find existing entry, or a slot to insert into (tombstone preferred) */
    unsigned int h = hash_int(key) & (unsigned int)(m->cap - 1);
    MapEnt *dead = NULL;
    int i;
    for (i = 0; i < m->cap; i++) {
        MapEnt *e = &m->e[(h + i) & (unsigned int)(m->cap - 1)];
        if (e->state == 1 && e->key == key) return e;
        if (e->state == 2 && !dead) dead = e;
        if (e->state == 0) return dead ? dead : e;
    }
    return dead;
}
static void map_put_num(Map *m, int key, unsigned long long num) {
    MapEnt *e;
    map_ensure(m);
    e = map_slot(m, key);
    if (!e) return;
    if (e->state != 1) { e->key = key; e->state = 1; m->num++; }
    e->num = num;
}
static void map_put_path(Map *m, int key, unsigned long long num, const wchar_t *path) {
    MapEnt *e;
    size_t n;
    map_ensure(m);
    e = map_slot(m, key);
    if (!e) return;
    if (e->state != 1) { e->key = key; e->state = 1; e->str = NULL; m->num++; }
    free(e->str); e->str = NULL;
    if (path) {
        n = wcslen(path) + 1;
        e->str = (wchar_t*)malloc(n * sizeof(wchar_t));
        if (e->str) wcscpy(e->str, path);
    }
    e->num = num;
}
static int map_get_num(Map *m, int key, unsigned long long *out) {
    unsigned int h;
    int i;
    if (!m->cap) return 0;
    h = hash_int(key) & (unsigned int)(m->cap - 1);
    for (i = 0; i < m->cap; i++) {
        MapEnt *e = &m->e[(h + i) & (unsigned int)(m->cap - 1)];
        if (e->state == 0) return 0;
        if (e->state == 1 && e->key == key) { *out = e->num; return 1; }
    }
    return 0;
}
static int map_has(Map *m, int key) { unsigned long long d; return map_get_num(m, key, &d); }
static const wchar_t *map_get_str(Map *m, int key) {
    unsigned int h;
    int i;
    if (!m->cap) return NULL;
    h = hash_int(key) & (unsigned int)(m->cap - 1);
    for (i = 0; i < m->cap; i++) {
        MapEnt *e = &m->e[(h + i) & (unsigned int)(m->cap - 1)];
        if (e->state == 0) return NULL;
        if (e->state == 1 && e->key == key) return e->str;
    }
    return NULL;
}
static void map_del(Map *m, int key) {
    unsigned int h;
    int i;
    if (!m->cap) return;
    h = hash_int(key) & (unsigned int)(m->cap - 1);
    for (i = 0; i < m->cap; i++) {
        MapEnt *e = &m->e[(h + i) & (unsigned int)(m->cap - 1)];
        if (e->state == 0) return;
        if (e->state == 1 && e->key == key) {
            e->state = 2; free(e->str); e->str = NULL; m->num--;
            return;
        }
    }
}

/* ---------------- settings ---------------- */
static void settings_path(wchar_t *dst, int dstn) {
    wchar_t base[512] = L"";
    GetEnvironmentVariableW(L"LOCALAPPDATA", base, 512);
    swprintf(dst, dstn, L"%s\\%s\\settings.cfg", base, APPNAME);
}
static void load_settings(void) {
    /* Missing or corrupt file just means defaults - never a crash. */
    wchar_t path[1024], line[512];
    FILE *f;
    settings_path(path, 1024);
    f = _wfopen(path, L"r, ccs=UTF-8");
    if (!f) return;
    while (fgetws(line, 512, f)) {
        wchar_t *eq, *key, *val, *a;
        wchar_t lk[64], lv[64];
        /* trim trailing newline */
        size_t n = wcslen(line);
        while (n && (line[n-1] == L'\n' || line[n-1] == L'\r')) line[--n] = 0;
        a = line;
        while (*a == L' ' || *a == L'\t') a++;
        if (!*a || *a == L'#') continue;
        eq = wcschr(a, L'=');
        if (!eq) continue;
        *eq = 0; key = a; val = eq + 1;
        while (*val == L' ' || *val == L'\t') val++;
        n = wcslen(val);
        while (n && (val[n-1] == L' ' || val[n-1] == L'\t')) val[--n] = 0;
        wcs_tolower_buf(lk, 64, key); wcs_tolower_buf(lv, 64, val);
        if (!wcscmp(lk, L"showallprocesses")) g_showAll = !wcscmp(lv, L"true");
        else if (!wcscmp(lk, L"sortby")) {
            int i;
            for (i = 0; i < 6; i++)
                if (!wcs_icmp(val, SORT_COLUMNS[i])) { wcscpy(g_sortBy, SORT_COLUMNS[i]); break; }
        }
        else if (!wcscmp(lk, L"sortdesc")) g_sortDesc = !wcscmp(lv, L"true");
    }
    fclose(f);
}
static void save_settings(void) {
    /* Written on every preference change, so it survives even a kill. */
    wchar_t path[1024], dir[1024], *p;
    FILE *f;
    settings_path(path, 1024);
    wcscpy(dir, path);
    p = wcsrchr(dir, L'\\');
    if (p) { *p = 0; CreateDirectoryW(dir, NULL); }
    f = _wfopen(path, L"w, ccs=UTF-8");
    if (!f) return;
    fwprintf(f, L"# %s settings - safe to edit by hand\n", APPNAME);
    fwprintf(f, L"ShowAllProcesses=%s\n", g_showAll ? L"true" : L"false");
    fwprintf(f, L"SortBy=%s\n", g_sortBy);
    fwprintf(f, L"SortDesc=%s\n", g_sortDesc ? L"true" : L"false");
    fclose(f);
}

/* ---------------- classification ---------------- */
static int crit_name(const wchar_t *name) {
    wchar_t l[64];
    size_t i;
    wcs_tolower_buf(l, 64, name);
    for (i = 0; i < sizeof(CRITICAL_NAMES) / sizeof(CRITICAL_NAMES[0]); i++)
        if (!wcscmp(l, CRITICAL_NAMES[i])) return 1;
    return 0;
}
static int infra_name(const wchar_t *name) {
    wchar_t l[64];
    size_t i;
    wcs_tolower_buf(l, 64, name);
    for (i = 0; i < sizeof(INFRA_NAMES) / sizeof(INFRA_NAMES[0]); i++)
        if (!wcscmp(l, INFRA_NAMES[i])) return 1;
    return 0;
}
static void file_name_no_ext(const wchar_t *path, wchar_t *dst, int dstn) {
    const wchar_t *p = wcsrchr(path, L'\\');
    const wchar_t *q = wcsrchr(path, L'/');
    const wchar_t *f = path, *d;
    if (p && p > f) f = p + 1;
    if (q && q > f) f = q + 1;
    wcsncpy(dst, f, dstn - 1); dst[dstn - 1] = 0;
    d = wcsrchr(dst, L'.');
    if (d) *(wchar_t*)d = 0;
}
static int is_windows_system_path(const wchar_t *path) {
    wchar_t l[1024];
    if (!path || !*path || !wcscmp(path, L"-")) return 0;
    wcs_tolower_buf(l, 1024, path);
    return wcsstr(l, L"\\windows\\system32\\") || wcsstr(l, L"\\windows\\syswow64\\") ||
           wcsstr(l, L"\\windows\\winsxs\\") || wcsstr(l, L"\\windows\\servicing\\") ||
           wcsstr(l, L"\\windows\\systemapps\\");
}
static int is_protected(const ProcInfo *pr) {
    wchar_t fn[260];
    wchar_t l[1024];
    if (pr->pid <= 8 || (DWORD)pr->pid == g_ownPid) return 1;
    if (crit_name(pr->name)) return 1;
    if (pr->path[0] && wcscmp(pr->path, L"-")) {
        wcs_tolower_buf(l, 1024, pr->path);
        if ((wcsstr(l, L"\\windows\\system32\\") || wcsstr(l, L"\\windows\\syswow64\\"))) {
            file_name_no_ext(pr->path, fn, 260);
            if (crit_name(fn)) return 1;
        }
    }
    return 0;
}
static int compute_is_system(int pid, const wchar_t *name, const wchar_t *path,
                             int sessionId, int hasWindow) {
    if (pid <= 8) return 1;
    /* Session 0 is the services session: nothing interactive runs there. */
    if (sessionId == 0) return 1;
    /* Well-known core processes, matched by name too: keeps them classified as
       system even when the image path cannot be read (protected processes). */
    if (crit_name(name)) return 1;
    /* A visible top-level window means an interactive app the user launched,
       even if the exe happens to live in System32 (mstsc, notepad, ...). */
    if (hasWindow) return 0;
    /* Windowless Windows-shipped binaries are OS infrastructure
       (sihost, ctfmon, RuntimeBroker, ...). Anything else defaults to user:
       better to show a process than to hide one he launched. */
    if (is_windows_system_path(path) && infra_name(name)) return 1;
    return 0;
}
static BOOL CALLBACK enum_window_pids(HWND hwnd, LPARAM lParam) {
    if (!IsWindowVisible(hwnd)) return TRUE;
    {
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid) map_put_num((Map*)lParam, (int)pid, 0);
    }
    return TRUE;
}
static int matches_filter(const ProcInfo *pr, const wchar_t *filter) {
    wchar_t pidbuf[32];
    if (!filter[0]) return 1;
    swprintf(pidbuf, 32, L"%d", pr->pid);
    if (wcschr(filter, L'*'))
        return wild_match(pr->name, filter) || wild_match(pidbuf, filter) || wild_match(pr->path, filter);
    return str_contains_i(pr->name, filter) || str_contains_i(pidbuf, filter) ||
           str_contains_i(pr->path, filter);
}
static void make_bar(wchar_t *dst, int dstn, double pct) {
    int f = (int)(pct / 100.0 * BAR_WIDTH + 0.5);
    int i = 0;
    if (f < 0) f = 0;
    if (f > BAR_WIDTH) f = BAR_WIDTH;
    for (; i < f && i < dstn - 1; i++) dst[i] = L'|';
    for (; i < BAR_WIDTH && i < dstn - 1; i++) dst[i] = L' ';
    dst[i] = 0;
}
static void format_disk_pair(wchar_t *dst, int dstn, double usedGb, double totGb) {
    /* Sub-GB volumes: show MB so the numbers stay meaningful. */
    if (totGb < 1.0) swprintf(dst, dstn, L"%.1f / %.1f MB", usedGb * 1024.0, totGb * 1024.0);
    else swprintf(dst, dstn, L"%.1f / %.1f GB", usedGb, totGb);
}
static void format_uptime(wchar_t *dst, int dstn) {
    unsigned long long s = GetTickCount64() / 1000;
    if (s >= 86400) swprintf(dst, dstn, L"%llu d %llu h %llu m", s / 86400, (s / 3600) % 24, (s / 60) % 60);
    else if (s >= 3600) swprintf(dst, dstn, L"%llu h %llu m %llu s", s / 3600, (s / 60) % 60, s % 60);
    else swprintf(dst, dstn, L"%llu m %llu s", s / 60, s % 60);
}
static void now_hms(wchar_t *dst, int dstn) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    swprintf(dst, dstn, L"%02d:%02d:%02d", st.wHour, st.wMinute, st.wSecond);
}

/* ---------------- sampling ---------------- */
static void sample_processes(void) {
    unsigned long long nowMs = GetTickCount64();
    double elapsed;
    double memUsedMb = 0, memTotMb = 0, memPct = 0;
    MEMORYSTATUSEX ms;
    DriveInfo drives[64];
    int driveCount = 0;
    DWORD dmask;
    int i, total = 0, userCount = 0, sysCount = 0;
    double sumCpu = 0;
    int cores = 1;
    SYSTEM_INFO si;
    HANDLE snap;
    PROCESSENTRY32W pe;
    ProcList *fresh;
    int di;
    double rawCpu, acc;
    int n;

    EnterCriticalSection(&g_cs);
    elapsed = (nowMs - g_lastSampleMs) / 1000.0;
    LeaveCriticalSection(&g_cs);
    if (elapsed < 0.5) elapsed = 0.5;

    ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) {
        memTotMb = round(ms.ullTotalPhys / 1048576.0);
        memUsedMb = round((ms.ullTotalPhys - ms.ullAvailPhys) / 1048576.0);
        memPct = (double)ms.dwMemoryLoad;
    }

    dmask = GetLogicalDrives();
    for (i = 0; i < 26 && driveCount < 64; i++) {
        wchar_t root[4];
        ULARGE_INTEGER freeB, totB, totFree;
        double tot, fr;
        if (!(dmask & (1u << i))) continue;
        root[0] = (wchar_t)(L'A' + i); root[1] = L':'; root[2] = L'\\'; root[3] = 0;
        if (GetDriveTypeW(root) != DRIVE_FIXED) continue;
        if (!GetDiskFreeSpaceExW(root, &freeB, &totB, &totFree)) continue;
        tot = totB.QuadPart / 1073741824.0;
        fr = freeB.QuadPart / 1073741824.0;
        drives[driveCount].name[0] = (wchar_t)(L'A' + i);
        drives[driveCount].name[1] = L':'; drives[driveCount].name[2] = 0;
        drives[driveCount].usedGb = tot - fr;
        drives[driveCount].totGb = tot;
        drives[driveCount].pct = tot > 0 ? (tot - fr) / tot * 100.0 : 0;
        driveCount++;
    }

    /* One window enumeration per sample: which PIDs own a visible top-level
       window (used to tell user-launched GUI apps apart from OS plumbing). */
    map_free(&g_windowPids); map_init(&g_windowPids);
    EnumWindows(enum_window_pids, (LPARAM)&g_windowPids);

    map_free(&g_liveIds); map_init(&g_liveIds);
    GetSystemInfo(&si);
    if (si.dwNumberOfProcessors > 0) cores = (int)si.dwNumberOfProcessors;

    fresh = (ProcList*)malloc(sizeof(ProcList));
    if (fresh) proclist_init(fresh);

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE && fresh) {
        pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) do {
            int pid = (int)pe.th32ProcessID;
            int sessId = -1;
            DWORD s = 0;
            HANDLE h;
            double cpu = 0;
            unsigned long long createTime = 0, prev;
            double memMb = 0, readMBps = 0, writeMBps = 0;
            wchar_t fullPath[1024];
            int pidIsNew = 0;
            const wchar_t *cached;
            ProcInfo pi;
            int hasWindow;

            map_put_num(&g_liveIds, pid, 0);
            total++;

            if (ProcessIdToSessionId((DWORD)pid, &s)) sessId = (int)s;

            /* Process Explorer-style "new process" highlight. */
            if (!g_firstSample && !map_has(&g_prevLiveIds, pid)) {
                map_put_num(&g_newProcs, pid, nowMs + NEW_PROC_HIGHLIGHT_SECS * 1000ULL);
                pidIsNew = 1;
            } else if (map_get_num(&g_newProcs, pid, &prev) && nowMs < prev) {
                pidIsNew = 1;
            }

            /* QUERY_LIMITED_INFORMATION only: asking for the full right is
               all-or-nothing, and SYSTEM/protected processes deny it to a
               non-elevated token - which used to leave the path as "-". */
            h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
            if (h) {
                FILETIME fc, fe, fk, fu;
                if (GetProcessTimes(h, &fc, &fe, &fk, &fu)) {
                    ULARGE_INTEGER ct, k, u;
                    unsigned long long tpt;
                    ct.LowPart = fc.dwLowDateTime; ct.HighPart = fc.dwHighDateTime;
                    createTime = ct.QuadPart;
                    k.LowPart = fk.dwLowDateTime; k.HighPart = fk.dwHighDateTime;
                    u.LowPart = fu.dwLowDateTime; u.HighPart = fu.dwHighDateTime;
                    tpt = k.QuadPart + u.QuadPart; /* 100ns */
                    if (map_get_num(&g_prevCpu, pid, &prev))
                        cpu = r1((tpt > prev ? (double)(tpt - prev) : 0.0) / 1e7 / elapsed / cores * 100.0);
                    if (cpu < 0) cpu = 0;
                    map_put_num(&g_prevCpu, pid, tpt);
                    sumCpu += cpu;
                }
            }

            wcscpy(fullPath, L"-");
            if (h) {
                PROCESS_MEMORY_COUNTERS pmc;
                IO_COUNTERS io;
                if (GetProcessMemoryInfo(h, &pmc, sizeof(pmc)))
                    memMb = r1(pmc.WorkingSetSize / 1048576.0);
                /* The exe path of a PID never changes during the process's
                   lifetime, so cache it: QueryFullProcessImageNameW is the most
                   expensive call in the sample loop. The creation time guards
                   against PID reuse (a recycled PID gets a fresh query). */
                cached = NULL;
                if (createTime && map_get_num(&g_pathCache, pid, &prev) && prev == createTime)
                    cached = map_get_str(&g_pathCache, pid);
                if (cached) {
                    wcsncpy(fullPath, cached, 1023); fullPath[1023] = 0;
                } else {
                    wchar_t ibuf[1024]; DWORD isz = 1024;
                    if (QueryFullProcessImageNameW(h, 0, ibuf, &isz) && isz > 0) {
                        wcsncpy(fullPath, ibuf, 1023); fullPath[1023] = 0;
                    }
                    if (createTime) map_put_path(&g_pathCache, pid, createTime, fullPath);
                }
                if (GetProcessIoCounters(h, &io)) {
                    /* Guard against PID reuse: a recycled PID can have smaller
                       counters than the stale entry, which would underflow. */
                    if (map_get_num(&g_prevRead, pid, &prev) && io.ReadTransferCount >= prev)
                        readMBps = r2((double)(io.ReadTransferCount - prev) / elapsed / 1048576.0);
                    if (readMBps < 0) readMBps = 0;
                    if (map_get_num(&g_prevWrite, pid, &prev) && io.WriteTransferCount >= prev)
                        writeMBps = r2((double)(io.WriteTransferCount - prev) / elapsed / 1048576.0);
                    if (writeMBps < 0) writeMBps = 0;
                    map_put_num(&g_prevRead, pid, io.ReadTransferCount);
                    map_put_num(&g_prevWrite, pid, io.WriteTransferCount);
                }
                CloseHandle(h);
            }

            pi.pid = pid;
            wcsncpy(pi.name, pe.szExeFile, 259); pi.name[259] = 0;
            wcsncpy(pi.path, fullPath, 1023); pi.path[1023] = 0;
            pi.cpu = cpu; pi.mem = memMb;
            pi.readMBps = readMBps; pi.writeMBps = writeMBps;
            hasWindow = map_has(&g_windowPids, pid);
            pi.isSystem = compute_is_system(pid, pi.name, pi.path, sessId, hasWindow);
            pi.isNew = pidIsNew;
            if (pi.isSystem) sysCount++; else userCount++;
            proclist_push(fresh, &pi);
        } while (Process32NextW(snap, &pe));
        CloseHandle(snap);
    }

    /* Prune dead PIDs from the previous-sample tables. */
    if (g_prevCpu.num > g_liveIds.num + 32) {
        int i;
        for (i = 0; i < g_prevCpu.cap; i++) {
            MapEnt *e = &g_prevCpu.e[i];
            if (e->state == 1 && !map_has(&g_liveIds, e->key)) {
                map_del(&g_prevCpu, e->key);
                map_del(&g_prevRead, e->key);
                map_del(&g_prevWrite, e->key);
                map_del(&g_pathCache, e->key);
            }
        }
    }
    /* Expire old "new process" highlights and drop PIDs that are gone.
       (The very first sample marks nothing, so the whole list doesn't flash.) */
    for (di = 0; di < g_newProcs.cap; di++) {
        MapEnt *e = &g_newProcs.e[di];
        if (e->state == 1 && (nowMs >= e->num || !map_has(&g_liveIds, e->key)))
            map_del(&g_newProcs, e->key);
    }
    g_firstSample = 0;
    map_free(&g_prevLiveIds);
    g_prevLiveIds = g_liveIds;
    map_init(&g_liveIds);

    rawCpu = r1(sumCpu);
    if (rawCpu > 100.0) rawCpu = 100.0;
    EnterCriticalSection(&g_cs);
    g_cpuRing[g_cpuRingIdx] = rawCpu;
    g_cpuRingIdx = (g_cpuRingIdx + 1) % 3;
    if (g_cpuRingN < 3) g_cpuRingN++;
    acc = 0;
    for (n = 0; n < g_cpuRingN; n++) acc += g_cpuRing[n];
    g_lastSysCpu = g_cpuRingN ? r1(acc / g_cpuRingN) : 0;
    g_lastMemUsed = memUsedMb; g_lastMemTot = memTotMb; g_lastMemPct = memPct;
    g_driveCount = driveCount;
    for (di = 0; di < driveCount; di++) g_drives[di] = drives[di];
    g_totalProcesses = total;
    g_userProcs = userCount; g_sysProcs = sysCount;
    if (fresh) {
        proclist_free(&g_allProcs);
        g_allProcs = *fresh;
        free(fresh);
    }
    g_lastSampleMs = nowMs;
    LeaveCriticalSection(&g_cs);
}

static DWORD WINAPI sampler_thread_proc(LPVOID p) {
    int i;
    (void)p;
    while (!InterlockedCompareExchange(&g_samplerStop, 0, 0)) {
        sample_processes();
        for (i = 0; i < 125; i++) {
            if (InterlockedCompareExchange(&g_samplerStop, 0, 0)) break;
            Sleep(40); /* ~5s between samples */
        }
    }
    return 0;
}

/* ---------------- filter / sort ---------------- */
static int header_lines(void) {
    int n;
    EnterCriticalSection(&g_cs);
    n = g_driveCount;
    LeaveCriticalSection(&g_cs);
    return 8 + (n > 1 ? n : 1);
}
static int proc_cmp(const void *a, const void *b) {
    const ProcInfo *x = (const ProcInfo*)a, *y = (const ProcInfo*)b;
    int c = 0;
    switch (g_sortCol) {
    case 1: c = (x->mem < y->mem) ? -1 : (x->mem > y->mem); break;
    case 2: c = (x->readMBps < y->readMBps) ? -1 : (x->readMBps > y->readMBps); break;
    case 3: c = (x->writeMBps < y->writeMBps) ? -1 : (x->writeMBps > y->writeMBps); break;
    case 4: c = wcs_icmp(x->name, y->name); break;
    case 5: c = (x->pid < y->pid) ? -1 : (x->pid > y->pid); break;
    default: c = (x->cpu < y->cpu) ? -1 : (x->cpu > y->cpu); break;
    }
    return g_sortDesc ? -c : c;
}
/* keepPid: KEEP_ANCHOR = keep the currently selected process;
   -1 = no pinning (selection resets to the top); else pin that PID. */
static void apply_filter_and_sort(int keepPid) {
    ProcList work;
    int i, w, ww, wh, maxRows, count;
    if (keepPid == -1) g_pinSelection = 0;   /* explicit reset also unpins */
    {
        int anchor = keepPid, n = g_fullList.n;
        if (anchor == KEEP_ANCHOR)
            anchor = (g_selected >= 0 && g_selected < n) ? g_fullList.v[g_selected].pid : -1;

        proclist_init(&work);
        EnterCriticalSection(&g_cs);
        for (i = 0; i < g_allProcs.n; i++) proclist_push(&work, &g_allProcs.v[i]);
        LeaveCriticalSection(&g_cs);

        w = 0;
        for (i = 0; i < work.n; i++) {
            ProcInfo *x = &work.v[i];
            if (!g_showAll && x->isSystem) continue;
            if (!matches_filter(x, g_filter)) continue;
            if (w != i) work.v[w] = work.v[i];
            w++;
        }
        work.n = w;

        g_sortCol = 0;
        for (i = 0; i < 6; i++)
            if (!wcs_icmp(g_sortBy, SORT_COLUMNS[i])) { g_sortCol = i; break; }
        if (work.n > 1) qsort(work.v, (size_t)work.n, sizeof(ProcInfo), proc_cmp);

        proclist_free(&g_fullList);
        g_fullList = work;

        get_win_size(&ww, &wh);
        maxRows = wh - header_lines() - 2;
        if (maxRows < 3) maxRows = 3;
        count = g_fullList.n;

        /* Pin the selected process at its current row: the list keeps
           auto-sorting around it, but the process you arrowed to never slides
           out from under the cursor, so kill always hits the process you
           picked. 'c' unpins. */
        if (anchor >= 0 && g_pinSelection && count > 0) {
            int from = -1, at;
            for (i = 0; i < count; i++)
                if (g_fullList.v[i].pid == anchor) { from = i; break; }
            if (from >= 0) {
                ProcInfo pinned;
                at = g_selected;
                if (at < 0) at = 0;
                if (at >= count) at = count - 1;
                if (from != at) {
                    pinned = g_fullList.v[from];
                    if (from < at) {
                        memmove(&g_fullList.v[from], &g_fullList.v[from + 1],
                                (size_t)(at - from) * sizeof(ProcInfo));
                        g_fullList.v[at] = pinned;
                    } else {
                        memmove(&g_fullList.v[at + 1], &g_fullList.v[at],
                                (size_t)(from - at) * sizeof(ProcInfo));
                        g_fullList.v[at] = pinned;
                    }
                }
                g_selected = at;
                if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
                if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
                return;
            }
            /* That process exited or got filtered out: fall through to clamping. */
        }
        if (g_scrollOffset > count - maxRows) g_scrollOffset = count - maxRows > 0 ? count - maxRows : 0;
        if (g_selected >= count) g_selected = count - 1 > 0 ? count - 1 : 0;
        if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
        if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
    }
}

/* ---------------- draw ---------------- */
/* LineBuilder: colored segments, then pad to full width. Tracks visible width
   itself (no cursor reads), so wrapped-line weirdness cannot break padding. */
typedef struct { int col; int winW; } LB;
static void lb_seg(LB *lb, const wchar_t *s, int fg, int bg) {
    cons_color(fg, bg); cons_write(s); lb->col += (int)wcslen(s);
}
static void lb_pad(LB *lb) {
    int n = lb->winW - lb->col, m, i;
    wchar_t tmp[1024];
    if (n <= 0) return;
    m = n > 1023 ? 1023 : n;
    for (i = 0; i < m; i++) tmp[i] = L' ';
    tmp[m] = 0;
    cons_write(tmp);
    lb->col += m;
}
static void lb_nl(LB *lb) { cons_write(L"\r\n"); lb->col = 0; }
static void write_header_cell(LB *lb, const wchar_t *text, const wchar_t *sortKey, int width) {
    wchar_t cell[64];
    int active = (wcs_icmp(g_sortBy, sortKey) == 0);
    fit_cell(cell, 64, text, width);
    lb_seg(lb, cell, C_BLACK, active ? C_YELLOW : C_DGRAY);
}

static void draw(void) {
    int rawW, rawH, winW, winH, ww, wh;
    double sysCpu, memUsed, memTot, memPct;
    int totalProcs, userProcs, i, j;
    DriveInfo drives[64];
    int driveCount;
    LB lb;
    wchar_t t[512], tm[32], up[64], b[256], bar[64], pair[64], lab[16];
    const wchar_t *mode;
    int headerLines, maxRows, pathWidth, pathMax, count, linesWritten, left;
    int listTop, listH, thumbH, maxStart, thumbStart, r, row;
    wchar_t ptext[12][32];
    int pfg[12], np = 0, col;

    get_win_size(&rawW, &rawH);
    if (rawW < 70 || rawH < 14) {
        goto_xy(0, 0);
        cons_color(C_YELLOW, C_BLACK);
        swprintf(t, 512, L"Window too small - make it larger to use %s.", APPNAME);
        cons_writeln(t);
        swprintf(t, 512, L"Need at least 70x14, have %dx%d.", rawW, rawH);
        cons_writeln(t);
        cons_drawcolor();
        return;
    }
    winW = rawW - 1; if (winW < 70) winW = 70;
    winH = rawH; if (winH < 14) winH = 14;
    goto_xy(0, 0);

    EnterCriticalSection(&g_cs);
    sysCpu = g_lastSysCpu; memUsed = g_lastMemUsed; memTot = g_lastMemTot;
    memPct = g_lastMemPct; totalProcs = g_totalProcesses; userProcs = g_userProcs;
    driveCount = g_driveCount;
    for (i = 0; i < driveCount && i < 64; i++) drives[i] = g_drives[i];
    LeaveCriticalSection(&g_cs);

    lb.col = 0; lb.winW = winW;
    mode = g_showAll ? L"ALL" : L"USER";
    format_uptime(up, 64);
    now_hms(tm, 32);

    /* Title */
    swprintf(t, 512, L"  %s  %s%s  [%s]", APPNAME, tm, g_paused ? L"  [PAUSED]" : L"", mode);
    fit_cell(t, 512, t, winW);
    lb_seg(&lb, t, C_WHITE, C_DBLUE);
    cons_drawcolor(); lb_nl(&lb);

    /* Host line */
    swprintf(t, 512, L"  Host %s   User %s   Uptime %s", g_host, g_user, up);
    fit_cell(t, 512, t, winW);
    lb_seg(&lb, t, C_CYAN, C_BLACK); lb_nl(&lb);
    fit_cell(t, 512, L"", winW);
    lb_seg(&lb, t, C_GRAY, C_BLACK); lb_nl(&lb);

    /* CPU / MEM / Disks - every '[' starts at the same column */
    {
        int fg = sysCpu >= 80 ? C_RED : sysCpu >= 50 ? C_YELLOW : C_GREEN;
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        lb_seg(&lb, L"  CPU  ", C_GREEN, C_BLACK);
        make_bar(bar, 64, sysCpu);
        swprintf(b, 256, L"[%s]", bar);
        lb_seg(&lb, b, fg, C_BLACK);
        swprintf(b, 256, L" %5.1f%%  %d CPU  procs %d", sysCpu,
                 (int)si.dwNumberOfProcessors, g_showAll ? totalProcs : userProcs);
        lb_seg(&lb, b, C_GREEN, C_BLACK);
        lb_pad(&lb); cons_drawcolor(); lb_nl(&lb);
    }
    {
        int fg = memPct >= 80 ? C_RED : memPct >= 50 ? C_YELLOW : C_CYAN;
        lb_seg(&lb, L"  Mem  ", C_CYAN, C_BLACK);
        make_bar(bar, 64, memPct);
        swprintf(b, 256, L"[%s]", bar);
        lb_seg(&lb, b, fg, C_BLACK);
        swprintf(b, 256, L" %5.1f%%  %.1f / %.1f GB", memPct, memUsed / 1024.0, memTot / 1024.0);
        lb_seg(&lb, b, C_CYAN, C_BLACK);
        lb_pad(&lb); cons_drawcolor(); lb_nl(&lb);
    }
    fit_cell(t, 512, L"  Disks", winW);
    lb_seg(&lb, t, C_MAG, C_BLACK); lb_pad(&lb); cons_drawcolor(); lb_nl(&lb);
    if (driveCount == 0) {
        fit_cell(t, 512, L"  (scanning...)", winW);
        lb_seg(&lb, t, C_GRAY, C_BLACK); lb_nl(&lb);
    } else {
        for (i = 0; i < driveCount; i++) {
            int fg = drives[i].pct >= 90 ? C_RED : drives[i].pct >= 75 ? C_YELLOW : C_MAG;
            swprintf(lab, 16, L"  %-3s  ", drives[i].name);
            lb_seg(&lb, lab, fg, C_BLACK);
            make_bar(bar, 64, drives[i].pct);
            swprintf(b, 256, L"[%s]", bar);
            lb_seg(&lb, b, fg, C_BLACK);
            format_disk_pair(pair, 64, drives[i].usedGb, drives[i].totGb);
            swprintf(b, 256, L" %5.1f%%  %s", drives[i].pct, pair);
            lb_seg(&lb, b, fg, C_BLACK);
            lb_pad(&lb); cons_drawcolor(); lb_nl(&lb);
        }
    }
    for (i = 0; i < winW && i < 511; i++) t[i] = L'-';
    t[i] = 0;
    lb_seg(&lb, t, C_DGRAY, C_BLACK); lb_nl(&lb);
    cons_drawcolor();

    /* Column headers */
    lb_seg(&lb, L"  ", C_GRAY, C_BLACK);
    write_header_cell(&lb, L"PID", L"PID", 6); lb_seg(&lb, L" ", C_GRAY, C_BLACK);
    write_header_cell(&lb, L"CPU%", L"CPU", 6); lb_seg(&lb, L" ", C_GRAY, C_BLACK);
    write_header_cell(&lb, L"MEM(MB)", L"MEM", 8); lb_seg(&lb, L" ", C_GRAY, C_BLACK);
    write_header_cell(&lb, L"R-MB/s", L"READ", 7); lb_seg(&lb, L" ", C_GRAY, C_BLACK);
    write_header_cell(&lb, L"W-MB/s", L"WRITE", 7); lb_seg(&lb, L" ", C_GRAY, C_BLACK);
    write_header_cell(&lb, L"Name", L"NAME", 18); lb_seg(&lb, L" ", C_GRAY, C_BLACK);
    pathWidth = winW - 62; if (pathWidth < 8) pathWidth = 8;
    write_header_cell(&lb, L"Path", L"NAME", pathWidth);
    cons_drawcolor(); lb_nl(&lb);

    headerLines = 8 + (driveCount > 1 ? driveCount : 1);
    maxRows = winH - headerLines - 2;
    if (maxRows < 3) maxRows = 3;
    pathMax = winW - 62; if (pathMax < 8) pathMax = 8;
    count = g_fullList.n;
    linesWritten = headerLines;

    for (i = 0; i < maxRows && g_scrollOffset + i < count; i++) {
        const ProcInfo *pr = &g_fullList.v[g_scrollOffset + i];
        int realIdx = g_scrollOffset + i, fg;
        wchar_t line[2048], nameShow[24], pathShow[1100];
        size_t pl = wcslen(pr->path);
        if (wcslen(pr->name) > 18) {
            wcsncpy(nameShow, pr->name, 15); nameShow[15] = 0; wcscat(nameShow, L"...");
        } else wcscpy(nameShow, pr->name);
        if ((int)pl > pathMax) swprintf(pathShow, 1100, L"...%s", pr->path + pl - pathMax + 3);
        else wcscpy(pathShow, pr->path);
        swprintf(line, 2048, L"  %6d %6.1f %8.1f %7.2f %7.2f %-*s %s",
                 pr->pid, pr->cpu, pr->mem, pr->readMBps, pr->writeMBps,
                 18, nameShow, pathShow);
        fit_cell(line, 2048, line, winW);
        if (realIdx == g_selected) lb_seg(&lb, line, C_BLACK, C_CYAN);
        else if (pr->isNew) lb_seg(&lb, line, C_GREEN, C_BLACK);
        else if (pr->isSystem) lb_seg(&lb, line, C_DGRAY, C_BLACK);
        else {
            fg = pr->cpu >= 40 ? C_RED : pr->cpu >= 10 ? C_YELLOW : C_GRAY;
            lb_seg(&lb, line, fg, C_BLACK);
        }
        lb_nl(&lb);
        linesWritten++;
    }

    {
        int shown = g_scrollOffset + (maxRows < count - g_scrollOffset ? maxRows : count - g_scrollOffset);
        if (shown >= count && count > 0) {
            fit_cell(t, 512, L"  -- end of processes --", winW);
            lb_seg(&lb, t, C_DGRAY, C_BLACK);
            lb_nl(&lb); linesWritten++;
        }
    }

    /* Fill remaining lines - the terminal never scrolls. */
    left = winH - 1 - linesWritten;
    if (left < 0) left = 0;
    cons_color(C_BLACK, C_BLACK);
    for (j = 0; j < left; j++) {
        for (i = 0; i < winW && i < 511; i++) t[i] = L' ';
        t[i] = 0;
        cons_writeln(t);
    }
    cons_drawcolor();

    /* Scrollbar on the right edge of the process area. */
    listTop = headerLines; listH = maxRows;
    thumbH = count <= listH ? listH : (int)(0.5 + (double)listH * listH / count);
    if (thumbH < 1) thumbH = 1;
    maxStart = listH - thumbH; if (maxStart < 0) maxStart = 0;
    thumbStart = 0;
    if (count > listH)
        thumbStart = (int)(0.5 + (double)g_scrollOffset / (count - listH) * maxStart);
    if (thumbStart < 0) thumbStart = 0;
    if (thumbStart > maxStart) thumbStart = maxStart;
    for (r = 0; r < listH; r++) {
        row = listTop + r;
        if (row >= winH - 1) break;
        goto_xy(winW - 1, row);
        if (r >= thumbStart && r < thumbStart + thumbH) {
            cons_color(C_GRAY, C_BLACK);
            cons_write(L"\u2588");
        } else {
            cons_color(C_DGRAY, C_BLACK);
            cons_write(L"\u2502");
        }
    }
    cons_drawcolor();

    /* Status bar on the last line: state first, then hotkeys most-used-first.
       An item is either fully shown or dropped, never cut in half. */
    if (g_filter[0]) {
        wchar_t fs[16];
        if (wcslen(g_filter) > 12) {
            wcsncpy(fs, g_filter, 12); fs[12] = 0; wcscat(fs, L"..");
        } else wcscpy(fs, g_filter);
        swprintf(ptext[np], 32, L"find:'%s'", fs);
        pfg[np++] = C_YELLOW;
    }
    wcscpy(ptext[np], L"q=quit"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"space=pause"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"/=find"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"<->=sort"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"k=kill"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"P=all/user"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"r=reverse"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"c=clear"); pfg[np++] = C_BLACK;
    wcscpy(ptext[np], L"h=help"); pfg[np++] = C_BLACK;

    goto_xy(0, winH - 1);
    cons_color(C_BLACK, C_DCYAN);
    col = 0;
    for (i = 0; i < np; i++) {
        int need = (int)wcslen(ptext[i]) + (col == 0 ? 0 : 2);
        if (col + need > winW) break;
        if (col != 0) { cons_write(L"  "); col += 2; }
        cons_color(pfg[i], C_DCYAN);
        cons_write(ptext[i]);
        col += (int)wcslen(ptext[i]);
    }
    cons_color(C_BLACK, C_DCYAN);
    if (col < winW) {
        for (i = 0; i < winW - col && i < 511; i++) t[i] = L' ';
        t[i] = 0;
        cons_write(t);
    }
    cons_drawcolor();
    (void)ww; (void)wh;
}

/* ---------------- actions ---------------- */
static void cycle_sort(int direction) {
    int idx = 0, i;
    for (i = 0; i < 6; i++)
        if (!wcs_icmp(g_sortBy, SORT_COLUMNS[i])) { idx = i; break; }
    idx = (idx + direction + 6) % 6;
    wcscpy(g_sortBy, SORT_COLUMNS[idx]);
    /* Each column gets its natural direction on landing: names A-Z,
       everything else highest-value-first. */
    g_sortDesc = wcs_icmp(g_sortBy, L"NAME") != 0;
    apply_filter_and_sort(KEEP_ANCHOR);
    save_settings();
    g_needRedraw = 1;
}

/* typed confirmation line; out gets the trimmed result ("" = cancelled) */
static void read_confirm(const wchar_t *prompt, int winW, wchar_t *out, int outn) {
    wchar_t sb[256] = L"";
    int ww, wh;
    size_t n;
    get_win_size(&ww, &wh);
    show_cursor(1);
    for (;;) {
        wchar_t full[1024];
        int k;
        swprintf(full, 1024, L"%s%s_", prompt, sb);
        fit_cell(full, 1024, full, winW);
        goto_xy(0, wh - 1);
        cons_color(C_WHITE, C_DRED); cons_write(full); cons_drawcolor();
        k = read_key();
        if (k == 13) { show_cursor(0); break; }
        if (k == 27) { show_cursor(0); sb[0] = 0; break; }
        if (k == 8) { n = wcslen(sb); if (n) sb[n - 1] = 0; }
        else if (k < 0x100 && !iswcntrl((wint_t)k) && wcslen(sb) < 255) {
            n = wcslen(sb); sb[n] = (wchar_t)k; sb[n + 1] = 0;
        }
    }
    /* trim */
    {
        wchar_t *a = sb;
        size_t e;
        while (*a == L' ' || *a == L'\t') a++;
        e = wcslen(a);
        while (e && (a[e-1] == L' ' || a[e-1] == L'\t')) e--;
        a[e] = 0;
        wcsncpy(out, a, outn - 1); out[outn - 1] = 0;
    }
}

typedef struct { int *pids; int n; } KillJob;
static DWORD WINAPI kill_thread_proc(LPVOID p) {
    KillJob *j = (KillJob*)p;
    int i;
    for (i = 0; i < j->n; i++) {
        HANDLE h;
        if ((DWORD)j->pids[i] == g_ownPid) continue;
        h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)j->pids[i]);
        if (h) { TerminateProcess(h, 1); CloseHandle(h); }
    }
    free(j->pids); free(j);
    return 0;
}
static void kill_async(const int *pids, int n) {
    KillJob *j = (KillJob*)malloc(sizeof(KillJob));
    HANDLE th;
    if (!j || n <= 0) { free(j); return; }
    j->pids = (int*)malloc((size_t)n * sizeof(int));
    if (!j->pids) { free(j); return; }
    memcpy(j->pids, pids, (size_t)n * sizeof(int));
    j->n = n;
    th = CreateThread(NULL, 0, kill_thread_proc, j, 0, NULL);
    if (th) CloseHandle(th);
    else { free(j->pids); free(j); }
}

static void do_kill_confirm(void) {
    int count = g_fullList.n;
    ProcInfo pr;
    int ww, wh, winW, k, i;
    int multi, anyProtected;
    wchar_t msg[256], conf[64];
    int doSingle = 0, doAll = 0;
    int *toKill = NULL;
    int nKill = 0, capKill = 0;

    if (count == 0 || g_selected < 0 || g_selected >= count) return;
    pr = g_fullList.v[g_selected];
    get_win_size(&ww, &wh);
    winW = ww - 1; if (winW < 70) winW = 70;
    multi = g_filter[0] && count > 1;
    anyProtected = 0;
    if (multi) {
        for (i = 0; i < count; i++)
            if (is_protected(&g_fullList.v[i])) { anyProtected = 1; break; }
    } else anyProtected = is_protected(&pr);

    if (multi) swprintf(msg, 256, L"Kill (s)elected %d or (a)ll %d? s/a/n: ", pr.pid, count);
    else swprintf(msg, 256, L"Kill PID %d (%s)? y/n: ", pr.pid, pr.name);
    fit_cell(msg, 256, msg, winW);
    goto_xy(0, wh - 1);
    cons_color(C_WHITE, C_DRED); cons_write(msg); cons_drawcolor();

    show_cursor(1);
    k = read_key();
    show_cursor(0);

    if (multi) {
        if (k == 's' || k == 'S') doSingle = 1;
        else if (k == 'a' || k == 'A') doAll = 1;
        else { g_needRedraw = 1; return; }
    } else {
        if (k == 'y' || k == 'Y') doSingle = 1;
        else { g_needRedraw = 1; return; }
    }

    if (doSingle) {
        if ((DWORD)pr.pid == g_ownPid) { g_needRedraw = 1; return; }
        if (is_protected(&pr)) {
            swprintf(msg, 256, L"CRITICAL system process! Type KILL to confirm PID %d: ", pr.pid);
            read_confirm(msg, winW, conf, 64);
            {
                wchar_t lc[64];
                wcs_tolower_buf(lc, 64, conf);
                if (wcscmp(lc, L"kill")) { g_needRedraw = 1; return; }
            }
        }
        kill_async(&pr.pid, 1);
        g_nextRefreshMs = GetTickCount64();
    } else if (doAll) {
        if (count > 50 || anyProtected || !g_filter[0] || !wcscmp(g_filter, L"*"))
            swprintf(msg, 256, L"DANGER: kill ALL %d matching '%s'? Type YES: ", count, g_filter);
        else
            swprintf(msg, 256, L"Confirm kill ALL %d? Type YES: ", count);
        read_confirm(msg, winW, conf, 64);
        {
            wchar_t lc[64];
            wcs_tolower_buf(lc, 64, conf);
            if (wcscmp(lc, L"yes")) { g_needRedraw = 1; return; }
        }
        for (i = 0; i < count; i++) {
            ProcInfo *it = &g_fullList.v[i];
            wchar_t lc[64];
            if ((DWORD)it->pid == g_ownPid) continue;
            if (is_protected(it)) {
                swprintf(msg, 256, L"Skip critical %s (PID %d)? y=skip n=force: ", it->name, it->pid);
                read_confirm(msg, winW, conf, 64);
                wcs_tolower_buf(lc, 64, conf);
                if (!wcscmp(lc, L"n") || !wcscmp(lc, L"kill")) {
                    swprintf(msg, 256, L"FORCE kill critical %s? Type KILL: ", it->name);
                    read_confirm(msg, winW, conf, 64);
                    wcs_tolower_buf(lc, 64, conf);
                    if (wcscmp(lc, L"kill")) continue;
                } else continue;
            }
            if (nKill == capKill) {
                int nc = capKill ? capKill * 2 : 64;
                int *np = (int*)realloc(toKill, (size_t)nc * sizeof(int));
                if (!np) break;
                toKill = np; capKill = nc;
            }
            toKill[nKill++] = it->pid;
        }
        kill_async(toKill, nKill);
        free(toKill);
        g_nextRefreshMs = GetTickCount64();

        /* Clear filter after mass kill */
        g_filter[0] = 0;
        g_selected = 0;
        g_scrollOffset = 0;
        apply_filter_and_sort(-1);
    }
    g_needRedraw = 1;
}

static void do_search(void) {
    int ww, wh, winW, k;
    wchar_t sb[512];
    size_t n;
    get_win_size(&ww, &wh);
    winW = ww - 1; if (winW < 70) winW = 70;
    wcscpy(sb, g_filter);
    show_cursor(1);
    for (;;) {
        wchar_t prompt[1024];
        wcscpy(g_filter, sb);
        g_selected = 0;
        g_scrollOffset = 0;
        apply_filter_and_sort(-1);
        draw();

        swprintf(prompt, 1024, L"LIVE SEARCH (* ok  Esc=cancel  Enter=done) > %s_", sb);
        fit_cell(prompt, 1024, prompt, winW);
        goto_xy(0, wh - 1);
        cons_color(C_BLACK, C_DYELLOW); cons_write(prompt); cons_drawcolor();

        k = read_key();
        if (k == 13) {
            /* trim sb into g_filter */
            wchar_t *a = sb;
            size_t e;
            while (*a == L' ' || *a == L'\t') a++;
            e = wcslen(a);
            while (e && (a[e-1] == L' ' || a[e-1] == L'\t')) e--;
            a[e] = 0;
            wcscpy(g_filter, a);
            break;
        }
        if (k == 27) { g_filter[0] = 0; break; }
        if (k == 8) { n = wcslen(sb); if (n) sb[n - 1] = 0; }
        else if (k < 0x100 && !iswcntrl((wint_t)k) && wcslen(sb) < 511) {
            n = wcslen(sb); sb[n] = (wchar_t)k; sb[n + 1] = 0;
        }
    }
    show_cursor(0);
    apply_filter_and_sort(-1);
    g_nextRefreshMs = GetTickCount64();
    g_needRedraw = 1;
}

static void do_run(void) {
    int ww, wh, winW, k;
    wchar_t sb[512] = L"";
    size_t n;
    get_win_size(&ww, &wh);
    winW = ww - 1; if (winW < 70) winW = 70;
    show_cursor(1);
    for (;;) {
        wchar_t prompt[1024];
        swprintf(prompt, 1024, L"CONSOLE RUN (Esc=cancel Enter=start) > %s", sb);
        fit_cell(prompt, 1024, prompt, winW);
        goto_xy(0, wh - 1);
        cons_color(C_BLACK, C_DGREEN); cons_write(prompt); cons_drawcolor();

        k = read_key();
        if (k == 13) {
            wchar_t *a = sb;
            size_t e;
            while (*a == L' ' || *a == L'\t') a++;
            e = wcslen(a);
            while (e && (a[e-1] == L' ' || a[e-1] == L'\t')) e--;
            a[e] = 0;
            if (a[0]) {
                HINSTANCE r = ShellExecuteW(NULL, L"open", a, NULL, NULL, SW_SHOWNORMAL);
                if ((INT_PTR)r <= 32) {
                    wchar_t err[1024];
                    swprintf(err, 1024, L"ERROR: could not start '%s' (code %d)", a, (int)(INT_PTR)r);
                    fit_cell(err, 1024, err, winW);
                    goto_xy(0, wh - 1);
                    cons_color(C_WHITE, C_DRED); cons_write(err); cons_drawcolor();
                    Sleep(2000);
                }
            }
            g_nextRefreshMs = GetTickCount64();
            break;
        }
        if (k == 27) break;
        if (k == 8) { n = wcslen(sb); if (n) sb[n - 1] = 0; }
        else if (k < 0x100 && !iswcntrl((wint_t)k) && wcslen(sb) < 511) {
            n = wcslen(sb); sb[n] = (wchar_t)k; sb[n + 1] = 0;
        }
    }
    show_cursor(0);
    g_needRedraw = 1;
}

static void show_help(void) {
    clear_all();
    cons_drawcolor();
    cons_writeln(L"WinTop keys");
    cons_writeln(L"  Up/Down        move selection");
    cons_writeln(L"  PageUp/PageDn  jump one page");
    cons_writeln(L"  Home/End       jump to first/last");
    cons_writeln(L"  Left/Right     change sort column");
    cons_writeln(L"                 (Name always starts A?Z)");
    cons_writeln(L"  r              reverse current sort");
    cons_writeln(L"  s              next sort column");
    cons_writeln(L"  Space          pause/resume");
    cons_writeln(L"  / or F3        live search (* ok)");
    cons_writeln(L"  P              toggle All/User processes");
    cons_writeln(L"  k / F9         kill selected");
    cons_writeln(L"  c / Esc        clear filter");
    cons_writeln(L"  Ctrl+R         console run (start a program)");
    cons_writeln(L"  q / F10        quit");
    cons_writeln(L"  Arrows pin the selected process at its row; c unpins.");
    cons_writeln(L"  New processes flash green, like Process Explorer.");
    cons_writeln(L"");
    cons_writeln(L"Press any key...");
    read_key();
    clear_all();
    g_needRedraw = 1;
}

static void handle_key(void) {
    int key = read_key();
    int ww, wh, maxRows, count;
    if (key == 18) { do_run(); return; }   /* Ctrl+R */

    get_win_size(&ww, &wh);
    maxRows = wh - header_lines() - 2;
    if (maxRows < 3) maxRows = 3;
    count = g_fullList.n;

    switch (key) {
    case 'q': case 'Q': case K_F10:
        g_running = 0;
        break;
    case 27: /* Esc */
        if (g_filter[0]) {
            g_filter[0] = 0; g_selected = 0; g_scrollOffset = 0;
            apply_filter_and_sort(-1); g_needRedraw = 1;
        }
        break;
    case 32: /* Space */
        g_paused = !g_paused;
        g_needRedraw = 1;
        if (!g_paused) g_nextRefreshMs = GetTickCount64();
        break;
    case K_UP:
        g_pinSelection = 1;   /* any arrow-key navigation pins the selection */
        if (g_selected > 0) {
            g_selected--;
            if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
            g_needRedraw = 1;
        }
        break;
    case K_DOWN:
        g_pinSelection = 1;
        if (g_selected < count - 1) {
            g_selected++;
            if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
            g_needRedraw = 1;
        }
        break;
    case K_PGUP:
        g_pinSelection = 1;
        g_selected -= maxRows; if (g_selected < 0) g_selected = 0;
        if (g_selected < g_scrollOffset) g_scrollOffset = g_selected;
        g_needRedraw = 1;
        break;
    case K_PGDN:
        g_pinSelection = 1;
        g_selected += maxRows;
        if (g_selected > count - 1) g_selected = count - 1 > 0 ? count - 1 : 0;
        if (g_selected >= g_scrollOffset + maxRows) g_scrollOffset = g_selected - maxRows + 1;
        g_needRedraw = 1;
        break;
    case K_HOME:
        g_pinSelection = 1;
        g_selected = 0; g_scrollOffset = 0; g_needRedraw = 1;
        break;
    case K_END:
        g_pinSelection = 1;
        g_selected = count - 1 > 0 ? count - 1 : 0;
        g_scrollOffset = count - maxRows > 0 ? count - maxRows : 0;
        g_needRedraw = 1;
        break;
    case K_LEFT:
        cycle_sort(-1);
        break;
    case K_RIGHT:
        cycle_sort(1);
        break;
    case 'k': case 'K': case K_F9:
        do_kill_confirm();
        break;
    case '/': case K_F3:
        do_search();
        break;
    case 's': case 'S': case K_F6:
        cycle_sort(1);
        break;
    case 'r': case 'R':
        g_sortDesc = !g_sortDesc;
        apply_filter_and_sort(KEEP_ANCHOR);
        save_settings();
        g_needRedraw = 1;
        break;
    case 'c': case 'C':
        g_filter[0] = 0; g_selected = 0; g_scrollOffset = 0;
        apply_filter_and_sort(-1); g_needRedraw = 1;
        break;
    case 'p': case 'P':
        g_showAll = !g_showAll;
        g_selected = 0; g_scrollOffset = 0;
        apply_filter_and_sort(-1);
        save_settings();
        g_needRedraw = 1;
        break;
    case 'h': case 'H': case K_F1:
        show_help();
        break;
    }
}

int wmain(int argc, wchar_t **argv) {
    int code = 0;
    CONSOLE_SCREEN_BUFFER_INFO bi;
    wchar_t un[256] = L"", dm[256] = L"";
    DWORD cm = 0;
    (void)argc; (void)argv;

    g_hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    g_hIn = GetStdHandle(STD_INPUT_HANDLE);
    g_ownPid = GetCurrentProcessId();
    SetConsoleTitleW(APPNAME);
    show_cursor(0);

    {
        DWORD n = 256;
        wchar_t hn[256] = L"";
        GetComputerNameW(hn, &n);
        wcsncpy(g_host, hn, 255);
    }
    GetEnvironmentVariableW(L"USERNAME", un, 256);
    GetEnvironmentVariableW(L"USERDOMAIN", dm, 256);
    swprintf(g_user, 256, L"%s\\%s", dm, un);

    InitializeCriticalSection(&g_cs);
    map_init(&g_prevCpu); map_init(&g_prevRead); map_init(&g_prevWrite);
    map_init(&g_pathCache); map_init(&g_newProcs);
    map_init(&g_prevLiveIds); map_init(&g_liveIds); map_init(&g_windowPids);
    proclist_init(&g_allProcs); proclist_init(&g_fullList);

    /* Remember the original scrollback buffer so we can restore it on exit,
       then lock the buffer to the window: no scrollbar, no scroll history. */
    if (GetConsoleScreenBufferInfo(g_hOut, &bi)) {
        g_origBufW = bi.dwSize.X; g_origBufH = bi.dwSize.Y;
        g_origAttr = bi.wAttributes;
    }
    fit_buffer_to_window();
    disable_quick_edit();

    /* Remember the console's original colors, then switch to our own palette
       and paint the whole buffer with it (stops the host's dark-blue bleed). */
    cons_drawcolor();
    clear_all();

    load_settings();
    g_lastSampleMs = GetTickCount64();

    /* Sample once on this thread BEFORE the sampler thread starts: the
       previous-sample maps are plain (non-atomic) structures, so two threads
       must never touch them at the same time. */
    sample_processes();
    g_samplerStop = 0;
    g_samplerThread = CreateThread(NULL, 0, sampler_thread_proc, NULL, 0, NULL);
    g_nextRefreshMs = GetTickCount64();

    apply_filter_and_sort(KEEP_ANCHOR);
    draw();
    g_needRedraw = 0;

    while (g_running) {
        int ww, wh;
        unsigned long long nowMs;
        get_win_size(&ww, &wh);
        if (ww != g_lastWinW || wh != g_lastWinH) {
            g_lastWinW = ww; g_lastWinH = wh;
            fit_buffer_to_window();
            /* Wipe on resize: narrowing can leave wrapped remnants past the
               new width that a repaint would not cover. */
            clear_all();
            g_needRedraw = 1;
        }
        while (_kbhit()) handle_key();
        nowMs = GetTickCount64();
        if (!g_paused && nowMs >= g_nextRefreshMs) {
            apply_filter_and_sort(KEEP_ANCHOR);
            g_nextRefreshMs = nowMs + 5000;
            g_needRedraw = 1;
        }
        if (g_needRedraw) {
            draw();
            g_needRedraw = 0;
        }
        Sleep(15);
    }

    show_cursor(1);
    InterlockedExchange(&g_samplerStop, 1);
    if (g_samplerThread) {
        WaitForSingleObject(g_samplerThread, 2000);
        CloseHandle(g_samplerThread);
    }
    /* Persist preferences, then restore the console to how we found it:
       original colors, original buffer size, clean screen. */
    save_settings();
    restore_console_mode();
    cons_color(g_origAttr & 15, (g_origAttr >> 4) & 15);
    if (g_bufferLocked) {
        COORD sz; sz.X = (SHORT)g_origBufW; sz.Y = (SHORT)g_origBufH;
        SetConsoleScreenBufferSize(g_hOut, sz);
    }
    clear_all();
    cons_color(g_origAttr & 15, (g_origAttr >> 4) & 15);

    {
        wchar_t done[512];
        cons_writeln(L"");
        cons_color(C_GREEN, (g_origAttr >> 4) & 15);
        swprintf(done, 512, L"%s ended. Press any key to close...", APPNAME);
        cons_writeln(done);
        cons_color(g_origAttr & 15, (g_origAttr >> 4) & 15);
        if (!GetConsoleMode(g_hIn, &cm)) {
            wchar_t dummy[256];   /* input redirected: read a line instead */
            if (!fgetws(dummy, 256, stdin)) { (void)0; }
        } else {
            read_key();
        }
    }

    DeleteCriticalSection(&g_cs);
    map_free(&g_prevCpu); map_free(&g_prevRead); map_free(&g_prevWrite);
    map_free(&g_pathCache); map_free(&g_newProcs);
    map_free(&g_prevLiveIds); map_free(&g_liveIds); map_free(&g_windowPids);
    proclist_free(&g_allProcs); proclist_free(&g_fullList);
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
Write-Host "  Bootstrap: building '$ProjectName' (native C console app, zero .NET)" -ForegroundColor Cyan
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
Write-Stage '3/7' 'Detecting a C compiler (MSVC, gcc, or portable Zig)'
$Script:Compiler=Find-Compiler
Write-Ok "Using: $($Script:Compiler.Desc)"
$Script:StageName='Writing sources'
Write-Stage '4/7' 'Writing the C application sources'
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
