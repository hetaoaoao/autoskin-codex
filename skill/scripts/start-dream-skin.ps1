[CmdletBinding()]
param(
  [int]$Port = 0,
  [switch]$RestartExisting,
  [string]$ProfilePath,
  [switch]$ForegroundInjector
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')
$operation = Enter-AutoSkinLock
try {
  $StateRoot = $script:AutoSkinStateRoot
  $StatePath = Join-Path $StateRoot 'state.json'
  $PausePath = Join-Path $StateRoot 'paused'
  $Injector = Join-Path $PSScriptRoot 'injector.mjs'
  if (-not (Test-Path -LiteralPath $Injector -PathType Leaf)) { throw "Injector not found: $Injector" }
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

  $previous = Read-AutoSkinJson $StatePath
  if ($Port -eq 0 -and $previous -and $previous.port) {
    $candidate = [int]$previous.port
    if (Test-AutoSkinCdp $candidate) { $Port = $candidate }
  }
  $Port = Resolve-AutoSkinPort $Port
  $node = Get-AutoSkinNode
  $codex = Get-AutoSkinCodex
  $running = @(Get-AutoSkinCodexProcesses $codex)
  $debugReady = Test-AutoSkinCdp $Port
  if (-not $debugReady -and $running.Count -gt 0) {
    if (-not $RestartExisting) {
      throw 'Codex is already running without the requested AutoSkin debug session. Close it or rerun with -RestartExisting.'
    }
    Stop-AutoSkinCodex $codex
  }

  if (-not $debugReady) {
    $arguments = @("--remote-debugging-port=$Port", '--remote-debugging-address=127.0.0.1')
    if ($ProfilePath) {
      $resolvedProfile = [System.IO.Path]::GetFullPath($ProfilePath)
      New-Item -ItemType Directory -Force -Path $resolvedProfile | Out-Null
      $arguments += "--user-data-dir=$resolvedProfile"
    }
    [void](Start-AutoSkinCodex -Codex $codex -Arguments $arguments)
    if (-not (Wait-AutoSkinCdp -Port $Port -Seconds 35)) {
      throw "Codex did not expose its loopback debugging endpoint on port $Port within 35 seconds."
    }
  }

  if ($previous -and $previous.injectorPid) {
    $old = Get-Process -Id ([int]$previous.injectorPid) -ErrorAction SilentlyContinue
    if ($old -and $old.ProcessName -eq 'node') { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
  }
  Remove-Item -LiteralPath $PausePath -Force -ErrorAction SilentlyContinue

  if ($ForegroundInjector) {
    & $node.Path $Injector --watch --port $Port
    exit $LASTEXITCODE
  }

  $stdout = Join-Path $StateRoot 'injector.log'
  $stderr = Join-Path $StateRoot 'injector-error.log'
  $argumentLine = @((ConvertTo-AutoSkinArgument $Injector), '--watch', '--port', "$Port") -join ' '
  $daemon = Start-Process -FilePath $node.Path -ArgumentList $argumentLine -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $state = [ordered]@{
    schemaVersion = 1; port = $Port; injectorPid = $daemon.Id
    nodePath = $node.Path; nodeVersion = $node.Version
    codexExe = $codex.Executable; codexPackageRoot = $codex.PackageRoot
    codexPackageFullName = $codex.PackageFullName; codexPackageFamilyName = $codex.PackageFamilyName
    codexVersion = $codex.Version; startedAt = (Get-Date).ToString('o')
    runtimeRoot = (Split-Path -Parent $PSScriptRoot); profilePath = $ProfilePath
  }
  Write-AutoSkinJson -Path $StatePath -Value $state

  $verified = $false
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 500
    & $node.Path $Injector --verify --port $Port *> $null
    if ($LASTEXITCODE -eq 0) { $verified = $true; break }
    if ($daemon.HasExited) { break }
  }
  if (-not $verified) {
    Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
    throw "AutoSkin launched but verification failed. Inspect $stderr"
  }
  Write-Host "AutoSkin is active on loopback port $Port."
} finally {
  Exit-AutoSkinLock $operation
}
