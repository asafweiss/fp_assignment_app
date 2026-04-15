<#
.SYNOPSIS
    Build, hash, sign, and package the 1stProtect application.

.DESCRIPTION
    End-to-end build pipeline for the 1stProtect dual-service Windows application.
    Produces a signed Burn bootstrapper EXE that installs both Windows services
    (1stProtectLogger and 1stProtectMonitor) via a WiX MSI.

    Steps
    -----
    0. Bootstrap the WiX v4 dotnet global tool (install or verify)
    1. Fetch Go module dependencies (go mod tidy)
    2. Cross-compile both Go services for windows/amd64
    3. Generate SHA256 hashes for the compiled binaries
    4. Create (or reuse) a self-signed code-signing certificate
    5. Sign logger.exe and monitor.exe with the certificate
    6. Build the WiX MSI from Product.wxs
    7. Sign the MSI
    8. Build the WiX Burn bootstrapper EXE from Bundle.wxs
    9. Sign the bootstrapper using the detach/reattach workflow
       (direct signing corrupts Burn's internal offset table)
   10. Hash the final signed bootstrapper

    Requirements
    ------------
    - Go toolchain (https://go.dev/dl/)
    - .NET SDK (for `dotnet tool install --global wix`)
    - PowerShell 7+ (Set-AuthenticodeSignature requires it for .msi files)

    Output
    ------
    ../artifacts/           ← shared folder at the monorepo root
    ├── logger.exe                    ← compiled Logger service
    ├── logger.exe.sha256
    ├── monitor.exe                   ← compiled Monitor service
    ├── monitor.exe.sha256
    ├── app.msi                       ← WiX MSI (intermediate; embedded in EXE)
    ├── 1stProtectInstaller.exe       ← final signed Burn bootstrapper
    └── 1stProtectInstaller.exe.sha256
#>

$ErrorActionPreference = "Stop"

$ProjectDir   = $PSScriptRoot
# Artifacts are published to the shared sibling folder so the test suite
# can locate them without needing any environment variable overrides.
$BuildDir = Join-Path (Split-Path $PSScriptRoot -Parent) "artifacts"
if (-Not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null }
$PackagingDir = Join-Path $ProjectDir "packaging"

Write-Host "Artifacts output directory: $BuildDir"

# ---------------------------------------------------------------------------
# Step 0: Bootstrap WiX v4 toolchain
# ---------------------------------------------------------------------------
Write-Host "0. Bootstrapping WiX v4 toolchain..."

# Ensure the dotnet global tools path is on PATH (it may not be in CI environments)
$DotnetToolsPath = "$env:USERPROFILE\.dotnet\tools"
if ($env:PATH -notmatch [regex]::Escape($DotnetToolsPath)) {
    $env:PATH += ";$DotnetToolsPath"
}

try {
    $wixVersion = (wix --version 2>$null)
    if ($wixVersion -and $wixVersion -match "^4\.") {
        Write-Host "  WiX v4 already installed ($wixVersion)"
        # Ensure the Burn extension is present (needed for Bundle.wxs)
        wix extension add -g WixToolset.Bal.wixext/4.0.5 2>$null
    } else {
        # Wrong version or not installed — install 4.0.5 pinned for reproducibility
        dotnet tool uninstall --global wix 2>$null | Out-Null
        Write-Host "  Installing WiX Toolset v4.0.5 via dotnet..."
        dotnet tool install --global wix --version 4.0.5
        wix extension add -g WixToolset.Bal.wixext/4.0.5
    }
} catch {
    Write-Error "Failed to install WiX. Ensure the .NET SDK is installed."
    exit 1
}

# ---------------------------------------------------------------------------
# Step 1: Fetch Go dependencies
# ---------------------------------------------------------------------------
Write-Host "1. Fetching Go dependencies..."

# Add Go binary directory to PATH if it's not already present
$GoPath = "C:\Program Files\Go\bin"
if ((Test-Path $GoPath) -and ($env:PATH -notmatch [regex]::Escape($GoPath))) {
    $env:PATH += ";$GoPath"
}

Push-Location $ProjectDir
go mod tidy
Pop-Location

# ---------------------------------------------------------------------------
# Step 2: Compile the Go services
# ---------------------------------------------------------------------------
Write-Host "2. Building Go applications..."

$LoggerExePath  = Join-Path $BuildDir "logger.exe"
$MonitorExePath = Join-Path $BuildDir "monitor.exe"

# Target windows/amd64 explicitly so the build works on any host OS/arch
$Env:GOARCH = "amd64"
$Env:GOOS   = "windows"

Push-Location $ProjectDir
go build -o $LoggerExePath  .\cmd\logger\main.go
go build -o $MonitorExePath .\cmd\monitor\main.go
Pop-Location

# ---------------------------------------------------------------------------
# Step 3: Hash the compiled binaries
# ---------------------------------------------------------------------------
Write-Host "3. Generating SHA256 hashes..."

# Hashes are stored next to each binary.  The test suite reads these files from
# the controller and compares them against hashes computed on the DUT to verify
# that the installer has not tampered with or corrupted the binaries.
Set-Content -Path (Join-Path $BuildDir "logger.exe.sha256")  -Value (Get-FileHash -Path $LoggerExePath  -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $BuildDir "monitor.exe.sha256") -Value (Get-FileHash -Path $MonitorExePath -Algorithm SHA256).Hash

# ---------------------------------------------------------------------------
# Step 4: Create (or reuse) a self-signed code-signing certificate
# ---------------------------------------------------------------------------
Write-Host "4. Setting up code-signing certificate..."

$CertValue = Get-ChildItem -Path Cert:\CurrentUser\My |
    Where-Object { $_.Subject -match "1stProtectTest" } |
    Select-Object -First 1

if (-not $CertValue) {
    Write-Host "  Generating self-signed certificate (CN=1stProtectTest)..."
    $CertValue = New-SelfSignedCertificate `
        -Subject "CN=1stProtectTest" `
        -Type CodeSigningCert `
        -CertStoreLocation "Cert:\CurrentUser\My"
}

# ---------------------------------------------------------------------------
# Step 5: Sign the compiled executables
# ---------------------------------------------------------------------------
Write-Host "5. Signing executables..."

Set-AuthenticodeSignature -Certificate $CertValue -FilePath $LoggerExePath  -HashAlgorithm SHA256
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $MonitorExePath -HashAlgorithm SHA256

# ---------------------------------------------------------------------------
# Step 6: Build the WiX MSI
# ---------------------------------------------------------------------------
Write-Host "6. Building MSI (WiX v4)..."

$MsiPath = Join-Path $BuildDir "app.msi"
Push-Location $PackagingDir
# Product.wxs defines the component layout, install paths, and service configuration
wix build -arch x64 -o $MsiPath Product.wxs
Pop-Location

# ---------------------------------------------------------------------------
# Step 7: Sign the MSI
# ---------------------------------------------------------------------------
Write-Host "7. Signing MSI..."

Set-AuthenticodeSignature -Certificate $CertValue -FilePath $MsiPath -HashAlgorithm SHA256

# ---------------------------------------------------------------------------
# Step 8: Build the Burn bootstrapper (EXE wrapper around the MSI)
# ---------------------------------------------------------------------------
Write-Host "8. Building Burn bootstrapper (EXE)..."

$SetupExePath = Join-Path $BuildDir "1stProtectInstaller.exe"
Push-Location $PackagingDir
# Bundle.wxs wraps the MSI with Burn, adds the LOG_LEVEL variable, and defines
# the install/uninstall UI behaviour
wix build -ext WixToolset.Bal.wixext/4.0.5 -o $SetupExePath Bundle.wxs
Pop-Location

# ---------------------------------------------------------------------------
# Step 9: Sign the Burn bootstrapper using the detach/reattach workflow
# ---------------------------------------------------------------------------
Write-Host "9. Signing Burn bootstrapper..."

# WHY NOT DIRECT SIGNING:
# Burn bootstrappers contain an embedded container whose byte offsets are baked
# into the EXE at build time.  Appending an Authenticode signature shifts those
# offsets, causing the bootstrapper to corrupt or crash at runtime.
# The correct approach is to:
#   a) Detach the Burn engine (separating it from the container)
#   b) Sign the engine (a standalone PE — safe to sign directly)
#   c) Reattach the signed engine (recalculates and updates the offsets)
#   d) Sign the final bundle EXE

$EnginePath       = Join-Path $BuildDir "engine.exe"
$SignedSetupExePath = Join-Path $BuildDir "1stProtectInstaller.signed.exe"

# 9a. Detach the engine from the bundle
wix burn detach $SetupExePath -engine $EnginePath

# 9b. Sign the detached engine
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $EnginePath -HashAlgorithm SHA256

# 9c. Reattach the signed engine (recalculates internal offsets)
wix burn reattach $SetupExePath -engine $EnginePath -o $SignedSetupExePath

# 9d. Sign the final reattached bundle
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $SignedSetupExePath -HashAlgorithm SHA256

# Replace the unsigned EXE with the signed one; clean up the intermediate engine file
Move-Item -Force $SignedSetupExePath $SetupExePath
Remove-Item -Force $EnginePath -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Step 10: Hash the final installer
# ---------------------------------------------------------------------------
$SetupHash = (Get-FileHash -Path $SetupExePath -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $BuildDir "1stProtectInstaller.exe.sha256") -Value $SetupHash

Write-Host ""
Write-Host "Build complete!"
Write-Host "  Installer : $SetupExePath"
Write-Host "  Hash      : $SetupHash"
