#Requires -RunAsAdministrator
<#
Prepare a Windows 10 x64 Proxmox VM as a reusable BinCan/Frida template.

Run in an elevated PowerShell:

  Set-ExecutionPolicy -Scope Process Bypass
  .\scripts\provision_windows_template.ps1

Optionally build the current checkout's Frida-enabled agent:

  .\scripts\provision_windows_template.ps1 -RepoPath C:\src\bincan -BuildAgent

After validating the VM, generalise and shut it down for conversion to a
Proxmox template:

  .\scripts\provision_windows_template.ps1 -Seal

Sogen is intentionally not installed here. It is a Linux-side PE emulator;
native Windows workers use Frida.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\BinCan",
    [string]$RepoPath = "",
    [switch]$BuildAgent,
    [switch]$Seal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$GoVersion = "1.25.12"
$GoSha256 = "45bc4ffd130e778374818551790abc2b4378dc5e89e46fcd114627ec9ebc1687"
$MsysVersion = "20260611"
$MsysSha256 = "c105946e64e08f099ac0e4647461ce762b95333ad211777666476a9a41451d65"
$FridaVersion = "17.14.1"
$FridaSha256 = "abfa7443458472c6e5c5e2c59162eaa13495d52b965a2e36a69d27e994ecb845"

$MsysRoot = "C:\msys64"
$FridaRoot = Join-Path $InstallRoot "frida-devkit"
$DownloadRoot = Join-Path $env:TEMP "bincan-template"

function Invoke-Checked {
    param([string]$FilePath, [string[]]$ArgumentList)
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "$FilePath exited with code $($process.ExitCode)"
    }
}

function Get-VerifiedFile {
    param([string]$Uri, [string]$Destination, [string]$Sha256)
    if (-not (Test-Path $Destination)) {
        Write-Host "Downloading $Uri"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Destination).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
        Remove-Item -Force $Destination
        throw "Checksum mismatch for $Destination"
    }
}

New-Item -ItemType Directory -Force -Path $InstallRoot, $DownloadRoot | Out-Null

Write-Host "==> QEMU guest agent"
$qemuService = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if (-not $qemuService) {
    $qemuMsi = Get-Volume |
        Where-Object { $_.DriveType -eq "CD-ROM" -and $_.DriveLetter } |
        ForEach-Object {
            Get-ChildItem "$($_.DriveLetter):\" -Filter "qemu-ga-x86_64.msi" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } |
        Select-Object -First 1
    if (-not $qemuMsi) {
        throw "Mount virtio-win.iso in Proxmox; qemu-ga-x86_64.msi was not found."
    }
    Invoke-Checked "msiexec.exe" @("/i", $qemuMsi.FullName, "/qn", "/norestart")
}
Set-Service -Name "QEMU-GA" -StartupType Automatic
Start-Service -Name "QEMU-GA"

Write-Host "==> Go $GoVersion"
$goExe = "C:\Program Files\Go\bin\go.exe"
$installedGo = if (Test-Path $goExe) { & $goExe version } else { "" }
if ($installedGo -notmatch "go$([regex]::Escape($GoVersion))\b") {
    $goMsi = Join-Path $DownloadRoot "go$GoVersion.windows-amd64.msi"
    Get-VerifiedFile `
        "https://go.dev/dl/go$GoVersion.windows-amd64.msi" `
        $goMsi `
        $GoSha256
    Invoke-Checked "msiexec.exe" @("/i", $goMsi, "/qn", "/norestart")
}

Write-Host "==> MSYS2 UCRT64 compiler"
if (-not (Test-Path "$MsysRoot\usr\bin\bash.exe")) {
    $msysInstaller = Join-Path $DownloadRoot "msys2-base-x86_64-$MsysVersion.sfx.exe"
    Get-VerifiedFile `
        "https://github.com/msys2/msys2-installer/releases/download/2026-06-11/msys2-base-x86_64-$MsysVersion.sfx.exe" `
        $msysInstaller `
        $MsysSha256
    Invoke-Checked $msysInstaller @("-y", "-oC:\")
}
Invoke-Checked "$MsysRoot\usr\bin\bash.exe" @(
    "-lc",
    "pacman --noconfirm -Sy --needed mingw-w64-ucrt-x86_64-gcc"
)

Write-Host "==> Frida Core devkit $FridaVersion"
if (-not (Test-Path "$FridaRoot\frida-core.h") -or -not (Test-Path "$FridaRoot\frida-core.lib")) {
    $fridaArchive = Join-Path $DownloadRoot "frida-core-devkit-$FridaVersion-windows-x86_64.tar.xz"
    Get-VerifiedFile `
        "https://github.com/frida/frida/releases/download/$FridaVersion/frida-core-devkit-$FridaVersion-windows-x86_64.tar.xz" `
        $fridaArchive `
        $FridaSha256
    New-Item -ItemType Directory -Force -Path $FridaRoot | Out-Null
    Invoke-Checked "tar.exe" @("-xf", $fridaArchive, "-C", $FridaRoot)
}

# frida-go asks the GNU linker for -lfrida-core. The Windows devkit names the
# compatible static archive frida-core.lib, so expose the filename GCC expects.
Copy-Item "$FridaRoot\frida-core.lib" "$FridaRoot\libfrida-core.a" -Force

if ($BuildAgent) {
    if (-not $RepoPath -or -not (Test-Path (Join-Path $RepoPath "go.mod"))) {
        throw "-BuildAgent requires -RepoPath pointing to the BinCan checkout."
    }
    Write-Host "==> Frida-enabled BinCan agent"
    $binDir = Join-Path $RepoPath "bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    $fridaFlags = ($FridaRoot -replace "\\", "/")
    $env:CC = "$MsysRoot\ucrt64\bin\gcc.exe"
    $env:CGO_ENABLED = "1"
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    $env:CGO_CFLAGS = "-I$fridaFlags"
    $env:CGO_LDFLAGS = "-L$fridaFlags -static-libgcc"

    Push-Location $RepoPath
    try {
        & $goExe build -tags frida -o "bin\agent-windows.exe" ".\cmd\agent"
        if ($LASTEXITCODE -ne 0) {
            throw "Frida-enabled Windows agent build failed."
        }
        & $goExe version -m "bin\agent-windows.exe"
    }
    finally {
        Pop-Location
    }
}

Write-Host "==> verification"
& $goExe version
& "$MsysRoot\ucrt64\bin\gcc.exe" --version | Select-Object -First 1
if (-not (Test-Path "$FridaRoot\frida-core.h") -or
    -not (Test-Path "$FridaRoot\libfrida-core.a") -or
    (Get-Service -Name "QEMU-GA").Status -ne "Running") {
    throw "Template verification failed."
}

if ($Seal) {
    Write-Host "==> sealing VM with Sysprep"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $InstallRoot "work")
    & "$env:WINDIR\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown /mode:vm
    if ($LASTEXITCODE -ne 0) {
        throw "Sysprep failed with code $LASTEXITCODE"
    }
    return
}

Write-Host ""
Write-Host "Windows Frida template prerequisites are ready."
Write-Host "Validate the VM, then rerun this script with -Seal."
