# SafeMove

**SafeMove** is a safety‑first PowerShell script for **high‑risk file migrations** where the destination **must not be modified, overwritten, or corrupted**. It recursively moves files from a source directory to a destination directory while enforcing strict, auditable safeguards.

This tool was built for situations where **“just use robocopy” is not acceptable**.

---

## Why SafeMove Exists

Most file‑move tools are optimised for speed, not safety. They assume the destination can be overwritten or “fixed later”.

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

If SafeMove cannot move a file safely, it leaves it alone and logs why.

---

## Features

- Recursive directory traversal
- Size‑based file filtering using **GB** (decimal values supported)
- Collision‑safe renaming  
  `file.txt` → `file (1).txt` → `file (2).txt`
- Native PowerShell `-WhatIf` support
- CSV audit logging with **sub‑second (millisecond) timestamps**
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

### Dry run (strongly recommended)

```powershell
.\SafeMove.ps1 `
  -Source C:\Data `
  -Destination D:\Archive `
  -MaxSizeGB 10 `
  -WhatIf
