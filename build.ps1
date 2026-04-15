$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$BuildDir = Join-Path $ProjectDir "build"
$PackagingDir = Join-Path $ProjectDir "packaging"

if (-Not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir | Out-Null }

Write-Host "0. Bootstrapping WiX v4 toolchain..."
$DotnetToolsPath = "$env:USERPROFILE\.dotnet\tools"
if ($env:PATH -notmatch [regex]::Escape($DotnetToolsPath)) {
    $env:PATH += ";$DotnetToolsPath"
}
try {
    $wixVersion = (wix --version 2>$null)
    if ($wixVersion -and $wixVersion -match "^4\.") {
        Write-Host "WiX v4 is installed."
        wix extension add -g WixToolset.Bal.wixext/4.0.5 2>$null
    } else {
        dotnet tool uninstall --global wix 2>$null | Out-Null
        Write-Host "Installing WiX Toolset v4.0.5 via dotnet..."
        dotnet tool install --global wix --version 4.0.5
        wix extension add -g WixToolset.Bal.wixext/4.0.5
    }
} catch {
    Write-Error "Failed to install WiX."
    exit 1
}

Write-Host "1. Fetching Go dependencies..."
$GoPath = "C:\Program Files\Go\bin"
if ((Test-Path $GoPath) -and ($env:PATH -notmatch [regex]::Escape($GoPath))) {
    $env:PATH += ";$GoPath"
}
Push-Location $ProjectDir
go mod tidy
Pop-Location

Write-Host "2. Building Go applications..."
$LoggerExePath = Join-Path $BuildDir "logger.exe"
$MonitorExePath = Join-Path $BuildDir "monitor.exe"
$Env:GOARCH="amd64"
$Env:GOOS="windows"
Push-Location $ProjectDir
go build -o $LoggerExePath .\cmd\logger\main.go
go build -o $MonitorExePath .\cmd\monitor\main.go
Pop-Location

Write-Host "3. Generating Hashes..."
Set-Content -Path (Join-Path $BuildDir "logger.exe.sha256") -Value (Get-FileHash -Path $LoggerExePath -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $BuildDir "monitor.exe.sha256") -Value (Get-FileHash -Path $MonitorExePath -Algorithm SHA256).Hash

Write-Host "4. Generating Local Certificate for Signing..."
$CertValue = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.Subject -match "1stProtectTest" } | Select-Object -First 1
if (-not $CertValue) {
    Write-Host "Generating Self-Signed Cert..."
    $CertValue = New-SelfSignedCertificate -Subject "CN=1stProtectTest" -Type CodeSigningCert -CertStoreLocation "Cert:\CurrentUser\My"
}

Write-Host "5. Signing executables..."
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $LoggerExePath -HashAlgorithm SHA256
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $MonitorExePath -HashAlgorithm SHA256

Write-Host "6. Building MSI using WiX v4..."
$MsiPath = Join-Path $BuildDir "app.msi"
Push-Location $PackagingDir
wix build -arch x64 -o $MsiPath Product.wxs
Pop-Location

Write-Host "7. Signing MSI..."
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $MsiPath -HashAlgorithm SHA256

Write-Host "8. Building EXE Bootstrapper..."
$SetupExePath = Join-Path $BuildDir "1stProtectInstaller.exe"
Push-Location $PackagingDir
wix build -ext WixToolset.Bal.wixext/4.0.5 -o $SetupExePath Bundle.wxs
Pop-Location

Write-Host "9. Signing EXE Bootstrapper (detach/reattach workflow)..."
# Direct signing corrupts Burn's embedded container offsets.
# The proper workflow: detach the engine, sign it, reattach, then sign the final bundle.
$EnginePath = Join-Path $BuildDir "engine.exe"
$SignedSetupExePath = Join-Path $BuildDir "1stProtectInstaller.signed.exe"

# 9a. Detach the Burn engine
wix burn detach $SetupExePath -engine $EnginePath

# 9b. Sign the detached engine
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $EnginePath -HashAlgorithm SHA256

# 9c. Reattach the signed engine (recalculates internal offsets)
wix burn reattach $SetupExePath -engine $EnginePath -o $SignedSetupExePath

# 9d. Sign the final reattached bundle
Set-AuthenticodeSignature -Certificate $CertValue -FilePath $SignedSetupExePath -HashAlgorithm SHA256

# Replace the unsigned EXE with the signed one
Move-Item -Force $SignedSetupExePath $SetupExePath
Remove-Item -Force $EnginePath -ErrorAction SilentlyContinue

$SetupHash = (Get-FileHash -Path $SetupExePath -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $BuildDir "1stProtectInstaller.exe.sha256") -Value $SetupHash

Write-Host "Build successfully completed! Setup File: $SetupExePath"
