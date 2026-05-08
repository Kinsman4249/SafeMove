<#
.SYNOPSIS
SafeMove – safety-first recursive file move script.

.DESCRIPTION
- Moves files recursively from Source to Destination
- NEVER overwrites destination files
- Renames files on collision (file (1), file (2), etc.)
- Skips files larger than MaxSizeGB
- Skips Google Drive placeholder files (.gdoc, .gsheet, etc.)
- Supports native -WhatIf
- Always logs actions to CSV (including -WhatIf)
- Windows PowerShell 5.1 compatible
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [double]$MaxSizeGB = 1.0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- Initial setup
$MaxSizeBytes = $MaxSizeGB * 1GB
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$CsvLogPath  = Join-Path $ScriptDir ("SafeMove_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$LogBuffer = New-Object System.Collections.Generic.List[object]

# --- Logging helper
function Write-Log {
    param (
        [string]$Action,
        [string]$SourcePath,
        [string]$DestinationPath,
        [double]$SizeGB,
        [string]$Note
    )

    $LogBuffer.Add([pscustomobject]@{
        Timestamp   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')
        DryRun      = $WhatIfPreference
        Action      = $Action
        Source      = $SourcePath
        Destination = $DestinationPath
        SizeGB      = $SizeGB
        Note        = $Note
    })
}

# --- Generate a non-colliding destination path
function Get-UniquePath {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $Dir  = Split-Path $Path -Parent
    $Name = Split-Path $Path -Leaf
    $Base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $Ext  = [IO.Path]::GetExtension($Name)

    $i = 1
    do {
        $Candidate = Join-Path $Dir ("{0} ({1}){2}" -f $Base, $i, $Ext)
        $i++
    } while (Test-Path -LiteralPath $Candidate)

    return $Candidate
}

# --- Ensure destination root exists
if (-not (Test-Path -LiteralPath $Destination)) {
    Write-Log 'CreateFolder' $null $Destination 0 'Create destination root'

    if ($PSCmdlet.ShouldProcess($Destination, 'Create destination root')) {
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }
}

# --- Create directory structure safely
Get-ChildItem -LiteralPath $Source -Directory -Recurse | ForEach-Object {
    $Relative = $_.FullName.Substring($Source.Length).TrimStart('\')
    $DestDir  = Join-Path $Destination $Relative

    if (-not (Test-Path -LiteralPath $DestDir)) {
        Write-Log 'CreateFolder' $_.FullName $DestDir 0 'Create directory'

        if ($PSCmdlet.ShouldProcess($DestDir, 'Create directory')) {
            New-Item -ItemType Directory -Path $DestDir | Out-Null
        }
    }
}

# --- Process files
Get-ChildItem -LiteralPath $Source -File -Recurse | ForEach-Object {

    $SizeGB = [math]::Round($_.Length / 1GB, 6)

    # Skip oversized files
    if ($_.Length -gt $MaxSizeBytes) {
        Write-Log 'SkippedSize' $_.FullName '' $SizeGB "Exceeds MaxSizeGB ($MaxSizeGB)"
        return
    }

    # Skip Google Drive placeholder files (cause Move-Item IO errors)
    if ($_.Extension -in '.gdoc', '.gsheet', '.gslides', '.gdraw', '.gtable') {
        Write-Log 'SkippedCloudStub' $_.FullName '' $SizeGB 'Google Drive placeholder file'
        return
    }

    $Relative = $_.FullName.Substring($Source.Length).TrimStart('\')
    $Target   = Join-Path $Destination $Relative
    $Final    = Get-UniquePath $Target

    $Note = if ($Final -ne $Target) {
        'Renamed to avoid overwrite'
    } else {
        'No collision'
    }

    Write-Log 'MovePlanned' $_.FullName $Final $SizeGB $Note

    if ($PSCmdlet.ShouldProcess($_.FullName, "Move to $Final")) {
        Move-Item -LiteralPath $_.FullName -Destination $Final
    }
}

# --- Write CSV log
$LogBuffer | Export-Csv -Path $CsvLogPath -NoTypeInformation -Encoding UTF8

Write-Host "Completed. CSV log written to:" -ForegroundColor Green
Write-Host $CsvLogPath
