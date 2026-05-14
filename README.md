# SafeMove

**SafeMove** is a safety‑first PowerShell script for **high‑risk file migrations** where the destination **must not be modified, overwritten, or corrupted**. It recursively moves files from a source directory to a destination directory while enforcing strict, auditable safeguards.

This tool was built for situations where **"just use robocopy" is not acceptable**.

> **Current version: 1.0.2** — see [CHANGELOG.md](CHANGELOG.md) for what changed.

---

## Why SafeMove Exists

Most file‑move tools are optimised for speed, not safety. They assume the destination can be overwritten or "fixed later".

SafeMove makes the opposite assumption:

> **The destination is sacred.**

SafeMove is designed for:
- Legacy file server migrations
- Partial data off‑loading
- Disk cleanup with strict size limits
- Auditable or pre‑approved change operations
- Situations where you must prove *what would have happened* before it happens

---

## Core Guarantees

SafeMove enforces the following guarantees by design:

- ✅ **Destination data is never overwritten**
- ✅ **Existing destination files are never modified**
- ✅ **Files are auto‑renamed on name collision**
- ✅ **Large files are skipped cleanly**
- ✅ **Dry‑runs behave like real runs**
- ✅ **All actions are logged, always**
- ✅ **A single failure never aborts the run** *(1.0.2+)*
- ✅ **The CSV log is always recoverable, even on crash** *(1.0.2+)*

If SafeMove cannot move a file safely, it leaves it alone and logs why.

---

## Features

- Recursive directory traversal
- Size‑based file filtering using **GB** (decimal values supported)
- Collision‑safe renaming
  `file.txt` → `file (1).txt` → `file (2).txt`
- Native PowerShell `-WhatIf` support
- CSV audit logging with **sub‑second (millisecond) timestamps**
- **Real‑time CSV flushing** — every row hits disk immediately, so the log survives Ctrl‑C, reboots, and OS kills
- **Per‑file exception handling** — a locked or unreadable file is logged and skipped, never fatal
- **Structured error columns** — `Status`, `ErrorType`, and `ErrorMessage` make failures easy to triage in Excel
- Logs written beside the script (no temp usage)
- Compatible with **Windows PowerShell 5.1**

No modules. No dependencies. No telemetry.

---

## Requirements

- Windows PowerShell **5.1** or newer
- NTFS file system recommended
- Read access to the source path
- Write access to the destination path

---

## Usage

### Dry run (strongly recommended first)

`-WhatIf` writes a full plan to the CSV without moving anything. Use it to verify the destination layout before you commit.

```powershell
.\SafeMove.ps1 `
  -Source C:\Data `
  -Destination D:\Archive `
  -MaxSizeGB 10 `
  -WhatIf
```

### Real run

Drop `-WhatIf` to perform the moves:

```powershell
.\SafeMove.ps1 `
  -Source C:\Data `
  -Destination D:\Archive `
  -MaxSizeGB 10
```

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Source` | `string` | yes | — | Source directory. Walked recursively. |
| `-Destination` | `string` | yes | — | Destination directory. Created if missing. |
| `-MaxSizeGB` | `double` | no | `1.0` | Files larger than this are skipped and logged. Decimals OK (e.g. `0.5`, `2.5`). |
| `-WhatIf` | switch | no | off | Plan‑only mode. No files move, but the full plan is logged. |

---

## CSV Audit Log

Every run writes a CSV log next to the script, named `SafeMove_YYYYMMDD_HHmmss.csv`.

### Column schema

The original 7 columns keep their **exact** positions so existing parsers don't break. Three columns were added at the end in 1.0.2.

| # | Column | Description |
|---|--------|-------------|
| 1 | `Timestamp` | ISO 8601 with milliseconds, e.g. `2026-05-14T14:32:18.473` |
| 2 | `DryRun` | `True` if the whole run was invoked with `-WhatIf`, else `False` |
| 3 | `Action` | `StartRun`, `CreateFolder`, `Move`, `EnumerateDirectories`, `EnumerateFiles`, `EndRun`, `FatalError` |
| 4 | `Source` | Full path of the source file or directory (blank for destination‑only actions) |
| 5 | `Destination` | Full path of the destination file or directory |
| 6 | `SizeGB` | File size in gigabytes, rounded to 6 decimals (0 for non‑file rows) |
| 7 | `Note` | Human‑readable context (e.g. `Renamed to avoid overwrite`, `Exceeds MaxSizeGB (10)`) |
| 8 | `Status` | One of `OK`, `DryRun`, `Skipped`, `FileLocked`, `Failed` *(1.0.2+)* |
| 9 | `ErrorType` | .NET exception class (e.g. `System.IO.IOException`) — blank on success *(1.0.2+)* |
| 10 | `ErrorMessage` | Exception message text — blank on success *(1.0.2+)* |

### Status values

| Status | Meaning | When to act |
|--------|---------|-------------|
| `OK` | Move (or folder create) completed successfully. | No action. |
| `DryRun` | `-WhatIf` was set; the operation was logged but not performed. | Use the row to verify the plan, then re‑run without `-WhatIf`. |
| `Skipped` | File deliberately skipped (oversize or Google Drive `.gdoc`/`.gsheet`/etc. placeholder). | Decide whether to raise `-MaxSizeGB`, move large files manually, or sync cloud stubs first. |
| `FileLocked` | The source or destination was held open by another process (`ERROR_SHARING_VIOLATION` / `HRESULT 0x80070020`). | Close the holding app (Word, Excel, Drive, AV scan, backup agent) and re‑run SafeMove on the remaining files. |
| `Failed` | Any other exception. See `ErrorType` and `ErrorMessage`. | Triage by `ErrorType`. Common culprits: `UnauthorizedAccessException` (ACLs), `PathTooLongException` (>260 chars), `IOException` (cross‑volume issues). |

### Reading the log

Open the CSV in Excel, then filter the `Status` column:

- **Filter to `Failed` and `FileLocked`** to see what didn't move.
- **Sort by `ErrorType`** to triage in batches — one fix often unsticks many files.
- **`StartRun` and `EndRun` rows** bookend each run. If `EndRun` is missing, the script was interrupted; everything before the missing row is still on disk because logging is real‑time.
- **`FatalError`** rows are the top‑level safety net — they should almost never appear, because every block in the script has its own `try/catch`. If you see one, file an issue with the row attached.

### Recovering from a locked file

The most common scenario:

1. Run SafeMove. Some rows come back with `Status = FileLocked`.
2. Filter the CSV to `Status = FileLocked` to get the list.
3. Close whatever has them open. Cloud sync clients (OneDrive, Google Drive, Dropbox), Office apps, and AV real‑time scanners are the usual suspects. Reboot if you're not sure.
4. Re‑run SafeMove with the **same arguments**. The collision‑safe renaming guarantee means the previously moved files don't get touched again, and the locked files (now free) get picked up on this pass.

---

## Behavioral details

- **Google Drive placeholder files** (`.gdoc`, `.gsheet`, `.gslides`, `.gdraw`, `.gtable`) are detected and skipped with `Status = Skipped`. Moving them produces zero‑byte garbage on the destination because they're stubs, not real files.
- **Directory structure** is recreated under `-Destination` *before* any files are moved, so partial runs leave a valid (if incomplete) directory tree behind.
- **Renaming on collision** suffixes `(1)`, `(2)`, … to the base name — `file.txt` → `file (1).txt` — searching upward until a free name is found. The destination filename actually used is recorded in the `Destination` column.
- **The CSV writer is real‑time.** Under the hood it's a `[System.IO.StreamWriter]` with `AutoFlush = $true`. Every `Write‑Log` call flushes immediately. If SafeMove is killed (Ctrl‑C, OOM, host reboot, power loss) the log on disk is current up to the last completed action.

---

## Versioning

SafeMove follows [Semantic Versioning](https://semver.org/). The CSV column order is part of the public API — additions go on the right, existing columns never move.

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

> **Note on v1.0.1**: the v1.0.1 git tag exists but contains the same code as v1.0.0 — it was an empty placeholder release. All of the post‑1.0.0 fixes (file‑in‑use handling, real‑time logging, structured error columns) ship for the first time in **1.0.2**.

---

## License

[Apache License 2.0](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
For security issues, see [SECURITY.md](SECURITY.md).
