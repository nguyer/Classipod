param(
    [string]$FlutterExecutable = 'flutter',
    [string]$BuildName = '2.1.0-dev-test',
    [int]$BuildNumber = 28
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$featureNames = @('FLUTTER_WINDOWS', 'FLUTTER_LINUX', 'FLUTTER_MACOS')
$previousFeatures = @{}
foreach ($featureName in $featureNames) {
    $previousFeatures[$featureName] = [Environment]::GetEnvironmentVariable($featureName, 'Process')
}

Push-Location $projectRoot
try {
    # Android needs no desktop plugin symlinks or Windows Developer Mode.
    # Keep these overrides local to this build, rather than changing Flutter's
    # global desktop settings on the developer's computer.
    foreach ($featureName in $featureNames) {
        [Environment]::SetEnvironmentVariable($featureName, 'false', 'Process')
    }
    & $FlutterExecutable pub get --suppress-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency setup failed.' }

    $registrant = Join-Path $projectRoot 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
    if (-not (Test-Path -LiteralPath $registrant)) {
        throw 'Android plugin registration was not generated. APK build stopped.'
    }

    & $FlutterExecutable build apk --debug --flavor dev --target lib/main.dart `
        --target-platform android-arm,android-arm64 --no-pub `
        --build-name $BuildName --build-number $BuildNumber
    if ($LASTEXITCODE -ne 0) { throw 'Android APK build failed.' }
}
finally {
    foreach ($featureName in $featureNames) {
        [Environment]::SetEnvironmentVariable($featureName, $previousFeatures[$featureName], 'Process')
    }
    Pop-Location
}
