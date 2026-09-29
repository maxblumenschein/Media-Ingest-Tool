#!/usr/bin/env python3
"""
Media Ingest Tool
=================
Safely, cleanly and reliably ingests files from a source folder into a
structured, validated archive at a destination you choose.

Filenames are validated against the "medienstandard" JSON definition:
  https://raw.githubusercontent.com/knisterstern1/medienstandard/refs/heads/main/medienstandard_v3-1_2026_regex.json

WORKFLOW (per file)
--------------------
  1. Compute a SHA-256 hash of the source file.
  2. Look the hash up in a persistent manifest database. If it has already
     been imported before (same content, any name/location) -> skip as a
     duplicate. This makes the tool safe to re-run, and safe to point at a
     second/overlapping source later.
  3. Validate the filename against the standard's master regex pattern.
       - VALID   -> destination: <dest>/<areaCategory>/<filename>
                    "areaCategory" is the filename's prefix *without* the
                    1-character owner code, e.g. "r11", "d11", "w1a"
                    (exactly the folder names the standard itself defines).
       - INVALID -> destination: <quarantine>/<relative-source-subpath>/<filename>
                    plus a precise, human-readable reason (evaluated rule by
                    rule against the standard's own error messages).
  4. Copy the file, then re-hash the COPY and compare it to the source hash.
     Only if this verification succeeds is the operation considered done.
  5. Only if verification succeeded, and --delete-source was given, the
     source file is removed. Otherwise the source is always left untouched.
  6. Record the import (hash, destination, timestamp) in the manifest.

BagIt-style folders (name matches the standard's "includeDirs" pattern,
e.g. "..._s-<part>-...-bag") are treated as ONE atomic unit: the folder
name itself is validated, and the whole folder is copied/verified/recorded
as a single object instead of being split file by file.

USAGE
-----
    python3 ingest_tool.py \
        --source /Volumes/Source \
        --dest /Volumes/Archive \
        [--quarantine /Volumes/Archive/_quarantine] \
        [--dry-run] [--delete-source]

Run `python3 ingest_tool.py --help` for all options.

Nothing is ever deleted from the source unless --delete-source is passed
AND the copy has been byte-verified. Default behaviour is copy-only.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import sys
import time
import uuid
from types import SimpleNamespace
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

STANDARD_URL_DEFAULT = (
    "https://raw.githubusercontent.com/knisterstern1/medienstandard/"
    "refs/heads/main/medienstandard_v3-1_2026_regex.json"
)

DEFAULT_IGNORE = [
    ".DS_Store", "Thumbs.db", "desktop.ini", "Desktop.ini",
    "._*", "*.tmp", "*.part", "~$*",
]


def bundled_standard_path() -> Path:
    """The standard also ships as a plain file right next to this script,
    so a machine that has never had (or will never have) internet access
    can still run the tool correctly from the very first run - not just
    after a successful download has been cached once."""
    return Path(__file__).resolve().parent / "medienstandard_v3-1_2026_regex.json"


# --------------------------------------------------------------------------
# The standard: fetch, cache, compile, validate
# --------------------------------------------------------------------------

class Standard:
    """Wraps the medienstandard JSON: compiled master pattern, compiled
    per-rule regexes (with their onError sub-patterns), and the BagIt
    directory-name pattern."""

    def __init__(self, data: dict):
        self.data = data
        self.version = data.get("info", {}).get("version", "?")
        self.year = data.get("info", {}).get("year", "?")

        self.pattern = re.compile(unquote(data["pattern"]))
        self.include_dirs = re.compile(unquote(data["includeDirs"]))

        self.rules = []
        for rule in data.get("rules", []):
            on_error = [
                {"regex": re.compile(unquote(sub["regex"])), "error": sub.get("error", "")}
                for sub in rule.get("onError", [])
            ]
            self.rules.append({
                "regex": re.compile(unquote(rule["regex"])),
                "error": rule.get("error", "Ungueltiger Dateiname."),
                "onError": on_error,
            })

    @classmethod
    def load(cls, url: str, cache_path: Path, force_refresh: bool = False, logger=None) -> "Standard":
        raw = None
        try:
            if force_refresh or not cache_path.exists():
                raw = cls._download(url)
            else:
                # Use cache, but still try a fresh download; fall back silently.
                try:
                    raw = cls._download(url)
                except Exception:
                    raw = cache_path.read_text(encoding="utf-8")
        except Exception as exc:
            if cache_path.exists():
                if logger:
                    logger.warning("Could not download standard (%s); using cached copy at %s", exc, cache_path)
                raw = cache_path.read_text(encoding="utf-8")
            else:
                bundled = bundled_standard_path()
                if url == STANDARD_URL_DEFAULT and bundled.exists():
                    if logger:
                        logger.warning("Could not download standard (%s); using the copy bundled "
                                        "with this tool at %s", exc, bundled)
                    raw = bundled.read_text(encoding="utf-8")
                else:
                    raise RuntimeError(
                        f"Could not download the medienstandard from {url}, no cached "
                        f"copy exists at {cache_path}, and no bundled copy was found at "
                        f"{bundled}. Cannot continue without a validation standard. "
                        f"Error: {exc}"
                    ) from exc

        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(raw, encoding="utf-8")
        data = json.loads(raw)
        std = cls(data)
        if logger:
            logger.info("Loaded medienstandard v%s (%s)", std.version, std.year)
        return std

    @staticmethod
    def _download(url: str) -> str:
        req = urllib.request.Request(url, headers={"User-Agent": "media-ingest-tool/1.0"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.read().decode("utf-8")

    def is_bag_dir(self, dirname: str) -> bool:
        return bool(self.include_dirs.match(dirname))

    def validate_name(self, name: str):
        """Return (is_valid, groups_dict, list_of_error_strings)."""
        m = self.pattern.match(name)
        if m:
            return True, m.groupdict(), []

        errors = []
        for rule in self.rules:
            if rule["regex"].search(name):
                continue  # this rule is satisfied
            detail = None
            for sub in rule["onError"]:
                if sub["regex"].search(name):
                    detail = sub["error"]
                    break
            msg = rule["error"] + (f" ({detail})" if detail else "")
            errors.append(msg)
        if not errors:
            errors.append("Dateiname entspricht nicht dem Medienstandard (unspezifischer Fehler).")
        return False, {}, errors


# --------------------------------------------------------------------------
# Hashing helpers
# --------------------------------------------------------------------------

def append_csv_row_with_retry(path: Path, row, max_attempts: int = 6, initial_delay: float = 0.1) -> None:
    """Appends one row to a CSV file, retrying briefly on OSError before
    giving up. Network shares (NAS/SMB in particular) sometimes report a
    file as transiently locked - antivirus scanning it right after a
    write, an SMB oplock break, momentary contention from another user's
    session on the same archive - even though nothing is actually wrong.
    This matters most for the shared manifest CSV, which is reopened on
    every single import (the PowerShell version had the exact same
    exposure via Add-Content, seen directly on a real NAS); retrying
    rides out the hiccup instead of the previous behavior of silently
    dropping the row."""
    attempt = 0
    while True:
        try:
            with open(path, "a", newline="", encoding="utf-8") as f:
                writer = csv.writer(f, quoting=csv.QUOTE_ALL)
                writer.writerow(row)
            return
        except OSError:
            attempt += 1
            if attempt >= max_attempts:
                raise
            time.sleep(initial_delay * attempt)


def sha256_file(path, chunk_size: int = 4 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path: Path) -> str:
    """Deterministic combined hash over every file's relative path + content
    hash inside a directory tree. Used for BagIt-style bag folders."""
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = Path(root) / name
            rel = full.relative_to(path).as_posix()
            h.update(rel.encode("utf-8"))
            h.update(sha256_file(full).encode("utf-8"))
    return h.hexdigest()


def dir_size(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                pass
    return total


# --------------------------------------------------------------------------
# Manifest (dedupe database)
# --------------------------------------------------------------------------

CSV_MANIFEST_HEADER = ["hash", "original_name", "source_path", "dest_path", "size", "imported_at"]


class Manifest:
    """Persistent SQLite database of everything successfully imported so far,
    keyed by content hash TOGETHER WITH filename. Lives inside the
    destination archive.

    In addition to its own SQLite index (kept purely as a fast internal
    lookup cache), every import is ALSO written to the same plain-CSV
    manifest format the PowerShell version already reads and writes
    (manifest.csv, alongside this file, inside the archive's _ingest_tool
    folder). That shared CSV is what
    lets the two tools' duplicate detection and -Verify/--verify checks
    see each other's work, without requiring PowerShell to gain any
    SQLite-reading capability it doesn't have built in (and without this
    version losing the fast, indexed lookups that make it scale well).
    The SQLite database itself stays Python-only; the CSV is the shared,
    canonical record both tools rely on.

    Known limitation: if this archive already had history from before
    this cross-tool sharing existed AND the shared CSV was already
    created separately (e.g. the PowerShell version was also already used
    on the same destination), the one-time backfill below won't have run
    for it - only a brand new shared CSV gets backfilled with this tool's
    prior history. From that point on, everything new is fully shared
    either way.

    Two different, distinctly-named files that happen to contain identical
    bytes (e.g. two blank/placeholder files, or the same image reused
    under a different, meaningful standard filename) are NOT the same
    archive entry and should both be kept. An exact repeat of the same
    name AND the same content - a re-copy of a file already in the
    archive, or the same source processed twice - is still caught.
    """

    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(db_path))
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS imports (
                hash TEXT NOT NULL,
                original_name TEXT NOT NULL,
                source_path TEXT,
                dest_path TEXT,
                size INTEGER,
                imported_at TEXT,
                PRIMARY KEY (hash, original_name)
            )
        """)
        self.conn.commit()

        self.csv_path = db_path.parent / "manifest.csv"
        self._csv_cache = None  # lazily loaded {(hash, name): dest_path}, built from the shared CSV
        self._ensure_csv_and_backfill()

    def _ensure_csv_and_backfill(self):
        if self.csv_path.exists():
            return
        # First time the shared CSV has existed for this archive: create
        # it atomically (O_EXCL under the hood) so a concurrent
        # PowerShell run creating it at the same instant can't produce a
        # duplicate header - the loser here just proceeds normally below,
        # reading whatever the winner wrote. If this Python manifest
        # already has history of its own from before cross-tool sharing
        # existed, back all of it up into the CSV once, so it becomes
        # visible to the PowerShell version too from now on.
        try:
            with open(self.csv_path, "x", newline="", encoding="utf-8") as f:
                writer = csv.writer(f, quoting=csv.QUOTE_ALL)
                writer.writerow(CSV_MANIFEST_HEADER)
        except FileExistsError:
            return  # someone else just created it - nothing to backfill from here

        existing = self.conn.execute(
            "SELECT hash, original_name, source_path, dest_path, size, imported_at FROM imports"
        ).fetchall()
        if existing:
            with open(self.csv_path, "a", newline="", encoding="utf-8") as f:
                writer = csv.writer(f, quoting=csv.QUOTE_ALL)
                for row in existing:
                    writer.writerow(row)

    def _load_csv_cache(self):
        if self._csv_cache is not None:
            return self._csv_cache
        cache = {}
        if self.csv_path.exists():
            try:
                # utf-8-sig transparently strips a leading byte-order-mark
                # if present, and is a harmless no-op if not - needed
                # because the PowerShell version's default UTF8 writer
                # includes a BOM, which plain "utf-8" would otherwise
                # leave stuck to the first column name ("hash" becomes
                # "\ufeffhash"), silently breaking every lookup against
                # that column. Verified directly: this exact corruption
                # was reproduced and is what this line prevents.
                with open(self.csv_path, newline="", encoding="utf-8-sig") as f:
                    for row in csv.DictReader(f):
                        cache[(row.get("hash", ""), row.get("original_name", ""))] = row.get("dest_path", "")
            except OSError:
                pass
        self._csv_cache = cache
        return cache

    def lookup(self, file_hash: str, original_name: str):
        cur = self.conn.execute(
            "SELECT dest_path FROM imports WHERE hash = ? AND original_name = ?",
            (file_hash, original_name),
        )
        row = cur.fetchone()
        if row:
            return row[0]
        # Not in this tool's own fast index - check the shared CSV too,
        # in case the PowerShell version already handled this exact file.
        # Loaded once per run (not once per file) to keep this cheap.
        return self._load_csv_cache().get((file_hash, original_name))

    def record(self, file_hash: str, original_name: str, source_path: str, dest_path: str, size: int):
        imported_at = datetime.now(timezone.utc).isoformat()
        self.conn.execute(
            "INSERT OR REPLACE INTO imports "
            "(hash, original_name, source_path, dest_path, size, imported_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (file_hash, original_name, source_path, dest_path, size, imported_at),
        )
        self.conn.commit()
        try:
            append_csv_row_with_retry(
                self.csv_path,
                [file_hash, original_name, source_path, dest_path, size, imported_at],
            )
        except OSError as exc:
            # The shared CSV is what lets the other tool see this import -
            # worth knowing about if it's persistently failing, but still
            # never worth blocking or failing a real, already-verified
            # import over. This tool's own SQLite record above already
            # succeeded regardless.
            if not getattr(Manifest, "_csv_write_warned", False):
                print(f"  (Note: couldn't write to the shared manifest CSV just now - continuing anyway. {exc})")
                Manifest._csv_write_warned = True
        if self._csv_cache is not None:
            self._csv_cache[(file_hash, original_name)] = dest_path

    def all_entries(self):
        """Every (hash, original_name, dest_path) row currently recorded,
        merging this tool's own SQLite index with the shared CSV so
        -Verify/--verify sees everything either tool has imported."""
        merged = {}
        for h, n, d in self.conn.execute("SELECT hash, original_name, dest_path FROM imports"):
            merged[(h, n)] = d
        for (h, n), d in self._load_csv_cache().items():
            merged.setdefault((h, n), d)
        return [(h, n, d) for (h, n), d in merged.items()]

    def close(self):
        self.conn.close()


INGEST_TOOL_DIR_NAME = "_ingest_tool"


def migrate_legacy_layout(dest_root: Path, logger=None) -> None:
    """One-time, best-effort tidy-up for archives built by an older
    version of either tool, back when the manifest/index/logs lived loose
    at the destination root (.ingest_manifest.csv, .ingest_manifest.sqlite,
    _logs) instead of tucked inside one clearly-named _ingest_tool folder.

    Never touches actual archive content (category folders) or
    quarantine - only this tool's own bookkeeping - and never deletes
    anything it hasn't successfully relocated first: a partial or failed
    migration just leaves some old files in their old place (harmless
    clutter), never data loss. Safe to call on every run; once migrated,
    there is nothing left to do and it is a fast no-op.
    """
    new_tool_dir = dest_root / INGEST_TOOL_DIR_NAME
    old_manifest = dest_root / ".ingest_manifest.csv"
    new_manifest = new_tool_dir / "manifest.csv"
    old_index = dest_root / ".ingest_manifest_index"
    new_index = new_tool_dir / "manifest_index"
    old_sqlite = dest_root / ".ingest_manifest.sqlite"
    new_sqlite = new_tool_dir / "manifest_cache.sqlite"
    old_logs = dest_root / "_logs"
    new_logs = new_tool_dir / "logs"

    has_old_manifest = old_manifest.exists()
    has_old_logs = old_logs.exists()
    if not has_old_manifest and not has_old_logs and not old_sqlite.exists():
        return  # nothing old to migrate

    try:
        new_tool_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        return  # can't create it - just proceed on the old layout for this run

    if has_old_manifest and not new_manifest.exists():
        try:
            print("Tidying up this archive's bookkeeping into one '_ingest_tool' folder "
                  "(one-time - your actual files aren't touched)...")
            shutil.move(str(old_manifest), str(new_manifest))
        except OSError as exc:
            print(f"  (Couldn't move the old manifest yet ({exc}) - still using it from its old location this run.)")

    # The lookup index and this tool's own SQLite cache are both
    # disposable - if either can't be moved right now, simplest to just
    # leave it behind; it costs nothing but a one-time rebuild later.
    if old_index.exists() and not new_index.exists():
        try:
            shutil.move(str(old_index), str(new_index))
        except OSError:
            pass
    if old_sqlite.exists() and not new_sqlite.exists():
        try:
            shutil.move(str(old_sqlite), str(new_sqlite))
        except OSError:
            pass

    if has_old_logs:
        # Move file-by-file (not the whole folder at once) so this still
        # works even if _ingest_tool/logs already exists from an earlier
        # partial migration or a run that already started this session.
        try:
            new_logs.mkdir(parents=True, exist_ok=True)
            for item in old_logs.iterdir():
                target = new_logs / item.name
                if not target.exists():
                    try:
                        shutil.move(str(item), str(target))
                    except OSError:
                        pass
            if not any(old_logs.iterdir()):
                old_logs.rmdir()
        except OSError:
            pass  # old logs are historical only; leaving some behind is harmless

    if logger is not None:
        logger.debug("Legacy archive layout check/migration complete for %s", dest_root)


def ingest_tool_readme_text() -> str:
    return (
        "This folder belongs to the Media Ingest Tool - not to the archive's\n"
        "actual content.\n\n"
        "It keeps track of what has already been imported (so re-running an\n"
        "import never duplicates anything) and holds run logs for reference.\n\n"
        "You don't need to open anything in here, and nothing in the rest of\n"
        "this archive depends on you understanding it. A few things worth\n"
        "knowing anyway:\n\n"
        "  - Safe to leave in place. When you copy, move, or back up this\n"
        "    whole archive folder, bring this folder along with it (it is a\n"
        "    normal, visible folder - not hidden - specifically so ordinary\n"
        "    copy tools don't skip it by accident).\n"
        "  - Safe to delete, if you really need to. The tool will simply\n"
        "    rebuild it from scratch the next time you import - it just means\n"
        "    files already in the archive might briefly look \"new\" again to\n"
        "    the tool until it re-scans and recognizes them (nothing gets\n"
        "    deleted or duplicated in your actual archive from this).\n"
        "  - manifest.csv is the important file in here: a plain-text record\n"
        "    of every file ever imported. manifest_index/ and\n"
        "    manifest_cache.sqlite are just speed optimizations built from it -\n"
        "    safe to delete on their own any time, at no cost beyond a slightly\n"
        "    slower next run while they rebuild.\n"
        "  - logs/ holds a record of each past run, in case something needs\n"
        "    checking later.\n"
    )


def write_ingest_tool_readme(tool_dir: Path) -> None:
    """Drops a short, plain-language note inside _ingest_tool the first
    time that folder is created, for the benefit of someone who has never
    seen this script and stumbles into it later. Never overwrites an
    existing copy, so it's harmless to call this on every run."""
    readme_path = tool_dir / "README.txt"
    if readme_path.exists():
        return
    try:
        readme_path.write_text(ingest_tool_readme_text(), encoding="utf-8")
    except OSError:
        pass


# --------------------------------------------------------------------------
# Filesystem helpers
# --------------------------------------------------------------------------

def unique_path(path: Path) -> Path:
    """If path already exists, append ' (1)', ' (2)', ... before the
    extension until a free path is found."""
    if not path.exists():
        return path
    stem, suffix, parent = path.stem, path.suffix, path.parent
    n = 1
    while True:
        candidate = parent / f"{stem} ({n}){suffix}"
        if not candidate.exists():
            return candidate
        n += 1


def should_ignore(name: str, patterns) -> bool:
    import fnmatch
    return any(fnmatch.fnmatch(name, pat) for pat in patterns)


def copy_and_verify_atomic(naive_path: Path, src_path: Path, expected_hash: str, is_dir: bool):
    """Atomically claims a destination filename and copies verified content
    into it. This matters when more than one person/process might be
    importing into the same destination at the same time: a plain "check
    if the name is free, then copy" has a race window between those two
    steps - two processes can both see a name as free and both proceed,
    and the second one to finish silently overwrites the first with no
    error. Verified directly: running two imports at once against a
    shared destination with colliding filenames caused real, silent data
    loss in roughly half of repeated trials before this fix.

    Instead, the underlying create-the-file (or create-the-directory)
    call itself is what succeeds or fails atomically at the filesystem
    level: only one process can ever win a given name. The loser simply
    notices the name is now taken and tries the next available name
    instead - exactly the same outcome as if the two imports had happened
    one after the other, just safe when they genuinely overlap in time.

    For files, os.O_CREAT | os.O_EXCL is the atomic primitive: it fails
    if the file already exists, rather than silently truncating it. For
    directories, os.mkdir() is used the same way (it fails on ANY
    existing entry at that path, file or directory, empty or not) -
    unlike os.rename()/shutil.move(), which on this platform can silently
    replace an existing *empty* directory with no error, which would
    reopen exactly the race this function exists to close.

    Returns the actual path the content was claimed under (may differ
    from naive_path if that name was already taken), or None if the copy
    didn't verify and was removed."""
    directory = naive_path.parent
    stem, suffix = naive_path.stem, naive_path.suffix
    directory.mkdir(parents=True, exist_ok=True)

    candidate = naive_path
    n = 0
    while True:
        claimed = False
        if is_dir:
            try:
                os.mkdir(candidate)  # atomic claim, regardless of what (if anything) is there
                claimed = True
            except FileExistsError:
                pass
            if claimed:
                try:
                    shutil.copytree(src_path, candidate, dirs_exist_ok=True)
                except Exception:
                    shutil.rmtree(candidate, ignore_errors=True)
                    raise
        else:
            try:
                fd = os.open(candidate, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                claimed = True
                try:
                    with os.fdopen(fd, "wb") as dst_f, open(src_path, "rb") as src_f:
                        shutil.copyfileobj(src_f, dst_f)
                except Exception:
                    try:
                        os.remove(candidate)
                    except OSError:
                        pass
                    raise
            except FileExistsError:
                pass

        if claimed:
            break
        n += 1
        if n > 1000:
            raise RuntimeError(f"Too many naming collisions while claiming a destination for {naive_path}")
        candidate = directory / f"{stem} ({n}){suffix}"

    actual = sha256_dir(candidate) if is_dir else sha256_file(candidate)
    if actual != expected_hash:
        if is_dir:
            shutil.rmtree(candidate, ignore_errors=True)
        else:
            try:
                candidate.unlink()
            except OSError:
                pass
        return None
    return candidate


# --------------------------------------------------------------------------
# Core ingest logic
# --------------------------------------------------------------------------

class Stats:
    def __init__(self):
        self.imported = 0
        self.duplicates = 0
        self.quarantined = 0
        self.errors = 0
        self.bytes_imported = 0
        self.empty_folders_removed = 0
        self.quarantine_details = []

    def summary(self) -> str:
        return (f"Imported: {self.imported} | Duplicates skipped: {self.duplicates} | "
                f"Quarantined (invalid name): {self.quarantined} | Errors: {self.errors} | "
                f"Data imported: {self.bytes_imported / (1024**2):.1f} MiB | "
                f"Empty folders removed: {self.empty_folders_removed}")


def ingest_item(
    src_path: Path,
    rel_dir: Path,
    is_dir: bool,
    standard: Standard,
    manifest: Manifest,
    dest_root: Path,
    quarantine_root: Path,
    args,
    logger: logging.Logger,
    csv_writer,
    stats: Stats,
):
    name = src_path.name
    action = None
    dest_path = None
    errors = []

    try:
        if is_dir:
            size = dir_size(src_path)
            file_hash = sha256_dir(src_path)
        else:
            size = src_path.stat().st_size
            file_hash = sha256_file(src_path)
    except OSError as exc:
        logger.error("Could not read %s: %s", src_path, exc)
        csv_writer.writerow([now_iso(), str(src_path), "error", "", "", f"unreadable: {exc}"])
        stats.errors += 1
        return

    existing = manifest.lookup(file_hash, name)
    if existing:
        log_file_only(logger, logging.INFO, "DUPLICATE  %s  (already imported as %s)", src_path, existing)
        csv_writer.writerow([now_iso(), str(src_path), "duplicate", existing, file_hash, ""])
        stats.duplicates += 1
        if args.delete_source and args.delete_duplicates and not args.dry_run:
            _remove(src_path, is_dir)
        return

    is_valid, groups, errors = standard.validate_name(name)

    if is_valid:
        folder = groups.get("areaCategory") or "_unsorted"
        naive_path = dest_root / folder / name
        action = "imported"
    else:
        naive_path = quarantine_root / rel_dir / name
        action = "quarantined"
        stats.quarantine_details.append(f"{name}  ->  {'; '.join(errors)}")

    if args.dry_run:
        dest_path = unique_path(naive_path) if naive_path.exists() else naive_path
        log_file_only(logger, logging.INFO, "[DRY RUN] %s -> %s%s", src_path, dest_path,
                       f"  [{'; '.join(errors)}]" if errors else "")
        csv_writer.writerow([now_iso(), str(src_path), f"dry-run-{action}", str(dest_path),
                              file_hash, "; ".join(errors)])
        if action == "imported":
            stats.imported += 1
        else:
            stats.quarantined += 1
        return

    # If something is already sitting at the natural destination path,
    # check whether it is in fact this exact same, already-verified
    # content - most commonly a copy that finished on an earlier,
    # interrupted run (power loss, disconnect, closed window) before it
    # could be recorded in the manifest. If so, adopt it in place rather
    # than leaving that unrecorded file sitting there AND creating a
    # confusing, redundant "(1)" copy next to it. Only a genuine content
    # match is ever adopted this way; anything else already at that path
    # is left completely untouched, and copy_and_verify_atomic below
    # claims a distinct name safely - even if another process is claiming
    # a name at this exact moment.
    already_present_verified = False
    if naive_path.exists():
        existing_is_dir = naive_path.is_dir()
        if existing_is_dir == is_dir:
            try:
                existing_hash = sha256_dir(naive_path) if is_dir else sha256_file(naive_path)
                if existing_hash == file_hash:
                    already_present_verified = True
            except OSError:
                pass  # unreadable existing item -> fall through to the safe claim below

    if already_present_verified:
        dest_path = naive_path
        log_file_only(logger, logging.INFO, "ALREADY THERE %s -> %s (matches exactly - likely left "
                       "over from an earlier interrupted run; adopted, not re-copied)", src_path, dest_path)
        csv_action = f"{action}-already-present"
    else:
        dest_path = copy_and_verify_atomic(naive_path, src_path, file_hash, is_dir)
        if not dest_path:
            logger.error("VERIFY FAILED copying %s -> %s (source left untouched)", src_path, naive_path)
            csv_writer.writerow([now_iso(), str(src_path), "verify-failed", str(naive_path), file_hash, ""])
            stats.errors += 1
            return
        csv_action = action

    # Record every successfully copied item (imported OR quarantined) in the
    # manifest, so re-running the tool never re-quarantines the same invalid
    # content again - it will be recognized as a duplicate instead.
    manifest.record(file_hash, name, str(src_path), str(dest_path), size)

    if action == "imported":
        stats.imported += 1
        stats.bytes_imported += size
        if not already_present_verified:
            log_file_only(logger, logging.INFO, "IMPORTED   %s -> %s", src_path, dest_path)
    else:
        stats.quarantined += 1
        if not already_present_verified:
            log_file_only(logger, logging.WARNING, "QUARANTINE %s -> %s  [%s]", src_path, dest_path, "; ".join(errors))

    csv_writer.writerow([now_iso(), str(src_path), csv_action, str(dest_path), file_hash, "; ".join(errors)])

    if args.delete_source:
        _remove(src_path, is_dir)


def _remove(path: Path, is_dir: bool):
    try:
        if is_dir:
            shutil.rmtree(path)
        else:
            path.unlink()
    except OSError as exc:
        logging.getLogger("ingest").error("Could not delete source %s after import: %s", path, exc)


def remove_empty_folders(root: Path, exclude_paths) -> list:
    """Only ever removes a folder that ends up COMPLETELY empty - no files
    (not even ignored junk like Thumbs.db) and no subfolders. A folder
    holding anything left behind on purpose (an ignored file, something
    that failed to copy, an error) is never touched. The root itself is
    never removed, only its descendants. Processes deepest-first so an
    emptied child correctly allows its now-empty parent to be removed in
    the same pass."""
    exclude_set = {str(p) for p in exclude_paths}
    all_dirs = []
    for dirpath, dirnames, _filenames in os.walk(root):
        for d in dirnames:
            all_dirs.append(Path(dirpath) / d)
    all_dirs.sort(key=lambda p: len(p.parts), reverse=True)

    removed = []
    for d in all_dirs:
        if str(d) in exclude_set:
            continue
        try:
            if not any(d.iterdir()):
                d.rmdir()
                removed.append(str(d))
        except OSError:
            pass  # not empty, in use, or no permission - best-effort tidy-up only
    return removed


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def collect_ingest_items(source_root: Path, standard, dest_root: Path, quarantine_root: Path, args):
    """Walks the source tree once and returns a flat list of (path, rel_dir,
    is_dir) tuples still to process (files, plus BagIt-style folders
    treated as one unit each). Collecting this list upfront - rather than
    processing items inline during the walk - is what lets the progress
    bar show an accurate "X of Y" and percentage instead of just a moving
    counter."""
    ignore_patterns = args.ignore.split(",") if args.ignore else []
    items = []

    for root, dirs, files in os.walk(source_root):
        root_path = Path(root)
        rel_dir = root_path.relative_to(source_root)

        dirs[:] = [d for d in dirs if (root_path / d).resolve() not in (dest_root.resolve(), quarantine_root.resolve())]

        bag_dirs = [d for d in dirs if standard.is_bag_dir(d)]
        for d in bag_dirs:
            items.append((root_path / d, rel_dir, True))
            dirs.remove(d)

        for fname in files:
            if should_ignore(fname, ignore_patterns):
                continue
            items.append((root_path / fname, rel_dir, False))

    return items


def print_progress(activity: str, current: int, total: int, label: str):
    # Only draws a live-updating bar on a real terminal; when output is
    # redirected to a file (e.g. a scheduled task's log), a bar redrawn
    # with carriage returns would just bloat the file with junk, so this
    # stays silent in that case - the final summary still prints normally.
    if not sys.stdout.isatty():
        return
    width = 30
    frac = (current / total) if total > 0 else 1.0
    filled = int(width * frac)
    bar = "#" * filled + "-" * (width - filled)
    pct = int(frac * 100)
    line = f"\r{activity}: [{bar}] {pct}% ({current}/{total}) {label}"
    sys.stdout.write(line.ljust(100)[:100])
    sys.stdout.flush()


def clear_progress():
    if not sys.stdout.isatty():
        return
    sys.stdout.write("\r" + " " * 100 + "\r")
    sys.stdout.flush()


def print_quarantine_details(details, max_shown: int = 15):
    # Caps how many individual reasons are printed to the console so a
    # large batch of invalid files doesn't flood the screen; the full,
    # uncapped list always lives in the CSV report regardless.
    if not details:
        return
    print()
    print("Files set aside, and why:")
    shown = min(len(details), max_shown)
    for d in details[:shown]:
        print(f"  - {d}")
    if len(details) > max_shown:
        print(f"  ... and {len(details) - max_shown} more - see the full report for the complete list.")


def walk_and_ingest(source_root: Path, standard, manifest, dest_root, quarantine_root, args, logger, csv_writer, stats):
    items = collect_ingest_items(source_root, standard, dest_root, quarantine_root, args)
    total = len(items)
    activity = "Checking files (dry run)" if args.dry_run else "Importing files"

    for i, (path, rel_dir, is_dir) in enumerate(items, start=1):
        print_progress(activity, i, total, path.name)
        ingest_item(path, rel_dir, is_dir, standard, manifest, dest_root,
                    quarantine_root, args, logger, csv_writer, stats)
    clear_progress()


# --------------------------------------------------------------------------
# Archive verification (--verify): read-only integrity and completeness
# check against the manifest. Answers two separate questions:
#   1. Is everything the manifest says should be here actually here,
#      unmodified? (checked by re-hashing every tracked file)
#   2. Is there anything present in the archive that the manifest doesn't
#      know about - e.g. a file added manually, outside this tool?
# This never copies, moves, or deletes anything.
# --------------------------------------------------------------------------

def verify_archive(dest_root: Path, regex_url: str, cache_path: Path):
    print()
    print("=" * 70)
    print(f" Verifying archive: {dest_root}")
    print("=" * 70)
    print("This only reads and checks - nothing is copied, moved, or deleted.")
    print()

    migrate_legacy_layout(dest_root)
    tool_dir = dest_root / INGEST_TOOL_DIR_NAME
    manifest_csv_path = tool_dir / "manifest.csv"
    sqlite_path = tool_dir / "manifest_cache.sqlite"
    # The shared CSV, not this tool's own SQLite cache, is the real sign
    # that anything has ever been recorded here - an archive that's only
    # ever been imported into with the PowerShell version has a CSV but
    # no SQLite cache yet, and still has a perfectly good manifest to
    # check against.
    if not manifest_csv_path.exists() and not sqlite_path.exists():
        print(f"No manifest found in: {tool_dir}")
        print("There's nothing recorded to check the archive's contents against.")
        print("If this archive was built with this tool before, the manifest may")
        print("simply have been lost - re-running a normal import against the")
        print("original source (if you still have it) will safely rebuild it,")
        print("recognizing everything already here without duplicating anything.")
        return

    manifest = Manifest(sqlite_path)
    rows = manifest.all_entries()
    manifest.close()
    print(f"Manifest entries to check: {len(rows)}")
    print()

    log_dir = tool_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    write_ingest_tool_readme(tool_dir)
    report_path = log_dir / f"verify_{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}.csv"

    ok_count = 0
    missing = []
    changed = []
    tracked_paths = set()

    with open(report_path, "w", newline="", encoding="utf-8") as report_file:
        writer = csv.writer(report_file)
        writer.writerow(["category", "path", "recorded_hash", "notes"])

        for file_hash, original_name, dest_path_str in rows:
            p = Path(dest_path_str)
            tracked_paths.add(str(p))
            if not p.exists():
                missing.append(str(p))
                writer.writerow(["missing", str(p), file_hash, "listed in the manifest but not found on disk"])
                continue
            try:
                live_hash = sha256_dir(p) if p.is_dir() else sha256_file(p)
            except OSError as exc:
                changed.append(str(p))
                writer.writerow(["unreadable", str(p), file_hash, str(exc)])
                continue
            if live_hash != file_hash:
                changed.append(str(p))
                writer.writerow(["changed", str(p), file_hash, "content on disk no longer matches the recorded hash"])
            else:
                ok_count += 1

        print(f"Checked {len(rows)} tracked item(s):")
        print(f"  {ok_count} OK - content matches exactly what was recorded")
        if missing:
            print(f"  {len(missing)} MISSING - listed in the manifest but not found on disk:")
            for m in missing:
                print(f"    - {m}")
        if changed:
            print(f"  {len(changed)} CHANGED - content no longer matches what was recorded:")
            for c in changed:
                print(f"    - {c}")

        print()
        print("Scanning for files present in the archive that the manifest doesn't")
        print("know about (for example, something added manually)...")

        standard = None
        try:
            standard = Standard.load(regex_url, cache_path, force_refresh=False)
        except RuntimeError:
            print("  (Could not load the naming standard to check untracked filenames - skipping that detail.)")

        tool_dir_str = str(tool_dir)
        orphans = []
        for root, dirs, files in os.walk(dest_root):
            root_path = Path(root)
            if str(root_path).startswith(tool_dir_str):
                continue
            for fname in files:
                if fname in (".ingest_manifest.sqlite", ".ingest_manifest.csv"):
                    continue  # leftovers from an archive not yet tidied up
                fpath = root_path / fname
                if str(fpath) not in tracked_paths:
                    note = ""
                    if standard is not None:
                        is_valid, _groups, errors = standard.validate_name(fname)
                        note = "name matches the standard" if is_valid else \
                            f"name would NOT pass validation: {'; '.join(errors)}"
                    orphans.append(str(fpath))
                    writer.writerow(["untracked", str(fpath), "", note])

        if orphans:
            print(f"  {len(orphans)} untracked file(s) found:")
            for o in orphans:
                print(f"    - {o}")
            print("  These aren't necessarily a problem - they just didn't come through")
            print("  this tool, so their name/content was never checked or recorded.")
        else:
            print("  None found - every file in the archive is accounted for.")

    print()
    print(f"Full report: {report_path}")
    print("=" * 70)


# --------------------------------------------------------------------------
# CLI / main
# --------------------------------------------------------------------------

def build_logger(log_dir: Path) -> logging.Logger:
    log_dir.mkdir(parents=True, exist_ok=True)
    # A short random suffix (not just the timestamp) guarantees uniqueness
    # even if two runs against the same destination start in the same
    # second - a real possibility once more than one person can be
    # importing into a shared destination at once. Without it, two such
    # runs would collide on the same log/CSV filename and interleave.
    ts = time.strftime("%Y%m%d-%H%M%S")
    unique = uuid.uuid4().hex[:6]
    log_file = log_dir / f"ingest_{ts}-{unique}.log"

    logger = logging.getLogger("ingest")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)-8s %(message)s"))
    logger.addHandler(fh)

    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(logging.Formatter("%(levelname)-8s %(message)s"))
    logger.addHandler(ch)

    # Kept so log_file_only() can write to just this handler, bypassing
    # the console handler above, for high-volume per-item lines.
    logger.file_handler = fh

    return logger, log_file


def log_file_only(logger: logging.Logger, level: int, message: str, *args):
    # For high-volume, per-item routine lines (one per file processed)
    # that belong in the full log/CSV record but would otherwise flood
    # and scroll past the console on a large run. Warnings, errors,
    # headers, and summaries always go through logger.info/warning/error
    # instead, so they still reach the console too.
    record = logger.makeRecord(logger.name, level, "", 0, message, args, None)
    logger.file_handler.emit(record)


def run_ingest_pass(source_root: Path, dest_root: Path, quarantine_root: Path, log_dir: Path,
                     regex_url: str, cache_dir: Path, refresh_standard: bool, options):
    """Runs one full pass over the source tree (either a preview or a real
    run, depending on options.dry_run) and returns (stats, log_file,
    csv_path). Safe to call twice in the same process - the wizard does
    exactly that (once to preview, once for real). `options` needs
    dry_run, delete_source, delete_duplicates, remove_empty_folders and
    ignore attributes - the same shape as the argparse Namespace the
    plain command-line mode already builds, so a lightweight
    SimpleNamespace works just as well for the wizard."""
    logger, log_file = build_logger(log_dir)
    logger.info("=== Media Ingest Tool ===")
    logger.info("Source:      %s", source_root)
    logger.info("Destination: %s", dest_root)
    logger.info("Quarantine:  %s", quarantine_root)
    if options.dry_run:
        mode_text = "PREVIEW (nothing will be changed)"
        if options.delete_source and options.remove_empty_folders:
            mode_text += " - a real run would also remove any folders left empty afterward"
    elif options.delete_source:
        mode_text = "copy + delete verified source (move)"
        if options.remove_empty_folders:
            mode_text += ", then remove any folders left empty on the source"
    else:
        mode_text = "copy only (source kept)"
    logger.info("Mode:        %s", mode_text)

    cache_path = cache_dir / "medienstandard.json"
    standard = Standard.load(regex_url, cache_path, force_refresh=refresh_standard, logger=logger)

    write_ingest_tool_readme(dest_root / INGEST_TOOL_DIR_NAME)
    manifest = Manifest(dest_root / INGEST_TOOL_DIR_NAME / "manifest_cache.sqlite")
    stats = Stats()
    csv_path = log_dir / (log_file.stem + ".csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as csv_file:
        csv_writer = csv.writer(csv_file)
        csv_writer.writerow(["timestamp", "source_path", "action", "dest_path", "sha256", "notes"])

        try:
            walk_and_ingest(source_root, standard, manifest, dest_root, quarantine_root,
                             options, logger, csv_writer, stats)
        except KeyboardInterrupt:
            logger.warning("Interrupted by user. Partial progress has been recorded in the manifest/log.")
        finally:
            manifest.close()

        if options.delete_source and options.remove_empty_folders and not options.dry_run:
            removed = remove_empty_folders(source_root, [dest_root, quarantine_root])
            stats.empty_folders_removed = len(removed)
            for f in removed:
                log_file_only(logger, logging.INFO, "REMOVED EMPTY FOLDER  %s", f)

    logger.info("=== Done ===")
    logger.info(stats.summary())
    return stats, log_file, csv_path


# ---------------------------------------------------------------------------
# Interactive wizard - plain questions, sensible defaults, always previews.
# Mirrors the PowerShell version's wizard closely (including the shared
# ingest-settings.txt format), so the experience - and the settings file
# itself - are consistent regardless of which version someone runs.
# ---------------------------------------------------------------------------

def get_default_config_path() -> Path:
    return Path(__file__).resolve().parent / "ingest-settings.txt"


def read_ingest_config(path: Path):
    if not path.exists():
        return None
    try:
        values = {}
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            values[key.strip()] = val.strip()
        return {
            "source": values.get("Source", ""),
            "dest": values.get("Dest", ""),
            "move": values.get("Mode", "").strip().lower() == "move",
            "quarantine": values.get("Quarantine", ""),
        }
    except OSError:
        return None


def write_ingest_config(path: Path, source: str, dest: str, move: bool, quarantine: str = "") -> bool:
    mode_text = "Move" if move else "Copy"
    lines = [
        "# Media Ingest Tool - Configuration",
        "#",
        "# Edit the values below, save this file, and run the tool again.",
        "# Lines starting with # are ignored. These settings are used",
        "# automatically next time - you only need to change them when",
        "# something actually changes (a different source, a different",
        "# destination folder, and so on).",
        "",
        "# Where your files come from:",
        f"Source = {source}",
        "",
        "# Where they should go:",
        f"Dest = {dest}",
        "",
        "# Copy (keep the originals at the source too) or Move (delete from",
        "# the source once safely copied and verified)? Type Copy or Move:",
        f"Mode = {mode_text}",
        "",
        "# Advanced (optional). Where files with an invalid name are set",
        "# aside for you to review. Leave blank to use the default shown",
        "# below - it lives at the destination deliberately, so that even in",
        "# Move mode, invalid files still get a safe, verified copy",
        "# somewhere before anything is ever removed from the source.",
        f"# Default if left blank: {dest}/_quarantine",
        f"Quarantine = {quarantine}",
    ]
    try:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return True
    except OSError:
        return False


def clean_typed_path(raw: str) -> str:
    """Cleans up a path typed, pasted, or dragged in from Finder - Finder
    drops paths with backslash-escaped spaces rather than quotes, so both
    styles (and a plain unquoted path) are handled."""
    s = raw.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    s = s.replace("\\ ", " ")
    return s.strip()


def read_yes_no(prompt: str, default_yes: bool = True) -> bool:
    suffix = "[Y/n]" if default_yes else "[y/N]"
    while True:
        try:
            resp = input(f"{prompt} {suffix} ").strip().lower()
        except EOFError:
            # Input unexpectedly ran out (e.g. piped input, a closed
            # terminal) - treat this like declining, the safe choice for
            # every place this function is used, rather than crashing
            # with a raw traceback.
            print()
            return False
        if not resp:
            return default_yes
        if resp in ("y", "yes"):
            return True
        if resp in ("n", "no"):
            return False
        print("  Please answer y or n.")


def read_folder_path(question: str, remembered: str, must_exist: bool) -> str:
    print()
    print(question)
    print("  Tip: you can drag the folder from Finder and drop it into this window, then press Enter.")
    while True:
        prompt = f"  Folder (Enter to reuse: {remembered}): " if remembered else "  Folder: "
        try:
            resp = input(prompt)
        except EOFError:
            # Input unexpectedly ran out. With a remembered value, treat
            # this exactly like pressing Enter to reuse it. Without one,
            # there's nothing left to fall back on and retrying would spin
            # forever re-hitting the same EOF, so stop cleanly instead.
            if remembered:
                resp = ""
            else:
                print("\n  No input available and no folder to fall back on - stopping.")
                sys.exit(1)
        resp = clean_typed_path(resp)
        if not resp:
            if remembered:
                resp = remembered
            else:
                print("  Please enter a folder path.")
                continue
        candidate = Path(resp).expanduser()
        if must_exist:
            if not candidate.is_dir():
                print(f"  Can't find that folder: {candidate}")
                continue
            return str(candidate.resolve())
        else:
            if not candidate.exists():
                if not read_yes_no("  That folder doesn't exist yet. Create it?", True):
                    continue
                try:
                    candidate.mkdir(parents=True, exist_ok=True)
                except OSError as exc:
                    print(f"  Could not create that folder: {exc}")
                    continue
            return str(candidate.resolve())


def run_wizard():
    print()
    print("=" * 68)
    print(" Media Ingest Tool")
    print("=" * 68)
    print("This copies files from your source into a structured archive at")
    print("your destination, checking every filename against your naming")
    print("standard on the way. Files with valid names are sorted into")
    print("folders automatically; anything with an invalid name is set")
    print("aside for you to look at - nothing is ever silently dropped.")
    print()

    config_path = get_default_config_path()
    config = read_ingest_config(config_path) or {"source": "", "dest": "", "move": False, "quarantine": ""}

    source_path = dest_path = None
    move_choice = False
    quarantine_override = ""
    use_config = False

    if config["source"] and config["dest"]:
        source_ok = Path(config["source"]).is_dir()
        print(f"Found saved settings in: {config_path}")
        note = "   <- not available right now" if not source_ok else ""
        print(f"  Source: {config['source']}{note}")
        print(f"  Dest:   {config['dest']}")
        print(f"  Mode:   {'Move' if config['move'] else 'Copy'}")
        if config["quarantine"]:
            print(f"  Quarantine: {config['quarantine']}")
        print()
        if source_ok:
            use_config = read_yes_no("Use these settings?", True)
        else:
            print("The saved source folder isn't available right now - it may be")
            print("disconnected, unmounted, or have moved since it was saved.")

    if use_config:
        source_path = str(Path(config["source"]).resolve())
        dest_candidate = Path(config["dest"])
        dest_ok = True
        if not dest_candidate.exists():
            try:
                dest_candidate.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                print(f"  Could not reach or create the saved destination: {config['dest']}")
                print(f"  ({exc})")
                dest_ok = False
        if dest_ok:
            dest_path = str(dest_candidate.resolve())
            move_choice = config["move"]
            quarantine_override = config["quarantine"]
        else:
            use_config = False

    if not use_config:
        source_path = read_folder_path("1) Where are your files coming from?", config["source"], must_exist=True)
        dest_path = read_folder_path("2) Where should they go?", config["dest"], must_exist=False)
        quarantine_override = config["quarantine"]

        print()
        print("3) Once a file has been safely copied and double-checked, should the")
        print("   original also be removed from the source?")
        print("     [1] No, keep it at the source too (safest - default)")
        print("     [2] Yes, move it - also cleans up any folders left empty")
        print("         at the source afterward, to actually free up space")
        default_choice = "2" if config["move"] else "1"
        move_answered = False
        while not move_answered:
            try:
                resp = input(f"   Choice (1 or 2, Enter for {default_choice}): ").strip()
            except EOFError:
                resp = default_choice
            if not resp:
                resp = default_choice
            if resp == "1":
                move_choice, move_answered = False, True
            elif resp == "2":
                move_choice, move_answered = True, True
            else:
                print("   Please type 1 or 2.")

    saved = write_ingest_config(config_path, source_path, dest_path, move_choice, quarantine_override)
    print()
    if saved:
        print(f"(Settings saved to {config_path} - edit that file directly any time to change them.)")

    source_root = Path(source_path)
    dest_root = Path(dest_path)
    dest_root.mkdir(parents=True, exist_ok=True)
    migrate_legacy_layout(dest_root)
    if quarantine_override:
        quarantine_root = Path(quarantine_override)
        quarantine_root.mkdir(parents=True, exist_ok=True)
    else:
        quarantine_root = dest_root / "_quarantine"
        quarantine_root.mkdir(parents=True, exist_ok=True)
    log_dir = dest_root / INGEST_TOOL_DIR_NAME / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    regex_url = STANDARD_URL_DEFAULT
    cache_dir = Path.home() / ".cache" / "medienstandard"
    ignore = ",".join(DEFAULT_IGNORE)

    print()
    print("Checking your files now - this is just a preview, nothing will change yet...")
    print()
    preview_options = SimpleNamespace(dry_run=True, delete_source=move_choice,
                                       delete_duplicates=move_choice,
                                       remove_empty_folders=move_choice, ignore=ignore)
    try:
        preview_stats, _, _ = run_ingest_pass(source_root, dest_root, quarantine_root, log_dir,
                                               regex_url, cache_dir, False, preview_options)
    except RuntimeError as exc:
        print(f"\nERROR: {exc}")
        return

    print()
    print("-" * 68)
    print("Preview complete:")
    print(f"  {preview_stats.imported} file(s) would be imported")
    print(f"  {preview_stats.quarantined} file(s) would be set aside (invalid names)")
    print(f"  {preview_stats.duplicates} file(s) are already in the archive (would be skipped)")
    if preview_stats.errors > 0:
        print(f"  {preview_stats.errors} file(s) could not even be read - see the log")
    print_quarantine_details(preview_stats.quarantine_details)
    print("-" * 68)

    if preview_stats.imported == 0 and preview_stats.quarantined == 0:
        print()
        print("Nothing new to do - every file is already in the archive.")
        return

    print()
    go_ahead = read_yes_no("Proceed with the real import now?", False)
    if not go_ahead:
        print("Cancelled. Nothing was changed.")
        return

    print()
    print("Importing for real now...")
    print()
    real_options = SimpleNamespace(dry_run=False, delete_source=move_choice,
                                    delete_duplicates=move_choice,
                                    remove_empty_folders=move_choice, ignore=ignore)
    try:
        real_stats, _, real_csv = run_ingest_pass(source_root, dest_root, quarantine_root, log_dir,
                                                   regex_url, cache_dir, False, real_options)
    except RuntimeError as exc:
        print(f"\nERROR: {exc}")
        return

    print()
    print("-" * 68)
    print("Done!")
    print(f"  {real_stats.imported} file(s) imported into: {dest_root}")
    print(f"  {real_stats.quarantined} file(s) set aside into: {quarantine_root}")
    print(f"  {real_stats.duplicates} duplicate(s) skipped")
    if real_stats.empty_folders_removed > 0:
        print(f"  {real_stats.empty_folders_removed} empty folder(s) removed from the source")
    if real_stats.errors > 0:
        print(f"  {real_stats.errors} error(s) - see the log for details")
    print(f"  Full report: {real_csv}")
    print("-" * 68)


def parse_args():
    p = argparse.ArgumentParser(
        description="Safely ingest and validate media files from a source folder into a structured archive.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--source", type=Path, default=None, help="Source directory.")
    p.add_argument("--dest", type=Path, default=None, help="Destination archive root.")
    p.add_argument("--verify", action="store_true",
                   help="Read-only integrity check of --dest against its manifest. Checks every tracked "
                        "file is still present and unmodified, and flags anything in the archive that "
                        "isn't in the manifest (e.g. added manually). Does not need --source; copies, "
                        "moves, or deletes nothing.")
    p.add_argument("--quarantine", type=Path, default=None,
                   help="Where invalid files go. Default: <dest>/_quarantine")
    p.add_argument("--log-dir", type=Path, default=None,
                   help="Where run logs/CSV go. Default: <dest>/_ingest_tool/logs")
    p.add_argument("--regex-url", default=STANDARD_URL_DEFAULT, help="URL of the medienstandard JSON.")
    p.add_argument("--cache-dir", type=Path, default=Path.home() / ".cache" / "medienstandard",
                   help="Local cache location for the standard (used if the URL is unreachable).")
    p.add_argument("--refresh-standard", action="store_true",
                   help="Force re-download of the standard even if a fresh cache exists.")
    p.add_argument("--dry-run", action="store_true", help="Report what would happen; touch nothing.")
    p.add_argument("--delete-source", action="store_true",
                   help="After a VERIFIED copy, delete the source file/folder. Default: off (copy-only).")
    p.add_argument("--delete-duplicates", action="store_true",
                   help="Combined with --delete-source: also delete source files that turn out to be "
                        "duplicates of something already imported. Default: off (leave duplicates in place).")
    p.add_argument("--remove-empty-folders", action="store_true",
                   help="Combined with --delete-source: after the run, remove any source folders left "
                        "completely empty (no files, not even ignored junk like Thumbs.db, and no "
                        "subfolders). Has no effect without --delete-source. Never removes the source "
                        "root itself.")
    p.add_argument("--ignore", default=",".join(DEFAULT_IGNORE),
                   help="Comma-separated glob patterns of files to skip entirely (not copied, not quarantined).")
    return p.parse_args()


def main():
    args = parse_args()

    if args.verify:
        if not args.dest:
            print("ERROR: --verify requires --dest (the archive to check).", file=sys.stderr)
            sys.exit(1)
        dest_root = args.dest.resolve()
        if not dest_root.is_dir():
            print(f"ERROR: destination directory does not exist: {dest_root}", file=sys.stderr)
            sys.exit(1)
        cache_path = args.cache_dir / "medienstandard.json"
        verify_archive(dest_root, args.regex_url, cache_path)
        return

    if args.source or args.dest:
        # Explicit flags given: classic non-interactive command-line mode.
        if not args.source or not args.dest:
            print("ERROR: both --source and --dest are required when running non-interactively.", file=sys.stderr)
            sys.exit(1)

        source_root = args.source.resolve()
        if not source_root.is_dir():
            print(f"ERROR: source directory does not exist: {source_root}", file=sys.stderr)
            sys.exit(1)

        dest_root = args.dest.resolve()
        dest_root.mkdir(parents=True, exist_ok=True)
        migrate_legacy_layout(dest_root)
        quarantine_root = (args.quarantine or (dest_root / "_quarantine")).resolve()
        quarantine_root.mkdir(parents=True, exist_ok=True)
        log_dir = (args.log_dir or (dest_root / INGEST_TOOL_DIR_NAME / "logs")).resolve()
        log_dir.mkdir(parents=True, exist_ok=True)

        if args.remove_empty_folders and not args.delete_source:
            print("NOTE: --remove-empty-folders has no effect without --delete-source (nothing is ever "
                  "deleted from the source in copy-only mode, so no folder can become empty as a result).")

        try:
            stats, log_file, csv_path = run_ingest_pass(
                source_root, dest_root, quarantine_root, log_dir,
                args.regex_url, args.cache_dir, args.refresh_standard, args,
            )
        except RuntimeError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(2)

        print_quarantine_details(stats.quarantine_details)
        print(f"Full log: {log_file}")
        print(f"CSV report: {csv_path}")
    else:
        # No flags at all: interactive wizard, for people who'd rather
        # answer three plain questions than remember command-line flags.
        run_wizard()


if __name__ == "__main__":
    main()
