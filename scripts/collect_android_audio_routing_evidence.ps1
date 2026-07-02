param(
    [string]$WindowsIp = "",
    [int]$Port = 47820,
    [string]$AndroidDevice = "",
    [string]$CapturableSource = "",
    [string]$UnsupportedSource = "",
    [string]$DisconnectResult = "",
    [string]$Notes = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$evidenceDir = Join-Path $repoRoot "validation\android-audio-routing\$timestamp"
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$reportPath = Join-Path $evidenceDir "hardware-validation-report.md"
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

$androidVersion = ""
$androidModel = ""
if ($adbPath) {
    try {
        $androidVersion = (& $adbPath shell getprop ro.build.version.release 2>$null | Out-String).Trim()
        $androidModel = (& $adbPath shell getprop ro.product.model 2>$null | Out-String).Trim()
        & $adbPath logcat -d -v time > (Join-Path $evidenceDir "android-logcat.txt")
        & $adbPath shell screencap -p /sdcard/audioshare-validation.png | Out-Null
        & $adbPath pull /sdcard/audioshare-validation.png (Join-Path $evidenceDir "android-screenshot.png") | Out-Null
    } catch {
        Set-Content -Path (Join-Path $evidenceDir "adb-capture-error.txt") -Value $_.Exception.Message
    }
}

$report = @'
# Android Audio Routing Hardware Validation Report

Date: __DATE__

This report is the evidence capture target for
`docs/android-audio-routing-validation-checklist.md`.

## Environment

- Windows virtual-network IP: __WINDOWS_IP__
- Port: __PORT__
- Android device: __ANDROID_DEVICE__
- ADB path: __ADB_PATH__
- ADB model: __ANDROID_MODEL__
- ADB Android version: __ANDROID_VERSION__
- Capturable source app: __CAPTURABLE_SOURCE__
- Unsupported/protected source app: __UNSUPPORTED_SOURCE__

## Required Observations

Mark each line with observed values before considering the goal complete.

- [ ] Android reached `paired` after `Hello` / `Pair` / `PairAccepted` / `StartStream`.
- [ ] Android MediaProjection authorized.
- [ ] Android AudioRecord capturing.
- [ ] Android `PCM frames` increased above zero: ______
- [ ] Android `Opus frames` increased above zero: ______
- [ ] Android `UDP packets sent` increased above zero: ______
- [ ] Windows `UDP packets received` increased above zero: ______
- [ ] Windows playback active.
- [ ] Windows `playedFrames` increased above zero: ______
- [ ] Audio heard from selected Windows output device.
- [ ] Non-default output device routing checked when available.
- [ ] `Test connection` remained reachability-only, not stream success.

## Unsupported Capture Result

- [ ] Unsupported/protected source did not show false streaming success.
- [ ] Android showed zero-frame or capture-empty diagnostics.
- [ ] UI distinguished unsupported capture from network failure.

## Disconnect Result

__DISCONNECT_RESULT__

- [ ] Receiver/network interruption produced missed heartbeat warnings.
- [ ] Android stopped AudioRecord capture and UDP sending after timeout.
- [ ] Android state changed to disconnected.
- [ ] Foreground service and notification cleared.

## Compatibility Policy

- [ ] UI/docs do not claim guaranteed phone-speaker mute for arbitrary third-party apps.
- [ ] Best-effort audio-focus behavior is documented honestly.

## Captured Files

- `android-logcat.txt` if ADB was available.
- `android-screenshot.png` if ADB screenshot capture succeeded.
- Any manually added Windows screenshots or audio-device proof files.

## Notes

__NOTES__
'@

$replacements = @{
    "__DATE__" = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
    "__WINDOWS_IP__" = $WindowsIp
    "__PORT__" = $Port.ToString()
    "__ANDROID_DEVICE__" = $AndroidDevice
    "__ADB_PATH__" = if ($adbPath) { $adbPath } else { "" }
    "__ANDROID_MODEL__" = $androidModel
    "__ANDROID_VERSION__" = $androidVersion
    "__CAPTURABLE_SOURCE__" = $CapturableSource
    "__UNSUPPORTED_SOURCE__" = $UnsupportedSource
    "__DISCONNECT_RESULT__" = $DisconnectResult
    "__NOTES__" = $Notes
}

foreach ($key in $replacements.Keys) {
    $report = $report.Replace($key, $replacements[$key])
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($reportPath, $report, $utf8NoBom)

Write-Output "Created hardware validation evidence folder: $evidenceDir"
Write-Output "Fill the report and attach screenshots/logs before marking the routing goal complete."
