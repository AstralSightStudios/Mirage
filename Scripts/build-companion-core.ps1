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
    $out = Join-Path $bridge 'target\release'
    # -AsHashtable: the metadata has keys that differ only in case (USB / usb)
    $metadata = cargo metadata --format-version 1 | ConvertFrom-Json -AsHashtable
    $copied = 0
    foreach ($pkg in $metadata.packages | Where-Object { $_.name -eq 'windows_x86_64_msvc' }) {
        $libDir = Join-Path (Split-Path $pkg.manifest_path) 'lib'
        foreach ($lib in Get-ChildItem $libDir -Filter '*.lib' -ErrorAction SilentlyContinue) {
            Copy-Item $lib.FullName $out -Force
            $copied++
        }
    }
    Write-Host "companion core: $(Join-Path $out 'mirage_astrobox.lib') (+$copied import libraries)"
} finally {
    Pop-Location
}
