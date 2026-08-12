$ErrorActionPreference = "Stop"

$flutter = "E:\Programs\flutter\bin\flutter.bat"
if (-not (Test-Path $flutter)) {
    $flutter = "flutter"
}

@(
    (Join-Path $PSScriptRoot "..\build\windows"),
    (Join-Path $PSScriptRoot "..\build\flutter_assets")
) | Where-Object { Test-Path $_ } | ForEach-Object {
    Remove-Item -LiteralPath $_ -Recurse -Force
}

& $flutter pub get
& $flutter build windows --release

$source = Join-Path $PSScriptRoot "..\build\windows\x64\runner\Release"
$dist = Join-Path $PSScriptRoot "..\dist"
$zip = Join-Path $dist "AudioShare-Windows-portable.zip"

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -Path (Join-Path $source "*") -DestinationPath $zip
Write-Output "Created $zip"
