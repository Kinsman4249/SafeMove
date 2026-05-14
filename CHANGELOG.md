# Changelog

All notable changes to **SafeMove** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-05-14

> The v1.0.1 tag exists in the repository but contains the same code as v1.0.0
> (it was an empty placeholder release). All of the fixes and additions below
> ship for the first time in **1.0.2** — skip 1.0.1.

### Added
- **Real-time CSV logging.** Every row is flushed to disk the instant it is
  written, via a `[System.IO.StreamWriter]` with `AutoFlush = $true`. If the
  script is interrupted (Ctrl-C, host reboot, OS kill, power loss), the CSV
  already contains every action completed up to that point. No more end-of-run
  data dumps that disappear if the run dies.
- **New `Status` column** on every CSV row, with one of:
  `OK`, `DryRun`, `Skipped`, `FileLocked`, `Failed`.
- **New `ErrorType` and `ErrorMessage` columns** capturing the .NET exception
  class and message for any non-success row, so a CSV reader can triage
  failures without re-running the script.
- **Lifecycle rows.** `StartRun` is written at startup with the SafeMove
  version and parameters; `EndRun` is written on a clean finish; `FatalError`
  is written if (despite everything below) the top-level safety net fires.

### Fixed
- **"The process cannot access the file because it is being used by another
  process"** no longer aborts the run. The file is logged with
  `Status = FileLocked` (matched on `HRESULT 0x80070020 / 0x80070021` and a
  message-text fallback for older PowerShell hosts) and SafeMove continues
  with the next file.
- **Unhandled per-file exceptions** (NTFS ACLs, long paths, anti-virus locks,
  cloud-sync stubs, invalid characters, etc.) are now caught at the iteration
  level. The offending file is logged with `Status = Failed`, `ErrorType`,
  and `ErrorMessage`; the rest of the run continues normally.
- **Directory enumeration failures.** If a source subdirectory is unreadable
  (permissions, broken reparse point), the error is captured via
  `-ErrorVariable` and logged as `EnumerateDirectories` / `EnumerateFiles`
  rows instead of halting the entire enumeration.

### Changed
- **CSV column order is backwards-compatible.** The original seven columns
  (`Timestamp, DryRun, Action, Source, Destination, SizeGB, Note`) keep their
  exact positions. The three new columns (`Status, ErrorType, ErrorMessage`)
  are appended at the end so existing parsers that index by column position
  do not break.

## [1.0.0] - 2026-05-08

### Added
- Initial release.
- Recursive directory traversal with collision-safe renaming
  (`file.txt` &rarr; `file (1).txt` &rarr; `file (2).txt`).
- Size-based filtering via `-MaxSizeGB` (decimal values supported).
- Skips Google Drive placeholder files (`.gdoc`, `.gsheet`, `.gslides`,
  `.gdraw`, `.gtable`).
- Native PowerShell `-WhatIf` support.
- CSV audit logging with millisecond timestamps, written beside the script.
- Windows PowerShell 5.1 compatibility. No modules, dependencies, or telemetry.
