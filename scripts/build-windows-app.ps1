[CmdletBinding()]
param(
  [ValidateSet('win-x64', 'win-arm64')]
  [string]$Runtime = 'win-x64',
  [switch]$FrameworkDependent
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $RepositoryRoot 'app\windows\AutoSkin.Windows.csproj'
$Output = Join-Path $RepositoryRoot "dist\AutoSkin-$Runtime"
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Output | Out-Null

$arguments = @('publish', $Project, '-c', 'Release', '-r', $Runtime, '-o', $Output,
  '-p:PublishSingleFile=true', '-p:DebugType=None', '-p:DebugSymbols=false')
if ($FrameworkDependent) {
  $arguments += '--no-self-contained'
} else {
  $arguments += '--self-contained'
}
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw 'Windows AutoSkin publish failed.' }

$readme = @"
AutoSkin Codex for Windows

1. Install the Microsoft Store Codex app, Node.js 22+, and Python 3.9+.
2. Extract this entire folder; do not move AutoSkin.exe away from AutoSkinRuntime.
3. Double-click AutoSkin.exe. Its tray icon installs/updates and applies the skin automatically.
4. Use Themes > Original Codex Skin to pause, or choose a theme to apply it again.

AutoSkin never modifies WindowsApps or app.asar. User themes remain under:
%LOCALAPPDATA%\CodexAutoSkin\themes-private
"@
[System.IO.File]::WriteAllText((Join-Path $Output 'README-Windows.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Windows app published to $Output"
