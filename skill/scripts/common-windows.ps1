$script:AutoSkinStateRoot = Join-Path $env:LOCALAPPDATA 'CodexAutoSkin'
$script:AutoSkinRuntimeRoot = Join-Path $script:AutoSkinStateRoot 'runtime'
$script:AutoSkinUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Enter-AutoSkinLock {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = New-Object System.Threading.Mutex($false, "Local\CodexAutoSkin.$sid.Operation")
  try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) {
    $mutex.Dispose()
    throw 'Another AutoSkin install, start, verify, or restore operation is already running.'
  }
  return $mutex
}

function Exit-AutoSkinLock([System.Threading.Mutex]$Mutex) {
  if ($null -eq $Mutex) { return }
  try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Write-AutoSkinUtf8([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $temporary = "$Path.next-$PID-$([guid]::NewGuid().ToString('N'))"
  try {
    [System.IO.File]::WriteAllText($temporary, $Content, $script:AutoSkinUtf8NoBom)
    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temporary, $Path, $null, $true)
    } else {
      [System.IO.File]::Move($temporary, $Path)
    }
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

function Write-AutoSkinJson([string]$Path, [object]$Value) {
  Write-AutoSkinUtf8 -Path $Path -Content (($Value | ConvertTo-Json -Depth 8) + "`n")
}

function Read-AutoSkinJson([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Assert-AutoSkinPort([int]$Port) {
  if ($Port -lt 1024 -or $Port -gt 65535) { throw "Port must be between 1024 and 65535: $Port" }
}

function Get-AutoSkinNode {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $command) { throw 'Node.js 22 or newer is required and was not found in PATH.' }
  $version = (& $command.Source -p 'process.versions.node' 2>$null).Trim()
  $major = 0
  if (-not [int]::TryParse(($version -split '\.')[0], [ref]$major) -or $major -lt 22) {
    throw "Node.js 22 or newer is required; found $version."
  }
  $path = (& $command.Source -p 'process.execPath' 2>$null).Trim()
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Node.js executable could not be validated.' }
  return [pscustomobject]@{ Path = $path; Version = $version }
}

function Get-AutoSkinPython {
  foreach ($name in @('python.exe', 'python3.exe', 'python')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  throw 'Python 3.9 or newer is required for theme validation and building.'
}

function Get-AutoSkinCodex {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
    Where-Object { "$($_.SignatureKind)" -eq 'Store' -and -not $_.IsDevelopmentMode } |
    Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package) { throw 'The official OpenAI.Codex Microsoft Store package is not installed.' }
  $executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Codex executable not found: $executable" }
  $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
  $apps = @($manifest.Package.Applications.Application | Where-Object {
    "$($_.Executable)".Replace('/', '\') -ieq 'app\ChatGPT.exe'
  })
  if ($apps.Count -ne 1) { throw 'The registered Codex application identity is ambiguous.' }
  $appId = "$($apps[0].Id)"
  if ($appId -notmatch '^[A-Za-z0-9._-]+$') { throw 'The registered Codex application ID is invalid.' }
  return [pscustomobject]@{
    Executable = $executable
    PackageRoot = "$($package.InstallLocation)"
    PackageFullName = "$($package.PackageFullName)"
    PackageFamilyName = "$($package.PackageFamilyName)"
    AppUserModelId = "$($package.PackageFamilyName)!$appId"
    Version = "$($package.Version)"
  }
}

function Initialize-AutoSkinPackageLauncher {
  if ('CodexAutoSkin.PackageLauncher' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexAutoSkin {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
  }
  [ComImport, Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  class ApplicationActivationManager { }
  public static class PackageLauncher {
    public static uint Launch(string id, string arguments) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      try { uint pid; Marshal.ThrowExceptionForHR(manager.ActivateApplication(id, arguments ?? "", 0, out pid)); return pid; }
      finally { if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager); }
    }
  }
}
'@
}

function ConvertTo-AutoSkinArgument([string]$Value) {
  if ($Value.Contains('"')) { throw 'Arguments containing double quotes are not supported.' }
  if ($Value -notmatch '\s') { return $Value }
  return '"' + $Value.Replace('\', '\') + '"'
}

function Start-AutoSkinCodex([object]$Codex, [string[]]$Arguments) {
  Initialize-AutoSkinPackageLauncher
  $line = (($Arguments | ForEach-Object { ConvertTo-AutoSkinArgument $_ }) -join ' ')
  $pidValue = [CodexAutoSkin.PackageLauncher]::Launch($Codex.AppUserModelId, $line)
  if ($pidValue -le 0) { throw 'Windows did not return a Codex process ID.' }
  return $pidValue
}

function Get-AutoSkinCodexProcesses([object]$Codex) {
  $root = [System.IO.Path]::GetFullPath($Codex.PackageRoot).TrimEnd('\') + '\'
  return @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and ([System.IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase))
  })
}

function Stop-AutoSkinCodex([object]$Codex) {
  foreach ($process in @(Get-AutoSkinCodexProcesses $Codex)) {
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
  }
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline -and @(Get-AutoSkinCodexProcesses $Codex).Count -gt 0) {
    Start-Sleep -Milliseconds 250
  }
  if (@(Get-AutoSkinCodexProcesses $Codex).Count -gt 0) { throw 'Codex did not stop within 12 seconds.' }
}

function Get-AutoSkinTargets([int]$Port) {
  foreach ($hostName in @('127.0.0.1', '[::1]')) {
    try { return @(Invoke-RestMethod "http://${hostName}:$Port/json/list" -TimeoutSec 2) } catch {}
  }
  return @()
}

function Test-AutoSkinCdp([int]$Port) {
  return @(Get-AutoSkinTargets $Port | Where-Object {
    $_.type -eq 'page' -and $_.url -like 'app://-/index.html*' -and $_.webSocketDebuggerUrl
  }).Count -gt 0
}

function Test-AutoSkinTcpPort([int]$Port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    return $task.Wait(250) -and $client.Connected
  } catch { return $false } finally { $client.Dispose() }
}

function Resolve-AutoSkinPort([int]$RequestedPort = 0) {
  if ($RequestedPort) {
    Assert-AutoSkinPort $RequestedPort
    if ((Test-AutoSkinTcpPort $RequestedPort) -and -not (Test-AutoSkinCdp $RequestedPort)) {
      throw "Port $RequestedPort is occupied by another application."
    }
    return $RequestedPort
  }
  foreach ($candidate in 9335..9435) {
    if (-not (Test-AutoSkinTcpPort $candidate) -or (Test-AutoSkinCdp $candidate)) { return $candidate }
  }
  throw 'No free AutoSkin debugging port was found from 9335 through 9435.'
}

function Wait-AutoSkinCdp([int]$Port, [int]$Seconds = 35) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-AutoSkinCdp $Port) { return $true }
    Start-Sleep -Milliseconds 350
  }
  return $false
}

function Assert-AutoSkinSafeTree([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Directory not found: $Path" }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse-point directory: $Path" }
  foreach ($child in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
    if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Runtime contains a reparse point: $($child.FullName)" }
  }
}

function Install-AutoSkinRuntime([string]$SkillRoot) {
  $source = [System.IO.Path]::GetFullPath($SkillRoot)
  foreach ($relative in @('assets\renderer-inject.js', 'styles\dream\style.css', 'scripts\injector.mjs', 'scripts\start-dream-skin.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "Runtime source is incomplete: $relative" }
  }
  foreach ($name in @('assets', 'styles', 'themes', 'scripts')) { Assert-AutoSkinSafeTree (Join-Path $source $name) }
  New-Item -ItemType Directory -Force -Path $script:AutoSkinStateRoot | Out-Null
  $staging = Join-Path $script:AutoSkinStateRoot ".runtime-next-$PID"
  $backup = Join-Path $script:AutoSkinStateRoot ".runtime-backup-$PID"
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    foreach ($name in @('assets', 'styles', 'themes', 'scripts')) {
      Copy-Item -LiteralPath (Join-Path $source $name) -Destination $staging -Recurse -Force
    }
    Assert-AutoSkinSafeTree $staging
    if (Test-Path -LiteralPath $script:AutoSkinRuntimeRoot) {
      Move-Item -LiteralPath $script:AutoSkinRuntimeRoot -Destination $backup
    }
    try { Move-Item -LiteralPath $staging -Destination $script:AutoSkinRuntimeRoot } catch {
      if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $script:AutoSkinRuntimeRoot }
      throw
    }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  }
}
