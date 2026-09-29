# Media Ingest Tool

Ingests files from a source folder into a structured archive, validating
every filename against `medienstandard_v3-1_2026_regex.json`. Works on
Windows (PowerShell) and macOS/Linux (Python) — same behavior, same
settings format, either one.

## Files

| File | Purpose |
|---|---|
| `Run Ingest Tool.cmd` | Windows launcher — double-click this |
| `Media-Ingest-Tool-Mac.zip` | macOS package — unzip, then double-click the `.command` inside |
| `Ingest-MediaFiles.ps1` | The Windows tool (PowerShell) |
| `ingest_tool.py` | The macOS/Linux tool (Python 3) |
| `medienstandard_v3-1_2026_regex.json` | Bundled naming standard (lets the tool work offline) |
| `ingest-settings.txt` | Created automatically after your first run |

Keep them all in the same folder.

**macOS:** use `Media-Ingest-Tool-Mac.zip`, not the loose files — unzipping
it (double-click the zip) keeps the launcher correctly marked as
executable. If your Mac still warns it's from an unidentified developer,
right-click the `.command` file, choose **Open**, then confirm once.

## Using it

Double-click the launcher for your platform. First run, it asks three
questions:

1. **Where are your files coming from?**
2. **Where should they go?** (creates the folder if needed)
3. **Copy or move?** — copy keeps the originals; move deletes them from
   the source, but only *after* a verified copy, and cleans up any
   folders left empty behind it.

Your answers are saved to `ingest-settings.txt`. Every run after that just
asks "Use these settings?" — press Enter and you're straight into a
preview. Edit that file directly any time something changes.

It always shows a preview (nothing changed yet) before asking to confirm
the real run. Full detail for every file goes into `_logs/` regardless of
what's shown on screen.

## Command line

Power users can skip the wizard by passing flags — the same rule for
both: give it `--source`/`--dest` and it runs non-interactively; give it
nothing and you get the wizard.

```powershell
.\Ingest-MediaFiles.ps1 -Source "D:\" -Dest "E:\Archive" -DryRun
.\Ingest-MediaFiles.ps1 -Source "D:\" -Dest "E:\Archive"
```
```bash
python3 ingest_tool.py --source /Volumes/Source --dest /Volumes/Archive --dry-run
python3 ingest_tool.py --source /Volumes/Source --dest /Volumes/Archive
```

| Python | PowerShell | Meaning |
|---|---|---|
| `--source PATH` | `-Source PATH` | Source folder |
| `--dest PATH` | `-Dest PATH` | Destination archive root |
| `--verify` | `-Verify` | Read-only integrity check of `--dest` (no source needed) |
| `--quarantine PATH` | `-Quarantine PATH` | Default: `<dest>\_quarantine` |
| `--log-dir PATH` | `-LogDir PATH` | Default: `<dest>\_logs` |
| `--dry-run` | `-DryRun` | Preview only |
| `--delete-source` | `-DeleteSource` | Move instead of copy |
| `--delete-duplicates` | `-DeleteDuplicates` | With delete-source: also remove source duplicates |
| `--remove-empty-folders` | `-RemoveEmptyFolders` | With delete-source: clean up emptied folders |
| `--ignore PATTERNS` | `-IgnorePatterns` | Comma-separated glob patterns to skip |
| `--regex-url URL` | `-RegexUrl URL` | Override the naming standard's source |
| `--refresh-standard` | `-RefreshStandard` | Force re-download of the standard |

Execution-policy blocked on Windows ("is not digitally signed")? Use
`Run Ingest Tool.cmd`, which already works around it.

## What it does

- **Validates** every filename against the standard; valid files go to
  `<dest>\<areaCategory>\<filename>` (the prefix without its 1-character
  owner code — `r11`, `d11`, `w1a`, etc.); invalid ones go to quarantine
  with the specific reason.
- **Verifies** every copy by re-hashing it against the source before
  counting it as done. Never overwrites existing content — a name
  collision gets a safe `(1)`, `(2)`, ... suffix instead.
- **Deduplicates** by hash + filename together, so two different files
  that happen to share content aren't treated as the same thing.
- **Self-heals**: if interrupted mid-run, the next run recognizes
  already-correct files in place rather than re-copying or duplicating.
- **Works offline**, using the bundled standard if the live one is
  unreachable.
- **`-Verify`** re-checks a whole archive later: confirms tracked files
  are still intact, and flags anything present that the manifest doesn't
  know about (e.g. added manually).

## Multiple people, same archive

Safe for concurrent use, including from both platforms at once — this
was specifically stress-tested under real concurrent load, not just
assumed. The PowerShell and Python versions share one manifest file
(`_ingest_tool/manifest.csv`) for duplicate detection and `-Verify`;
Python also keeps its own SQLite index for faster lookups internally.

Worth knowing:
- A custom `Quarantine =` override is per-person, not shared — leave it
  blank unless you mean it.
- No indicator shows whether someone else is importing at the same
  time; check the CSV report or `-Verify` afterward if you want to know.
- `_ingest_tool/logs/` grows over time with no automatic cleanup.

## Scaling

Built for large archives. Both tools check duplicates against an index
rather than the archive's full history each run, so a normal import's
cost tracks how many files it's importing, not how big the archive has
grown to:
- Python queries its own SQLite index.
- PowerShell keeps a small on-disk index (`_ingest_tool/manifest_index/`,
  auto-managed, safe to delete) split by hash prefix, and only re-reads
  whatever's been added to the manifest since it last ran. The very
  first run against an existing large archive (or after that index
  folder is deleted) still does a one-time full build.

Scanning a very large source also takes real time before the progress
bar can show a percentage; a message prints so it's clear the tool is
working, not frozen. `-Verify`/`--verify` always scales with total data
size, since it deliberately re-reads every tracked file to catch
corruption.

## Output structure

```
<dest>/
  r11/  d11/  w1a/  ...       <- your actual archive, sorted by standard prefix
  _quarantine/                 <- invalid files, mirroring source structure -
                                   these need a human look, so they stay in plain sight
  _ingest_tool/                 <- everything the tool needs to track itself,
                                   in one place. Safe to leave alone; safe to
                                   delete if you ever need to (it just rebuilds
                                   on the next import). See its own README.txt.
    manifest.csv                <- shared manifest, both tools read/write this
    manifest_cache.sqlite       <- Python's internal index (disposable)
    manifest_index/             <- PowerShell's lookup index (disposable)
    logs/
      ingest_<timestamp>.log     <- full detail
      ingest_<timestamp>.csv     <- machine-readable report
```

Only three kinds of things ever sit at the top level of the archive: your
category folders, `_quarantine` (needs your attention), and `_ingest_tool`
(the tool's own bookkeeping — never your files). `_ingest_tool` is a normal,
visible folder on purpose, not a hidden dotfile, so ordinary copy/backup
tools don't silently skip it when you move the archive to new storage.

Archives built by an older version of this tool (with `.ingest_manifest.csv`,
`_logs`, etc. loose at the top level) are migrated into this layout
automatically the next time either tool runs against them — nothing to do
by hand, and nothing in your actual files is touched.

## Requirements

- **Windows:** PowerShell 5.1+ or 7+ (built in). No admin rights needed.
- **macOS/Linux:** Python 3.8+ (standard library only).
- Read access to the source, write access to the destination.
- Internet optional — see *works offline* above.
