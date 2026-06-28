param(
    [string]$Version = "v2.0.0"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReleaseRoot = Join-Path $Root "release"
$PackageName = "OfficeAISwitch-$Version-win-x64"
$PackageDir = Join-Path $ReleaseRoot $PackageName
$ZipPath = Join-Path $ReleaseRoot "$PackageName.zip"
$Launcher = Join-Path $Root "scripts\office_ai_switch_launcher.py"

function Copy-ItemSafe([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing release source: $Source"
    }
    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
if (Test-Path -LiteralPath $PackageDir) { Remove-Item -LiteralPath $PackageDir -Recurse -Force }
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null

$python = "python"
$oldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$pyinstallerCheck = & $python -m PyInstaller --version 2>$null
$pyinstallerExitCode = $LASTEXITCODE
$ErrorActionPreference = $oldErrorActionPreference
if ($pyinstallerExitCode -ne 0) {
    Write-Host "PyInstaller not found. Installing into current Python environment..."
    & $python -m pip install pyinstaller
    if ($LASTEXITCODE -ne 0) { throw "Failed to install PyInstaller." }
}

& $python -m PyInstaller `
    --noconfirm `
    --clean `
    --onefile `
    --windowed `
    --name OfficeAISwitch `
    --distpath $PackageDir `
    --workpath (Join-Path $Root "build\pyinstaller") `
    --specpath (Join-Path $Root "build") `
    $Launcher
if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed." }

Copy-ItemSafe (Join-Path $Root "word-switch-v2.py") (Join-Path $PackageDir "word-switch-v2.py")
Copy-ItemSafe (Join-Path $Root "word-switch-v2-gui.ps1") (Join-Path $PackageDir "word-switch-v2-gui.ps1")
Copy-ItemSafe (Join-Path $Root "word-deepseek-manifest.example.xml") (Join-Path $PackageDir "word-deepseek-manifest.example.xml")
Copy-ItemSafe (Join-Path $Root "start.example.ps1") (Join-Path $PackageDir "start.example.ps1")
Copy-ItemSafe (Join-Path $Root "WORD_AI_SWITCH_V2_README.md") (Join-Path $PackageDir "README.md")
Copy-ItemSafe (Join-Path $Root "LICENSE") (Join-Path $PackageDir "LICENSE")

New-Item -ItemType Directory -Path (Join-Path $PackageDir "docs") -Force | Out-Null
Copy-ItemSafe (Join-Path $Root "docs\GATEWAY_SETUP.md") (Join-Path $PackageDir "docs\GATEWAY_SETUP.md")
Copy-ItemSafe (Join-Path $Root "docs\RELEASE_NOTES_v2.0.0.md") (Join-Path $PackageDir "docs\RELEASE_NOTES_v2.0.0.md")

New-Item -ItemType Directory -Path (Join-Path $PackageDir "gateway_unified") -Force | Out-Null
Copy-ItemSafe (Join-Path $Root "gateway_unified\pyproject.toml") (Join-Path $PackageDir "gateway_unified\pyproject.toml")
Copy-ItemSafe (Join-Path $Root "gateway_unified\requirements.txt") (Join-Path $PackageDir "gateway_unified\requirements.txt")
Copy-ItemSafe (Join-Path $Root "gateway_unified\.env.example") (Join-Path $PackageDir "gateway_unified\.env.example")
Copy-ItemSafe (Join-Path $Root "gateway_unified\run-gateway.ps1") (Join-Path $PackageDir "gateway_unified\run-gateway.ps1")
Copy-Item -LiteralPath (Join-Path $Root "gateway_unified\src") -Destination (Join-Path $PackageDir "gateway_unified\src") -Recurse -Force
Get-ChildItem -LiteralPath (Join-Path $PackageDir "gateway_unified\src") -Directory -Recurse -Force |
    Where-Object { $_.Name -eq "__pycache__" -or $_.Name -like "*.egg-info" } |
    Remove-Item -Recurse -Force

@"
# Office AI Switch $Version

1. Install Python 3.11+ if it is not installed.
2. Open this folder and double-click `OfficeAISwitch.exe`.
3. On first run, the launcher creates `gateway_unified\.venv` and installs gateway dependencies automatically.
4. In the GUI, create or select a profile, save the API key, test it, then apply it to the gateway.
5. Configure your Office manifest from `word-deepseek-manifest.example.xml`.

For detailed setup, see `docs/GATEWAY_SETUP.md`.

Do not put real API keys or gateway tokens into files that you upload publicly.
"@ | Set-Content -LiteralPath (Join-Path $PackageDir "QUICK_START.md") -Encoding UTF8

Compress-Archive -Path (Join-Path $PackageDir "*") -DestinationPath $ZipPath -Force
if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "Zip package was not created: $ZipPath"
}

Write-Host "Release package created:"
Write-Host $PackageDir
Write-Host $ZipPath
