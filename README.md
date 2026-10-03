# WinTop

**WinTop** is a lightweight, interactive terminal process monitor and resource dashboard for Windows, inspired by `top` and `htop`. Pick your implementation — C, C++, or C# — and build it with the included zero-dependency PowerShell script. Every build compiles to a self-contained, single-file native executable (`WinTop.exe`) that runs on any modern Windows system with no administrative elevation.

![WinTop Screenshot](Screenshots/2026-10-02_185441.png)

---

## Build options

| Script | Language | Toolchain (auto-detected) | Output |
| :--- | :--- | :--- | :--- |
| `Build-WinTop-c.ps1` | C | MSVC → gcc → portable Zig | ~200 KB–3 MB native exe, no runtimes at all |
| `Build-WinTop-cpp.ps1` | C++ | MSVC → g++ → portable Zig | ~1–3 MB native exe, no .NET |
| `Build-WinTop.cs.ps1` | C# (.NET 8) | User-local .NET 8 SDK (downloaded automatically if missing) | ~70 MB+ self-contained single file |

All three builds share the same UI, hotkeys, features, and settings file (`%LOCALAPPDATA%\WinTop\settings.cfg`).

The C and C++ scripts need no SDK: they use MSVC if you have Visual Studio, a MinGW gcc/g++ on `PATH` if you have one, and otherwise download a portable Zig toolchain into your user profile (no admin rights, no system changes) to compile a native Windows binary.

> **Which to pick?** C++ is the best balance — tiny native exe like the C build, but far easier to maintain and extend. The C build is for minimalists who want the smallest possible binary; the C# build is for .NET shops.

---

## Features

- **System Resource Metrics:** Real-time visual meters for CPU utilization, physical memory usage, and fixed storage drive capacities.
- **Process Activity Tracking:** Live updates for PID, CPU%, Memory (working set MB), and per-process disk I/O read/write speeds (MB/s) via native Win32 APIs.
- **Interactive Navigation & Sorting:** Sort by CPU, Memory, Read, Write, Name, or PID with bi-directional ordering.
- **Dynamic Search & Filtering:** Filter running tasks in real time by name, PID, or executable path, with `*` wildcard support.
- **All / User views:** Toggle between every process and just your own (`P`). Apps you launch are correctly detected as yours — even GUI programs living in System32 like `mstsc` — while Windows plumbing (services, `sihost`, `ctfmon`, …) stays hidden.
- **Selection pinning:** Arrow-key navigation pins the selected process at its row while the rest of the list keeps auto-sorting around it, so the kill target never slides out from under the cursor.
- **New-process highlight:** Newly started processes flash green for 10 seconds, Process Explorer-style.
- **Safe Process Termination:** In-app process kill with critical-system-process guards and typed confirmations (mass-kill of filtered results supported).
- **Quick Command Runner:** Launch programs directly from the dashboard via a built-in run console.
- **Persistent Preferences:** View mode, sort column, and sort direction auto-save to `%LOCALAPPDATA%\WinTop\settings.cfg` (hand-editable).
- **Zero Configuration Setup:** Each script validates disk space, provisions its toolchain if needed, writes the sources, compiles, and launches — in one step.

---

## Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| `Up` / `Down` | Move process selection (pins it at its row) |
| `PageUp` / `PageDn` | Scroll process list by page |
| `Home` / `End` | Jump to top / bottom of process list |
| `Left` / `Right` | Cycle sort column (`CPU` → `MEM` → `R-MB/s` → `W-MB/s` → `Name` → `PID`) |
| `s` / `F6` | Advance to next sort column |
| `r` | Reverse current sort direction |
| `/` or `F3` | Live search / filter (supports `*` wildcards) |
| `c` / `Esc` | Clear search filter (also unpins selection) |
| `P` | Toggle between **All** and **User-only** processes |
| `Space` | Pause / resume background sampling |
| `k` / `F9` | Kill selected process (or batch-kill filtered results) |
| `Ctrl + R` | Open run dialog to launch a program |
| `h` / `F1` | Show help overlay |
| `q` / `F10` | Exit WinTop |

---

## Quick Start

1. Open PowerShell (Windows PowerShell 5.1 or PowerShell 7+; no admin rights required).
2. Run one of the build scripts:

```powershell
.\Build-WinTop-c.ps1    # pure C — smallest binary, zero dependencies
```

```powershell
.\Build-WinTop-cpp.ps1  # C++ — recommended balance of size and maintainability
```

```powershell
.\Build-WinTop.cs.ps1   # C# / .NET 8 — needs nothing pre-installed, SDK is fetched for you
```

Each script builds `WinTop.exe` in a project folder next to the script and launches it when done.

---

## License

See [LICENSE](LICENSE).
