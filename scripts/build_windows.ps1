# Builds the Windows desktop app and, if Inno Setup is installed, compiles the
# single-file installer.
#
# Cloud sync: if secrets\dart_defines.json exists (same file the mobile
# run/build script uses), its Supabase URL / anon key / tenant id are baked in
# and the desktop app syncs in real time with every phone. If the file is
# absent the app builds local-only, exactly as before.
#
# Usage (from repo root):
#   powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
#
# Output:
#   build\windows\x64\runner\Release\      <- portable app folder
#   installer\output\BismillahConstructionsSetup.exe  <- installer (if ISCC found)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Write-Host '==> flutter pub get' -ForegroundColor Cyan
flutter pub get

$defines = Join-Path $repoRoot 'secrets\dart_defines.json'
$buildArgs = @('build', 'windows', '--release', '--target', 'lib/main_desktop.dart')
if (Test-Path $defines) {
  Write-Host "==> Cloud sync ON (using $defines)" -ForegroundColor Cyan
  $buildArgs += "--dart-define-from-file=secrets/dart_defines.json"
} else {
  Write-Warning 'secrets\dart_defines.json not found — building LOCAL-ONLY (no cloud sync).'
}

Write-Host '==> Building Windows release (desktop entrypoint)' -ForegroundColor Cyan
flutter @buildArgs
if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }

$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path $releaseDir)) { throw "Release folder not found: $releaseDir" }
Write-Host "App built at: $releaseDir" -ForegroundColor Green

# --- Locate Inno Setup's ISCC.exe ---
$iscc = $null
$candidates = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $iscc = $c; break } }
if (-not $iscc) {
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { $iscc = $cmd.Source }
}

if (-not $iscc) {
  Write-Warning 'Inno Setup (ISCC.exe) not found. The portable app folder is ready.'
  Write-Host 'Install Inno Setup 6 from https://jrsoftware.org/isinfo.php then re-run,' -ForegroundColor Yellow
  Write-Host 'or run: iscc installer\bismillah.iss' -ForegroundColor Yellow
  exit 0
}

Write-Host "==> Compiling installer with $iscc" -ForegroundColor Cyan
& $iscc (Join-Path $repoRoot 'installer\bismillah.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }

$out = Join-Path $repoRoot 'installer\output\BismillahConstructionsSetup.exe'
if (Test-Path $out) {
  Write-Host "Installer created: $out" -ForegroundColor Green
} else {
  Write-Warning 'ISCC reported success but installer not found at expected path.'
}
