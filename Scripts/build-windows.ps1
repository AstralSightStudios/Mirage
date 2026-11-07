# Resolve and patch the pinned WinUI dependencies before building Mirage.
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$BuildArguments)
$ErrorActionPreference = 'Stop'
$mirageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Regenerate the Win32 icon resource when it is missing or older than its sources.
$iconDirectory = Join-Path $mirageRoot 'CrossApp/Windows'
$iconSource = Join-Path $iconDirectory 'Mirage.ico'
$iconScript = Join-Path $iconDirectory 'Mirage.rc'
$iconResource = Join-Path $iconDirectory 'Mirage.res'
$iconIsStale = (
    -not (Test-Path -LiteralPath $iconResource) -or
    (Get-Item -LiteralPath $iconSource).LastWriteTimeUtc -gt (Get-Item -LiteralPath $iconResource).LastWriteTimeUtc -or
    (Get-Item -LiteralPath $iconScript).LastWriteTimeUtc -gt (Get-Item -LiteralPath $iconResource).LastWriteTimeUtc
)
if ($iconIsStale) {
    $resourceCompiler = Get-Command rc.exe -ErrorAction SilentlyContinue
    if (-not $resourceCompiler) {
        throw 'rc.exe was not found. Run this script from a VS Developer PowerShell.'
    }
    Push-Location -LiteralPath $iconDirectory
    try {
        & $resourceCompiler.Source /nologo /fo $iconResource 'Mirage.rc'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot compile the Windows app icon resource' }
    } finally {
        Pop-Location
    }
}

& swift package --package-path $mirageRoot resolve
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Mirage dependencies' }

foreach ($dependency in @('swift-winui', 'swift-cross-ui')) {
    $checkout = Join-Path $mirageRoot ".build\checkouts\$dependency"
    $patchName = if ($dependency -eq 'swift-winui') { 'swift-winui-runtime.patch' } else { 'swift-cross-ui-windows.patch' }
    $patch = Join-Path $PSScriptRoot "Patches\$patchName"
    $autocrlf = if ($dependency -eq 'swift-winui') { 'false' } else { 'true' }
    & git -c "core.autocrlf=$autocrlf" -C $checkout apply --reverse --check $patch 2>$null
    if ($LASTEXITCODE -eq 0) { continue }
    & git -c "core.autocrlf=$autocrlf" -C $checkout apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw "$dependency does not match the pinned compatibility patch" }

    # SwiftPM checks out dependencies read-only.
    $paths = & git -C $checkout apply --numstat $patch
    foreach ($line in $paths) {
        $path = ($line -split "`t", 3)[2]
        (Get-Item -LiteralPath (Join-Path $checkout $path)).IsReadOnly = $false
    }
    & git -c "core.autocrlf=$autocrlf" -C $checkout apply $patch
    if ($LASTEXITCODE -ne 0) { throw "Cannot apply $dependency compatibility patch" }
}

& swift build --package-path $mirageRoot --product Mirage @BuildArguments
exit $LASTEXITCODE
