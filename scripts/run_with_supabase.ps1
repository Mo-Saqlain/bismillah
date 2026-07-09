# Run or build Bismillah with cloud sync enabled.
# The Flutter app lives at the repository root (flattened from the old
# bismillah_constructions/ subfolder). Credentials live in
# secrets/dart_defines.json (gitignored).
param(
  [ValidateSet('run', 'build-apk')]
  [string]$Action = 'run',
  [string]$Device
)

$ErrorActionPreference = 'Stop'
# scripts/ sits at the repo root, so the app root is this script's parent dir.
$root = Split-Path $PSScriptRoot -Parent
$defines = Join-Path $root 'secrets\dart_defines.json'

if (-not (Test-Path $defines)) {
  Write-Error @"
Missing $defines
Copy secrets\dart_defines.example.json to secrets\dart_defines.json and fill in your Supabase URL + anon key.
"@
}

Set-Location $root

$common = @('--dart-define-from-file=secrets/dart_defines.json')

switch ($Action) {
  'run' {
    if ($Device) {
      flutter run @common -d $Device
    } else {
      flutter run @common
    }
  }
  'build-apk' {
    flutter build apk --release @common
  }
}
