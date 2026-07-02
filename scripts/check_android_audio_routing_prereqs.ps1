param(
    [int]$Port = 47820
)

$ErrorActionPreference = "Continue"

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutter = "E:\Programs\flutter\bin\flutter.bat"
if (-not (Test-Path $flutter)) {
    $flutter = "flutter"
}

Write-Output "# Android Audio Routing Hardware Prerequisite Check"
Write-Output ""
Write-Output "Repository: $repoRoot"
Write-Output "Port: $Port"
Write-Output ""

Write-Output "## Flutter Devices"
try {
    & $flutter devices
} catch {
    Write-Output "Flutter device check failed: $($_.Exception.Message)"
}
Write-Output ""

Write-Output "## ADB"
$adb = Get-Command adb -ErrorAction SilentlyContinue
$adbPath = $null
if ($adb) {
    $adbPath = $adb.Source
} else {
    $candidateSdkRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $candidateSdkRoots += $env:ANDROID_HOME
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
        $candidateSdkRoots += $env:ANDROID_SDK_ROOT
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidateSdkRoots += (Join-Path $env:LOCALAPPDATA "Android\Sdk")
    }
    $candidateSdkRoots += "E:\Programs\Android\Sdk"
    $candidateSdkRoots += "C:\Android\Sdk"

    foreach ($root in $candidateSdkRoots) {
        $candidate = Join-Path $root "platform-tools\adb.exe"
        if (Test-Path $candidate) {
            $adbPath = $candidate
            break
        }
    }
}

if ($adbPath) {
    Write-Output "adb: $adbPath"
    try {
        & $adbPath devices
    } catch {
        Write-Output "adb devices failed: $($_.Exception.Message)"
    }
} else {
    Write-Output "adb: not found on PATH"
    Write-Output "Install Android platform-tools or add adb to PATH before hardware validation."
}
Write-Output ""

Write-Output "## Virtual Network IPv4 Candidates"
try {
    $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -like "100.*" -or
            $_.InterfaceAlias -match "Tailscale|EasyTier|ZeroTier|WireGuard|VPN"
        } |
        Select-Object InterfaceAlias, IPAddress, PrefixLength
    if ($addresses) {
        $addresses | Format-Table -AutoSize | Out-String | Write-Output
    } else {
        Write-Output "No obvious Tailscale/EasyTier/VPN IPv4 address found."
    }
} catch {
    Write-Output "Network adapter check failed: $($_.Exception.Message)"
}
Write-Output ""

Write-Output "## Local Port Listener Check"
try {
    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listeners) {
        $listeners | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize | Out-String | Write-Output
    } else {
        Write-Output "No TCP listener currently detected on port $Port."
        Write-Output "Start Windows receiver mode before Android pairing."
    }
} catch {
    Write-Output "TCP listener check failed: $($_.Exception.Message)"
}
Write-Output ""

Write-Output "## Next Step"
Write-Output "After Windows receiver and Android device are ready, run:"
Write-Output ".\scripts\collect_android_audio_routing_evidence.ps1 -WindowsIp ""<windows-virtual-network-ip>"" -Port $Port -CapturableSource ""<capturable-source-app>"" -UnsupportedSource ""<unsupported-source-app>"""
