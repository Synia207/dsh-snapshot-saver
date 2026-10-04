[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SnapshotName
)

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

function Resolve-Snapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotRoot,
        [string]$RequestedName
    )

    $snapshots = @(Get-ChildItem -LiteralPath $SnapshotRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($snapshots.Count -eq 0) {
        throw "No snapshots found under $SnapshotRoot"
    }

    if (![string]::IsNullOrWhiteSpace($RequestedName)) {
        if ($RequestedName -notmatch '^[0-9]{8}-[0-9]{6}(?:-[0-9]+)?$') {
            throw 'SnapshotName must be a timestamp directory name.'
        }
        $selected = $snapshots | Where-Object Name -eq $RequestedName | Select-Object -First 1
        if ($null -eq $selected) {
            throw "Snapshot not found: $RequestedName"
        }
        return $selected
    }

    for ($index = 0; $index -lt $snapshots.Count; $index++) {
        $metadataPath = Join-Path $snapshots[$index].FullName 'installed_plugins.json'
        $pluginCount = '?'
        if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
            try { $pluginCount = @((Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).plugins).Count } catch { }
        }
        Write-Host ("[{0}] {1} (plugins: {2})" -f ($index + 1), $snapshots[$index].Name, $pluginCount)
    }
    $answer = Read-Host 'Select snapshot number'
    $selectedIndex = 0
    if (![int]::TryParse($answer, [ref]$selectedIndex) -or $selectedIndex -lt 1 -or $selectedIndex -gt $snapshots.Count) {
        throw 'Invalid snapshot selection.'
    }
    return $snapshots[$selectedIndex - 1]
}

function Assert-Snapshot {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Snapshot)

    $metadataPath = Join-Path $Snapshot.FullName 'installed_plugins.json'
    if (!(Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Snapshot metadata is missing: $metadataPath"
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    foreach ($name in @('package.json', 'pnpm-lock.yaml', 'cordis.patch.yml')) {
        $path = Join-Path $Snapshot.FullName $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Snapshot file is missing: $path"
        }
        $entry = @($metadata.files | Where-Object name -eq $name | Select-Object -First 1)
        if ($entry.Count -eq 1 -and (Get-Sha256 -Path $path) -ne $entry[0].sha256) {
            throw "Snapshot hash mismatch: $name"
        }
    }
    return $metadata
}

$dshHome = Get-DshHome
Stop-DshProcesses -DshHome $dshHome
$snapshotRoot = Join-Path $dshHome 'dsh-snapshots'
if (!(Test-Path -LiteralPath $snapshotRoot -PathType Container)) {
    throw "Snapshot directory is missing: $snapshotRoot"
}
$snapshot = Resolve-Snapshot -SnapshotRoot $snapshotRoot -RequestedName $SnapshotName
$metadata = Assert-Snapshot -Snapshot $snapshot
$profile = Join-Path $dshHome 'profiles\desktop'

foreach ($name in @('package.json', 'pnpm-lock.yaml', 'cordis.patch.yml')) {
    Copy-Item -LiteralPath (Join-Path $snapshot.FullName $name) -Destination (Join-Path $profile $name) -Force
}

$nodeModules = Join-Path $profile 'node_modules'
if (Test-Path -LiteralPath $nodeModules) {
    Remove-Item -LiteralPath $nodeModules -Recurse -Force -ErrorAction Stop
}

$pnpm = Get-Command pnpm -ErrorAction Stop
Push-Location $profile
try {
    & $pnpm.Source install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) {
        throw "pnpm install --frozen-lockfile failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

foreach ($name in @('package.json', 'pnpm-lock.yaml', 'cordis.patch.yml')) {
    $snapshotHash = Get-Sha256 -Path (Join-Path $snapshot.FullName $name)
    $restoredHash = Get-Sha256 -Path (Join-Path $profile $name)
    if ($snapshotHash -ne $restoredHash) {
        throw "Restored file changed unexpectedly after pnpm install: $name"
    }
}
Write-Output "Snapshot restored: $($snapshot.Name)"
Write-Output 'Restart DSH.'
