[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-DshHome {
    $configured = [Environment]::GetEnvironmentVariable('DSH_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = Split-Path -Parent $PSScriptRoot
    }
    $resolved = [IO.Path]::GetFullPath($configured)
    if (!(Test-Path -LiteralPath (Join-Path $resolved 'profiles\desktop') -PathType Container)) {
        throw "DSH_HOME does not contain profiles\desktop: $resolved"
    }
    return $resolved
}

function Stop-DshProcesses {
    param([Parameter(Mandatory = $true)][string]$DshHome)

    $homePattern = [regex]::Escape($DshHome.TrimEnd('\'))
    $currentPid = $PID
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $currentPid -and (
            $_.Name -match '(?i)^(dsh|deepseek-harness)(\.exe)?$' -or
            (($_.Name -match '(?i)^dsh-.*-helper(\.exe)?$') -and ($_.CommandLine -match "(?i)$homePattern.*profiles\\desktop")) -or
            (($_.Name -match '(?i)^(node|electron)(\.exe)?$') -and ($_.CommandLine -match "(?i)$homePattern.*(?:profiles\\desktop|--profile\s+desktop)"))
        )
    })

    foreach ($process in $processes) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    Write-Output ("Stopped DSH processes: " + $processes.Count)
}

function Get-RequiredFiles {
    param([Parameter(Mandatory = $true)][string]$DshHome)

    $profile = Join-Path $DshHome 'profiles\desktop'
    $files = [ordered]@{
        'package.json' = Join-Path $profile 'package.json'
        'pnpm-lock.yaml' = Join-Path $profile 'pnpm-lock.yaml'
        'cordis.patch.yml' = Join-Path $profile 'cordis.patch.yml'
    }
    foreach ($name in $files.Keys) {
        if (!(Test-Path -LiteralPath $files[$name] -PathType Leaf)) {
            throw "Required file is missing: $($files[$name])"
        }
    }
    return $files
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $getFileHash = Get-Command Get-FileHash -ErrorAction SilentlyContinue
    if ($null -ne $getFileHash) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace '-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $encoding = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), $encoding)
}

function Get-ThirdPartyPlugins {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    $package = Get-Content -LiteralPath $PackagePath -Raw | ConvertFrom-Json
    $plugins = @()
    foreach ($sectionName in @('dependencies', 'devDependencies', 'optionalDependencies')) {
        $section = $package.PSObject.Properties[$sectionName]
        if ($null -eq $section -or $null -eq $section.Value) {
            continue
        }
        foreach ($property in $section.Value.PSObject.Properties) {
            if ($property.Name -notmatch '^(?i:@deepseek-ai/)') {
                $plugins += [pscustomobject]@{
                    name = $property.Name
                    specifier = [string]$property.Value
                    section = $sectionName
                }
            }
        }
    }
    return @($plugins | Sort-Object name, section)
}

function Remove-OldSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotRoot,
        [int]$Keep = 5
    )

    $snapshots = @(Get-ChildItem -LiteralPath $SnapshotRoot -Directory | Sort-Object Name -Descending)
    if ($snapshots.Count -le $Keep) {
        return
    }

    foreach ($oldSnapshot in @($snapshots | Select-Object -Skip $Keep)) {
        [IO.Directory]::Delete($oldSnapshot.FullName, $true)
        Write-Output "Removed old snapshot: $($oldSnapshot.FullName)"
    }
}

$dshHome = Get-DshHome
Stop-DshProcesses -DshHome $dshHome
$files = Get-RequiredFiles -DshHome $dshHome
$snapshotRoot = Join-Path $dshHome 'dsh-snapshots'
New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$snapshotPath = Join-Path $snapshotRoot $timestamp
$suffix = 1
while (Test-Path -LiteralPath $snapshotPath) {
    $snapshotPath = Join-Path $snapshotRoot ($timestamp + '-' + $suffix)
    $suffix++
}
New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null

$fileEntries = @()
foreach ($name in $files.Keys) {
    $destination = Join-Path $snapshotPath $name
    Copy-Item -LiteralPath $files[$name] -Destination $destination
    $fileEntries += [pscustomobject]@{
        name = $name
        sha256 = Get-Sha256 -Path $destination
        bytes = (Get-Item -LiteralPath $destination).Length
    }
}

$metadata = [pscustomobject]@{
    schemaVersion = 1
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    profile = 'desktop'
    files = $fileEntries
    plugins = @(Get-ThirdPartyPlugins -PackagePath $files['package.json'])
}
Write-Utf8Json -Path (Join-Path $snapshotPath 'installed_plugins.json') -Value $metadata
Remove-OldSnapshots -SnapshotRoot $snapshotRoot -Keep 5
Write-Output "Snapshot created: $snapshotPath"
Write-Output ("Third-party plugin entries: " + @($metadata.plugins).Count)
