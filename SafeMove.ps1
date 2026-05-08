<#
.SYNOPSIS
Safely moves files from Source to Destination recursively.
- Skips files larger than MaxSizeGB
- NEVER overwrites destination files
- Auto-renames on name collision
- Supports -WhatIf dry-run
- Logs all actions to CSV with sub-second timestamps
- Windows PowerShell 5.1 compatible
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$Source      = 'C:\Source',
    [string]$Destination = 'D:\Destination',
    [double]$MaxSizeGB   = 1.0,

    # CSV log saved next to the script
    [string]$CsvLogPath = $(Join-Path $PSScriptRoot "SafeMove_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv")
)


Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$MaxSizeBytes = $MaxSizeGB * 1GB
$logBuffer = New-Object System.Collections.Generic.List[object]

function Get-TimeStamp {
    # ISO 8601 with milliseconds (sub-second precision)
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')
}

function Log-Action {
    param (
        [string]$Action,
        [string]$SourcePath,
        [string]$DestinationPath,
        [Nullable[Double]]$SizeGB,
        [string]$Note
    )

    $logBuffer.Add([pscustomobject]@{
        Timestamp      = Get-TimeStamp
        Action         = $Action
        Source         = $SourcePath
        Destination    = $DestinationPath
        SizeGB         = $SizeGB
        Note           = $Note
    })
}

function Get-RelativePath {
    param ($FullPath, $Root)
    $root = (Resolve-Path $Root).Path.TrimEnd('\')
    $full = (Resolve-Path $FullPath).Path
    $full.Substring($root.Length).TrimStart('\')
}

function Get-UniquePath {
    param ($Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $Path }

    $dir  = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [IO.Path]::GetExtension($name)

    $i = 1
    do {
        $candidate = Join-Path $dir "$base ($i)$ext"
        $i++
    } while (Test-Path -LiteralPath $candidate)

    return $candidate
}

# --- Ensure destination root exists (safe operation)
if (-not (Test-Path $Destination)) {
    if ($PSCmdlet.ShouldProcess($Destination, 'Create destination root folder')) {
        New-Item -Path $Destination -ItemType Directory | Out-Null
    }
    Log-Action 'CreateFolder' $null $Destination $null 'Destination root created'
}

# --- Create missing folder structure only
Get-ChildItem $Source -Directory -Recurse | ForEach-Object {
    $rel = Get-RelativePath $_.FullName $Source
    $targetDir = Join-Path $Destination $rel

    if (-not (Test-Path $targetDir)) {
        if ($PSCmdlet.ShouldProcess($targetDir, 'Create folder')) {
            New-Item -Path $targetDir -ItemType Directory | Out-Null
        }
        Log-Action 'CreateFolder' $_.FullName $targetDir $null 'Created missing directory'
    }
}

# --- Process files
Get-ChildItem $Source -File -Recurse | ForEach-Object {

    $sizeGB = [math]::Round($_.Length / 1GB, 6)


    if ($_.Length -gt $MaxSizeBytes) {
        Log-Action 'SkippedSize' $_.FullName $null $sizeGB "Exceeds MaxSizeGB ($MaxSizeGB)"
        return
    }

    $rel = Get-RelativePath $_.FullName $Source
    $desiredDest = Join-Path $Destination $rel
    $finalDest = Get-UniquePath $desiredDest
    $renamed = ($finalDest -ne $desiredDest)

    if ($PSCmdlet.ShouldProcess($_.FullName, "Move to $finalDest")) {
        Move-Item -LiteralPath $_.FullName -Destination $finalDest
    }

    Log-Action `
        -Action 'Moved' `
        -SourcePath $_.FullName `
        -DestinationPath $finalDest `
        -SizeGB $sizeGB `
        -Note ($(if ($renamed) { 'Renamed to avoid overwrite' } else { 'Moved as-is' }))
}

# --- Write CSV log
$logBuffer | Export-Csv -Path $CsvLogPath -NoTypeInformation -Append -Encoding UTF8

Write-Host "Completed. CSV log written to:" -ForegroundColor Green
Write-Host "  $CsvLogPath"
Write-Host "Use -WhatIf for dry runs."
