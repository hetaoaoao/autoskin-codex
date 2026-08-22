[CmdletBinding()]
param(
  [int]$Port = 0,
  [switch]$NoShortcuts,
  [switch]$NoAutoRecover,
  [switch]$NoExample
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common-windows.ps1')
$operation = Enter-AutoSkinLock
try {
  $node = Get-AutoSkinNode
  $codex = Get-AutoSkinCodex
  $Port = Resolve-AutoSkinPort $Port
  New-Item -ItemType Directory -Force -Path $script:AutoSkinStateRoot | Out-Null
  $config = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\config.toml'
  $backup = Join-Path $script:AutoSkinStateRoot 'config.before-autoskin.toml'
  if ((Test-Path -LiteralPath $config -PathType Leaf) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $config -Destination $backup
  }

  Install-AutoSkinRuntime -SkillRoot $SkillRoot
  $runtimeScripts = Join-Path $script:AutoSkinRuntimeRoot 'scripts'
  Get-ChildItem -LiteralPath $runtimeScripts -Filter '*.ps1' -File | ForEach-Object {
    Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
  }
  $privateThemes = Join-Path $script:AutoSkinStateRoot 'themes-private'
  New-Item -ItemType Directory -Force -Path $privateThemes | Out-Null
  if (-not $NoExample) {
    $example = Join-Path $SkillRoot 'examples\chiikawa-summer'
    $python = Get-AutoSkinPython
    & $python (Join-Path $SkillRoot 'scripts\theme_tool.py') build $example *> $null
    if ($LASTEXITCODE -ne 0) { throw 'The bundled example theme failed to build.' }
    $built = Join-Path $example '.build\chiikawa-summer'
    $destination = Join-Path $privateThemes 'chiikawa-summer'
    if (-not (Test-Path -LiteralPath $destination)) {
      Copy-Item -LiteralPath $built -Destination $destination -Recurse
    }
  }

  Write-AutoSkinJson -Path (Join-Path $script:AutoSkinStateRoot 'install-state.json') -Value ([ordered]@{
    schemaVersion = 1; installedAt = (Get-Date).ToString('o')
    runtimeRoot = $script:AutoSkinRuntimeRoot; nodePath = $node.Path; nodeVersion = $node.Version
    codexVersion = $codex.Version; codexPackageFullName = $codex.PackageFullName; defaultPort = $Port
  })

  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $startScript = Join-Path $runtimeScripts 'start-dream-skin.ps1'
  $restoreScript = Join-Path $runtimeScripts 'restore-dream-skin.ps1'
  $watchScript = Join-Path $runtimeScripts 'watch-dream-skin.ps1'
  if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
      $shortcut = $shell.CreateShortcut((Join-Path $folder 'AutoSkin Codex.lnk'))
      $shortcut.TargetPath = $powershell
      $shortcut.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$startScript`" -Port $Port -RestartExisting"
      $shortcut.WorkingDirectory = $script:AutoSkinRuntimeRoot
      $shortcut.Description = 'Launch the official Codex app with AutoSkin'
      $shortcut.Save()
    }
    $restore = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'AutoSkin Codex - Restore.lnk'))
    $restore.TargetPath = $powershell
    $restore.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$restoreScript`" -Port $Port"
    $restore.WorkingDirectory = $script:AutoSkinRuntimeRoot
    $restore.Description = 'Restore the official Codex interface'
    $restore.Save()
  }

  if (-not $NoAutoRecover) {
    $shell = New-Object -ComObject WScript.Shell
    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoSkin Codex Watcher.lnk'
    $shortcut = $shell.CreateShortcut($startupLink)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$watchScript`" -Port $Port"
    $shortcut.WorkingDirectory = $script:AutoSkinRuntimeRoot
    $shortcut.Description = 'Recover AutoSkin after Codex restarts'
    $shortcut.Save()
    $watcherState = Read-AutoSkinJson (Join-Path $script:AutoSkinStateRoot 'watcher-state.json')
    if ($watcherState -and $watcherState.watcherPid) {
      Stop-Process -Id ([int]$watcherState.watcherPid) -Force -ErrorAction SilentlyContinue
    }
    $watchArguments = @(
      '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-File',
      (ConvertTo-AutoSkinArgument $watchScript), '-Port', "$Port"
    ) -join ' '
    Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList $watchArguments
  }
  Write-Host "AutoSkin Codex for Windows is installed at $($script:AutoSkinRuntimeRoot)."
  Write-Host 'Launch it from the AutoSkin Codex shortcut. The source checkout is no longer required.'
} finally {
  Exit-AutoSkinLock $operation
}
