$ErrorActionPreference = "Stop"

$flutter = "E:\Programs\flutter\bin\flutter.bat"
if (-not (Test-Path $flutter)) {
    $flutter = "flutter"
}

$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"

& $flutter pub get
& $flutter build apk --release

$dist = Join-Path $PSScriptRoot "..\dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\build\app\outputs\flutter-apk\app-release.apk") `
    -Destination (Join-Path $dist "AudioShare-Android.apk") -Force
Write-Output "Created $(Join-Path $dist 'AudioShare-Android.apk')"
