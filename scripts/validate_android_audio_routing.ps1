$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutter = "E:\Programs\flutter\bin\flutter.bat"
$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo) {
    $cargoPath = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
    if (Test-Path $cargoPath) {
        $cargo = Get-Item $cargoPath
    }
}

if (-not (Test-Path $flutter)) {
    throw "Flutter SDK not found at $flutter"
}

if (-not $cargo) {
    throw "Cargo was not found on PATH or at $env:USERPROFILE\.cargo\bin\cargo.exe"
}

Push-Location $repoRoot
try {
    & $cargo.Source fmt --manifest-path crates/audioshare_core/Cargo.toml -- --check
    & $cargo.Source test --manifest-path crates/audioshare_core/Cargo.toml
    & $flutter analyze
    & $flutter test
    & $flutter build apk --debug
    & $flutter build windows --debug

    $dll = Join-Path $repoRoot "build\windows\x64\runner\Debug\audioshare_core.dll"
    if (-not (Test-Path $dll)) {
        throw "Windows build completed but audioshare_core.dll was not copied to $dll"
    }

    Write-Host "Automated Android audio routing validation passed."
    Write-Host "Hardware validation still requires docs/android-audio-routing-validation-checklist.md."
} finally {
    Pop-Location
}
