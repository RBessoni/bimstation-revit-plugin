<#
.SYNOPSIS
  Builds the BIM Station for Revit installer end to end.

.DESCRIPTION
  Runs the whole pipeline in the order it has to happen:
    1. Generate the static panel UI from the sibling speckle-connectors-dui repo
    2. Build the Revit connectors in Release
    3. Compile the single-file installer with Inno Setup

  The UI must be generated first, because the installer embeds its output.

.PARAMETER Version
  Version stamped into the installer. Defaults to whatever BIMStationForRevit.iss declares.

.PARAMETER SkipUi
  Reuse the existing UI bundle instead of regenerating it. Much faster when only C# changed.

.EXAMPLE
  .\Build\build-installer.ps1
  .\Build\build-installer.ps1 -Version 1.1.0 -SkipUi
#>
[CmdletBinding()]
param(
  [string]$Version,
  [switch]$SkipUi
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiRepo = Join-Path (Split-Path -Parent $repoRoot) 'speckle-connectors-dui'
$issPath = Join-Path $PSScriptRoot 'installer\BIMStationForRevit.iss'

function Assert-Tool($name, $probe, $hint) {
  if (-not (& $probe)) { throw "$name not found. $hint" }
  Write-Host "  ok  $name" -ForegroundColor DarkGray
}

Write-Host "`n[1/4] Checking prerequisites" -ForegroundColor Cyan

Assert-Tool 'sibling speckle-connectors-dui repo' { Test-Path $uiRepo } `
  "Clone it next to this repo: git clone <your-fork> `"$uiRepo`""
Assert-Tool '.NET SDK' { [bool](Get-Command dotnet -ErrorAction SilentlyContinue) } `
  'Install with: winget install --id Microsoft.DotNet.SDK.10'
Assert-Tool 'Node.js' { [bool](Get-Command node -ErrorAction SilentlyContinue) } `
  'Install with: winget install --id OpenJS.NodeJS.LTS'

# winget installs Inno Setup per-user, so it is not on PATH and not under Program Files.
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
  throw 'ISCC.exe not found. Install with: winget install --id JRSoftware.InnoSetup'
}
Write-Host "  ok  Inno Setup ($iscc)" -ForegroundColor DarkGray

if ($Version) {
  $iss = Get-Content $issPath -Raw
  $iss = $iss -replace '(?m)^#define AppVersion ".*"$', "#define AppVersion `"$Version`""
  Set-Content $issPath $iss -NoNewline
  Write-Host "  version set to $Version" -ForegroundColor DarkGray
}

if ($SkipUi) {
  if (-not (Test-Path (Join-Path $uiRepo '.output\public\index.html'))) {
    throw 'No existing UI bundle to reuse. Run without -SkipUi first.'
  }
  Write-Host "`n[2/4] Skipping UI generation (-SkipUi)" -ForegroundColor Cyan
}
else {
  Write-Host "`n[2/4] Generating panel UI" -ForegroundColor Cyan
  Push-Location $uiRepo
  try {
    if (-not (Test-Path 'node_modules')) {
      Write-Host '  installing dependencies (first run, takes a few minutes)' -ForegroundColor DarkGray
      corepack yarn install
      if ($LASTEXITCODE -ne 0) { throw 'yarn install failed' }
    }
    corepack yarn generate
    if ($LASTEXITCODE -ne 0) { throw 'yarn generate failed' }
  }
  finally { Pop-Location }
}

Write-Host "`n[3/4] Building Revit connectors (Release)" -ForegroundColor Cyan
foreach ($v in @('2026', '2027')) {
  Write-Host "  Revit $v" -ForegroundColor DarkGray
  # ContinuousIntegrationBuild=true disables the target that copies the addin into the Revit
  # Addins folder, which would fail on locked DLLs if Revit happens to be open.
  dotnet build "$repoRoot\Connectors\Revit\Speckle.Connectors.Revit$v\Speckle.Connectors.Revit$v.csproj" `
    -c Release -p:ContinuousIntegrationBuild=true --nologo -v minimal
  if ($LASTEXITCODE -ne 0) { throw "Revit $v build failed" }
}

Write-Host "`n[4/4] Compiling installer" -ForegroundColor Cyan
& $iscc $issPath | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compile failed' }

$exe = Get-ChildItem "$repoRoot\output\*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host "`nDone: $($exe.FullName)" -ForegroundColor Green
Write-Host ("       {0} MB" -f [math]::Round($exe.Length / 1MB, 2)) -ForegroundColor Green
