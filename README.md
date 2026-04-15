# 1stProtect App

A small dual-service Windows application written in Go, built as a test target for QA automation exercises.

## Services

- **1stProtectLogger** — writes a timestamped, log-level-tagged line to `%PROGRAMDATA%\1stProtect\app.log` every 5 seconds.
- **1stProtectMonitor** — exposes a `/health` HTTP endpoint on a random port that reports the Logger's real-time service state (`Running` / `Stopped`).

## Build

```powershell
.\build.ps1
```

Outputs a signed WiX Burn bootstrapper to `../artifacts/1stProtectInstaller.exe`.  
Requires: Go toolchain, WiX v4 (`dotnet tool install --global wix`), PowerShell 5+.

## Test Suite

See [`fp_auto`](https://github.com/asafweiss/fp_auto) — the companion QA automation repo.
