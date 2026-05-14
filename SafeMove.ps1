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
- Per-file exception handling: a single failure never aborts the run
- Real-time CSV logging: each row is flushed to disk immediately, so the
  log is fully recoverable if the script is interrupted, the host reboots,
  or PowerShell is killed mid-move
- Windows PowerShell 5.1 compatible

.NOTES
Version: 1.0.2
License: Apache-2.0

CSV columns (the three columns added in 1.0.2 are appended at the end so
existing parsers that rely on the original column positions do not break):

  Timestamp, DryRun, Action, Source, Destination, SizeGB, Note,
  Status, ErrorType, ErrorMessage

Status values:
  OK          - operation completed successfully
  DryRun      - logged but not performed (because of -WhatIf)
  Skipped     - file deliberately skipped (oversize, cloud stub)
  FileLocked  - source/destination was held by another process
                (ERROR_SHARING_VIOLATION, HRESULT 0x80070020)
  Failed      - any other exception (see ErrorType / ErrorMessage)
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [double]$MaxSizeGB = 1.0
)

$ScriptVersion = '1.0.2'

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- Initial setup
$MaxSizeBytes = $MaxSizeGB * 1GB
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$CsvLogPath   = Join-Path $ScriptDir ("SafeMove_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

# --- Real-time CSV writer
# AutoFlush = $true guarantees the log on disk is always current. If the
# script is interrupted (Ctrl-C, host reboot, OOM kill), every row that
# Write-Log has produced so far is already on disk.
$CsvHeader = 'Timestamp,DryRun,Action,Source,Destination,SizeGB,Note,Status,ErrorType,ErrorMessage'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$CsvWriter = New-Object System.IO.StreamWriter($CsvLogPath, $false, $Utf8NoBom)
$CsvWriter.AutoFlush = $true
$CsvWriter.WriteLine($CsvHeader)

# --- CSV field escaping (RFC 4180: quote-wrap, double any internal quotes)
function Format-CsvField {
    param ([object]$Value)
    if ($null -eq $Value) { return '""' }
    $s = [string]$Value
    return '"' + $s.Replace('"', '""') + '"'
}

# --- Logging helper (writes one row immediately and flushes)
function Write-Log {
    param (
        [string]$Action,
        [string]$SourcePath      = '',
        [string]$DestinationPath = '',
        [double]$SizeGB          = 0,
        [string]$Note            = '',
        [string]$Status          = '',
        [string]$ErrorType       = '',
        [string]$ErrorMessage    = ''
    )

    $fields = @(
        (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff'),
        [string]$WhatIfPreference,
        $Action,
        $SourcePath,
        $DestinationPath,
        $SizeGB,
        $Note,
        $Status,
        $ErrorType,
        $ErrorMessage
    ) | ForEach-Object { Format-CsvField $_ }

    $CsvWriter.WriteLine($fields -join ',')
}

# --- Detect "file in use" sharing-violation errors
# ERROR_SHARING_VIOLATION = 0x80070020 = -2147024864 (signed Int32)
# ERROR_LOCK_VIOLATION    = 0x80070021 = -2147024863 (signed Int32)
function Test-FileLocked {
    param ($Exception)
    if ($null -eq $Exception) { return $false }
    if ($Exception.PSObject.Properties['HResult']) {
        if ($Exception.HResult -eq -2147024864 -or $Exception.HResult -eq -2147024863) {
            return $true
        }
    }
    if ($Exception.Message -match 'being used by another process|sharing violation') {
        return $true
    }
    return $false
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

# ============================================================================
# Main pipeline — wrapped end-to-end so nothing escapes without being logged.
# Each block has its own try/catch; the outermost try/finally only exists to
# guarantee the CSV writer is flushed and disposed.
# ============================================================================
try {

    Write-Log -Action 'StartRun' -SourcePath $Source -DestinationPath $Destination `
              -Note "SafeMove v$ScriptVersion (MaxSizeGB=$MaxSizeGB)" -Status 'OK'

    # --- Ensure destination root exists
    try {
        if (-not (Test-Path -LiteralPath $Destination)) {
            if ($PSCmdlet.ShouldProcess($Destination, 'Create destination root')) {
                New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
                Write-Log -Action 'CreateFolder' -DestinationPath $Destination `
                          -Note 'Create destination root' -Status 'OK'
            } else {
                Write-Log -Action 'CreateFolder' -DestinationPath $Destination `
                          -Note 'Create destination root' -Status 'DryRun'
            }
        }
    }
    catch {
        $exc = $_.Exception
        Write-Log -Action 'CreateFolder' -DestinationPath $Destination `
                  -Note 'Create destination root' -Status 'Failed' `
                  -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message
    }

    # --- Enumerate source directories (per-item errors are captured, not fatal)
    $enumDirErrors = @()
    $SourceDirs = @(Get-ChildItem -LiteralPath $Source -Directory -Recurse `
                                  -ErrorAction SilentlyContinue `
                                  -ErrorVariable enumDirErrors)

    foreach ($err in $enumDirErrors) {
        $exc = $err.Exception
        $tgt = if ($err.TargetObject) { [string]$err.TargetObject } else { '' }
        Write-Log -Action 'EnumerateDirectories' -SourcePath $tgt -Status 'Failed' `
                  -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message
    }

    # --- Recreate directory structure safely
    foreach ($Dir in $SourceDirs) {
        $DestDir = $null
        try {
            $Relative = $Dir.FullName.Substring($Source.Length).TrimStart('\')
            $DestDir  = Join-Path $Destination $Relative

            if (-not (Test-Path -LiteralPath $DestDir)) {
                if ($PSCmdlet.ShouldProcess($DestDir, 'Create directory')) {
                    New-Item -ItemType Directory -Path $DestDir -ErrorAction Stop | Out-Null
                    Write-Log -Action 'CreateFolder' -SourcePath $Dir.FullName `
                              -DestinationPath $DestDir -Note 'Create directory' -Status 'OK'
                } else {
                    Write-Log -Action 'CreateFolder' -SourcePath $Dir.FullName `
                              -DestinationPath $DestDir -Note 'Create directory' -Status 'DryRun'
                }
            }
        }
        catch {
            $exc = $_.Exception
            Write-Log -Action 'CreateFolder' -SourcePath $Dir.FullName -DestinationPath $DestDir `
                      -Note 'Create directory' -Status 'Failed' `
                      -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message
        }
    }

    # --- Enumerate source files (per-item errors are captured, not fatal)
    $enumFileErrors = @()
    $SourceFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse `
                                   -ErrorAction SilentlyContinue `
                                   -ErrorVariable enumFileErrors)

    foreach ($err in $enumFileErrors) {
        $exc = $err.Exception
        $tgt = if ($err.TargetObject) { [string]$err.TargetObject } else { '' }
        Write-Log -Action 'EnumerateFiles' -SourcePath $tgt -Status 'Failed' `
                  -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message
    }

    # --- Process files
    foreach ($File in $SourceFiles) {
        $SourceFullName = ''
        $Final          = ''
        $SizeGB         = 0
        $Note           = ''

        try {
            $SourceFullName = $File.FullName
            $SizeGB         = [math]::Round($File.Length / 1GB, 6)

            # Skip oversized files
            if ($File.Length -gt $MaxSizeBytes) {
                Write-Log -Action 'Move' -SourcePath $SourceFullName -SizeGB $SizeGB `
                          -Note "Exceeds MaxSizeGB ($MaxSizeGB)" -Status 'Skipped'
                continue
            }

            # Skip Google Drive placeholder files (cause Move-Item IO errors)
            if ($File.Extension -in '.gdoc', '.gsheet', '.gslides', '.gdraw', '.gtable') {
                Write-Log -Action 'Move' -SourcePath $SourceFullName -SizeGB $SizeGB `
                          -Note 'Google Drive placeholder file' -Status 'Skipped'
                continue
            }

            $Relative = $SourceFullName.Substring($Source.Length).TrimStart('\')
            $Target   = Join-Path $Destination $Relative
            $Final    = Get-UniquePath $Target

            $Note = if ($Final -ne $Target) {
                'Renamed to avoid overwrite'
            } else {
                'No collision'
            }

            # --- The actual move, with explicit handling for sharing violations
            try {
                if ($PSCmdlet.ShouldProcess($SourceFullName, "Move to $Final")) {
                    Move-Item -LiteralPath $SourceFullName -Destination $Final -ErrorAction Stop
                    Write-Log -Action 'Move' -SourcePath $SourceFullName -DestinationPath $Final `
                              -SizeGB $SizeGB -Note $Note -Status 'OK'
                } else {
                    Write-Log -Action 'Move' -SourcePath $SourceFullName -DestinationPath $Final `
                              -SizeGB $SizeGB -Note $Note -Status 'DryRun'
                }
            }
            catch {
                $exc = $_.Exception
                $status = if (Test-FileLocked $exc) { 'FileLocked' } else { 'Failed' }
                Write-Log -Action 'Move' -SourcePath $SourceFullName -DestinationPath $Final `
                          -SizeGB $SizeGB -Note $Note -Status $status `
                          -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message
            }
        }
        catch {
            # Catch-all for anything in this iteration not already handled
            # (sizing, path math, collision lookup, ShouldProcess weirdness, etc.)
            $exc = $_.Exception
            Write-Log -Action 'Move' -SourcePath $SourceFullName -DestinationPath $Final `
                      -SizeGB $SizeGB -Note 'Unhandled iteration error' -Status 'Failed' `
                      -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message
        }
    }

    Write-Log -Action 'EndRun' -Status 'OK' -Note "SafeMove v$ScriptVersion completed"
}
catch {
    # Top-level safety net. Every block above already catches its own errors,
    # so this should almost never fire — but if it does, we still log it.
    $exc = $_.Exception
    Write-Log -Action 'FatalError' -Status 'Failed' `
              -ErrorType $exc.GetType().FullName -ErrorMessage $exc.Message `
              -Note 'Top-level catch fired'
}
finally {
    if ($CsvWriter) {
        try { $CsvWriter.Flush() }   catch { }
        try { $CsvWriter.Dispose() } catch { }
    }
}

Write-Host "Completed. CSV log written to:" -ForegroundColor Green
Write-Host $CsvLogPath
