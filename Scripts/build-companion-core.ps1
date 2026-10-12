# Windows counterpart of build-companion-core.sh: builds the companion core
# (AstroBoxBridge) as mirage_astrobox.lib for the SwiftCrossUI app.
$ErrorActionPreference = 'Stop'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $env:PATH = (Join-Path $cargoHome 'bin') + [IO.Path]::PathSeparator + $env:PATH
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'cargo not found; install Rust (https://rustup.rs) to build the companion core'
}

$bridge = Resolve-Path (Join-Path $PSScriptRoot '..\AstroBoxBridge')
Push-Location $bridge
try {
    Write-Host 'Building the companion core...'
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }

    # The static library imports Windows APIs through windows-targets' import
    # libraries (windows.0.48.5.lib, windows.0.52.0.lib, ...); put them next to
    # it so the Swift link (-L AstroBoxBridge\target\release) finds them.
    # Found by globbing the cargo registry instead of `cargo metadata`, whose
    # JSON needs ConvertFrom-Json -AsHashtable (PowerShell 6+ only) because it
    # has keys that differ only in case (USB / usb).
    $out = Join-Path $bridge 'target\release'
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $copied = 0
    foreach ($libDir in Get-ChildItem (Join-Path $cargoHome 'registry\src') -Directory |
        ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter 'windows_x86_64_msvc-*' } |
        ForEach-Object { Join-Path $_.FullName 'lib' }) {
        foreach ($lib in Get-ChildItem $libDir -Filter '*.lib' -ErrorAction SilentlyContinue) {
            Copy-Item $lib.FullName $out -Force
            $copied++
        }
    }
    Write-Host "companion core: $(Join-Path $out 'mirage_astrobox.lib') (+$copied import libraries)"
} finally {
    Pop-Location
}
