<#
.SYNOPSIS
    Safely, cleanly and reliably ingests files from a source folder into
    a structured, validated archive at a destination you choose. No
    Python, no modules to install, no admin rights.

.DESCRIPTION
    Run this with no arguments (e.g. by double-clicking "Run Ingest
    Tool.cmd") and it walks you through three plain questions - where the
    files are, where they should go, and whether to copy or move - then
    ALWAYS shows you a safe preview before touching anything.

    Prefer the command line? Pass -Source and -Dest and it behaves exactly
    like a normal script (see the parameters below) - no prompts.

    Filenames are validated against the "medienstandard" JSON definition:
      https://raw.githubusercontent.com/knisterstern1/medienstandard/refs/heads/main/medienstandard_v3-1_2026_regex.json

    Per file:
      1. Compute a SHA-256 hash of the source file.
      2. If that exact content was already imported OR already quarantined
         before -> skip it. Re-running this tool is always safe.
      3. Validate the filename.
           VALID   -> <Dest>\<areaCategory>\<filename>
                      ("areaCategory" = the filename's prefix WITHOUT the
                      1-character owner code, e.g. r11, d11, w1a)
           INVALID -> <Quarantine>\<relative-source-subpath>\<filename>,
                      with the precise reason logged.
      4. Copy, then re-hash the COPY and compare it to the source hash.
         Only a verified copy counts as done.
      5. Only if verification succeeded AND you chose "move", the source
         is removed. Otherwise the source is never touched.

    BagIt-style folders (e.g. "..._s-part-bag") are treated as ONE atomic
    object instead of being split file by file.

.PARAMETER Source
    Source folder. Omit this (and -Dest) to get the interactive wizard
    instead.

.PARAMETER Dest
    Destination archive root.

.EXAMPLE
    .\Ingest-MediaFiles.ps1
    (interactive wizard - recommended for most people)

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Ingest-MediaFiles.ps1 -Source "D:\" -Dest "E:\Archive" -DryRun
    (power-user command line, no prompts)
#>

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Dest,
    [string]$Quarantine,
    [string]$LogDir,
    [string]$RegexUrl = "https://raw.githubusercontent.com/knisterstern1/medienstandard/refs/heads/main/medienstandard_v3-1_2026_regex.json",
    [string]$CacheDir = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "medienstandard" } else { Join-Path $HOME ".cache/medienstandard" }),
    [switch]$RefreshStandard,
    [switch]$Verify,
    [switch]$DryRun,
    [switch]$DeleteSource,
    [switch]$DeleteDuplicates,
    [switch]$RemoveEmptyFolders,
    [string]$IgnorePatterns = ".DS_Store,Thumbs.db,desktop.ini,Desktop.ini,~`$*,*.tmp,*.part"
)

# The bundled-standard fallback (see Get-Standard) only applies when using
# the actual default URL, not a custom -RegexUrl someone deliberately
# pointed elsewhere - this literal must always match the -RegexUrl default
# above.
$script:DefaultRegexUrlConstant = "https://raw.githubusercontent.com/knisterstern1/medienstandard/refs/heads/main/medienstandard_v3-1_2026_regex.json"

# ===========================================================================
# Small helpers: logging, CSV
# ===========================================================================

function Invoke-WithIoRetry {
    # Network shares (NAS/SMB in particular) sometimes report a file as
    # briefly "in use by another process" for reasons that have nothing
    # to do with anything actually being wrong - antivirus scanning the
    # file right after it's written, an SMB oplock break, momentary
    # contention from another user's session on the same archive. Seen
    # directly on a real NAS: Add-Content failing with exactly that
    # transient error on a per-file log line, even though the
    # corresponding file copy (the part that actually matters) succeeded
    # every time. Retrying briefly rides out the hiccup instead of
    # surfacing it as an alarming error for something that isn't broken.
    param([scriptblock]$Action, [int]$MaxAttempts = 6, [int]$InitialDelayMs = 100)
    $attempt = 0
    while ($true) {
        try { & $Action; return }
        catch [System.IO.IOException] {
            $attempt++
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Milliseconds ($InitialDelayMs * $attempt)
        }
    }
}

function Open-IngestLogFile {
    # Opens $Path as a persistent, held-open writer for the rest of this
    # run (or until the next Open-IngestLogFile call), rather than the
    # open-append-close cycle Add-Content does on every single log line.
    # On a local disk that cycle is cheap; on a network share it's the
    # main thing that invites the transient locking errors above, since
    # every one of those hundreds of per-file log lines was its own
    # separate open/close round-trip to the NAS. Holding one handle open
    # for the run avoids almost all of that exposure, and is faster too.
    param([string]$Path)
    if ($script:LogFileWriter) {
        try { $script:LogFileWriter.Dispose() } catch { }
        $script:LogFileWriter = $null
    }
    Invoke-WithIoRetry -Action {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $script:LogFileWriter = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        $script:LogFileWriter.AutoFlush = $true
    }
    $script:LogFile = $Path
}

function Close-IngestLogFile {
    if ($script:LogFileWriter) {
        try { $script:LogFileWriter.Dispose() } catch { }
        $script:LogFileWriter = $null
    }
}

function Write-IngestLog {
    # -FileOnly is used for high-volume, per-item routine lines (one per
    # file processed) that belong in the full log/CSV record but would
    # otherwise flood and scroll past the console on a large run. Warnings,
    # errors, headers, and summaries are never -FileOnly - they always
    # reach the console too.
    param([string]$Level, [string]$Message, [switch]$FileOnly)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts [$Level] $Message"
    try {
        if ($script:LogFileWriter) {
            Invoke-WithIoRetry -Action { $script:LogFileWriter.WriteLine($line) }
        }
        elseif ($script:LogFile) {
            # Fallback for anywhere the persistent writer isn't set up
            # yet. Not Add-Content - see Add-CsvRow for why.
            Invoke-WithIoRetry -Action {
                $fs = [System.IO.File]::Open($script:LogFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $w = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
                try { $w.WriteLine($line) } finally { $w.Dispose() }
            }
        }
    }
    catch {
        # A run's actual work (copying and verifying files) never depends
        # on the log file - losing one line to a stubborn NAS hiccup isn't
        # worth aborting or alarming over. Say so once, plainly, and keep
        # going; the console output and CSV report still have the record.
        if (-not $script:LogWriteWarned) {
            Write-Host "  (Note: couldn't write to the log file just now - continuing anyway. $($_.Exception.Message))" -ForegroundColor Yellow
            $script:LogWriteWarned = $true
        }
    }
    if ($FileOnly) { return }
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function ConvertTo-CsvField {
    param([string]$Value)
    if ($null -eq $Value) { $Value = "" }
    return '"' + ($Value -replace '"', '""') + '"'
}

function Add-CsvRow {
    # Used for the manifest, the per-run CSV report, and the -Verify
    # report - all real records, so unlike a routine log line this is
    # retried but never silently swallowed: a transient hiccup rides out
    # the retry, but a genuine, persistent failure still surfaces as a
    # real error rather than quietly losing a row.
    #
    # Deliberately NOT Add-Content. Seen directly on a real NAS:
    # Add-Content -Encoding UTF8 failed appending to an already-created
    # file with "the stream was not readable" (an ArgumentException,
    # not an IOException - it wasn't even a locking issue, so the retry
    # above couldn't have caught it anyway). Appending with an explicit
    # -Encoding makes Add-Content reopen the file with extra read
    # capability so it can sniff the file's existing encoding first;
    # that reopen apparently didn't succeed cleanly on that NAS/SMB
    # setup. Opening the file directly in FileMode.Append sidesteps this
    # structurally: .NET rejects FileMode.Append combined with read
    # access outright, so this path only ever requests - and only ever
    # needs - write access, the same way Open-IngestLogFile already does
    # for the main log (which never hit this failure).
    param([string]$Path, [string[]]$Fields)
    $line = ($Fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ','
    Invoke-WithIoRetry -Action {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        try { $writer.WriteLine($line) }
        finally { $writer.Dispose() }
    }
}

# ===========================================================================
# The standard: fetch, cache, compile
# ===========================================================================

function ConvertTo-DotNetRegex {
    # The standard's regex strings are URL-encoded Python-style patterns
    # (named groups written "(?P<name>...)"). .NET regex uses "(?<name>...)"
    # (no "P"), so decode, then fix the named-group syntax.
    param([string]$Encoded)
    $decoded = [System.Uri]::UnescapeDataString($Encoded)
    $decoded = $decoded -replace '\(\?P<', '(?<'
    return [regex]::new($decoded)
}

function Get-BundledStandardPath {
    # The standard also ships as a plain file right next to this script,
    # so a machine that has never had (or will never have) internet
    # access can still run the tool correctly from the very first run -
    # not just after a successful download has been cached once.
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return Join-Path $baseDir "medienstandard_v3-1_2026_regex.json"
}

function Get-Standard {
    param([string]$Url, [string]$CachePath, [bool]$Force)

    $raw = $null
    try {
        $cacheDirPath = Split-Path $CachePath -Parent
        if (-not (Test-Path -LiteralPath $cacheDirPath)) {
            New-Item -ItemType Directory -Path $cacheDirPath -Force | Out-Null
        }
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
        $raw = $resp.Content
        Set-Content -LiteralPath $CachePath -Value $raw -Encoding UTF8
    }
    catch {
        $downloadError = $_.Exception.Message
        if (Test-Path -LiteralPath $CachePath) {
            Write-IngestLog "WARN" "Could not download the naming standard ($downloadError); using the previously cached copy."
            $raw = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8
        }
        else {
            $bundledPath = Get-BundledStandardPath
            $isDefaultUrl = ($Url -eq $script:DefaultRegexUrlConstant)
            if ($isDefaultUrl -and (Test-Path -LiteralPath $bundledPath)) {
                Write-IngestLog "WARN" "Could not download the naming standard ($downloadError); using the copy bundled with this tool ($bundledPath)."
                $raw = Get-Content -LiteralPath $bundledPath -Raw -Encoding UTF8
                # Seed the cache too, so future runs (online or offline) find
                # it there directly without needing this fallback again.
                try { Set-Content -LiteralPath $CachePath -Value $raw -Encoding UTF8 } catch { }
            }
            else {
                throw "Could not download the medienstandard from $Url, no cached copy exists, and no bundled copy was found at $bundledPath. Cannot continue. Error: $downloadError"
            }
        }
    }

    $data = $raw | ConvertFrom-Json

    $rules = @()
    foreach ($rule in $data.rules) {
        $onError = @()
        foreach ($sub in $rule.onError) {
            $onError += [pscustomobject]@{
                Regex = ConvertTo-DotNetRegex $sub.regex
                Error = $sub.error
            }
        }
        $rules += [pscustomobject]@{
            Regex   = ConvertTo-DotNetRegex $rule.regex
            Error   = $rule.error
            OnError = $onError
        }
    }

    $standard = [pscustomobject]@{
        Version     = $data.info.version
        Year        = $data.info.year
        Pattern     = ConvertTo-DotNetRegex $data.pattern
        IncludeDirs = ConvertTo-DotNetRegex $data.includeDirs
        Rules       = $rules
    }
    Write-IngestLog "INFO" "Loaded naming standard v$($standard.Version) ($($standard.Year))"
    return $standard
}

function Test-MediaFileName {
    param([string]$Name, $Standard)

    $m = $Standard.Pattern.Match($Name)
    if ($m.Success) {
        $groups = @{}
        foreach ($gname in $Standard.Pattern.GetGroupNames()) {
            if ($gname -notmatch '^\d+$') {
                $groups[$gname] = $m.Groups[$gname].Value
            }
        }
        return [pscustomobject]@{ IsValid = $true; Groups = $groups; Errors = @() }
    }

    $errors = @()
    foreach ($rule in $Standard.Rules) {
        if ($rule.Regex.Match($Name).Success) { continue }  # rule satisfied
        $detail = $null
        foreach ($sub in $rule.OnError) {
            if ($sub.Regex.Match($Name).Success) { $detail = $sub.Error; break }
        }
        $msg = $rule.Error
        if ($detail) { $msg = "$msg ($detail)" }
        $errors += $msg
    }
    if ($errors.Count -eq 0) {
        $errors += "Filename does not match the naming standard (no specific reason found)."
    }
    return [pscustomobject]@{ IsValid = $false; Groups = @{}; Errors = $errors }
}

# ===========================================================================
# Hashing
# ===========================================================================

function Get-Sha256File {
    # A hand-rolled buffered hash rather than the Get-FileHash cmdlet.
    # Get-FileHash is well documented as meaningfully slower for large
    # files on some PowerShell/.NET configurations (particularly older
    # Windows PowerShell 5.1 setups); this reads in large, explicit
    # chunks instead and produces byte-identical results (verified
    # against Get-FileHash across empty, tiny, and large files). Costs
    # nothing where Get-FileHash was already fast, and removes a
    # plausible bottleneck where it wasn't.
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $buffer = New-Object byte[] (4MB)
            while ($true) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            }
            [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
            return -join ($sha.Hash | ForEach-Object { $_.ToString("x2") })
        }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-Sha256Dir {
    # Deterministic combined hash over every file's relative path + content
    # hash inside a directory tree. Used for BagIt-style bag folders.
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $base = (Resolve-Path -LiteralPath $Path).ProviderPath
    $items = Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object { $_.FullName }
    foreach ($item in $items) {
        $rel = $item.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
        $relBytes = [System.Text.Encoding]::UTF8.GetBytes($rel)
        [void]$sha.TransformBlock($relBytes, 0, $relBytes.Length, $null, 0)
        $fh = Get-Sha256File $item.FullName
        $fhBytes = [System.Text.Encoding]::UTF8.GetBytes($fh)
        [void]$sha.TransformBlock($fhBytes, 0, $fhBytes.Length, $null, 0)
    }
    [void]$sha.TransformFinalBlock(@(), 0, 0)
    $hex = ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ''
    $sha.Dispose()
    return $hex
}

function Get-DirSize {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return $sum
}

# ===========================================================================
# Manifest (dedupe database) - a simple append-only CSV, shared as-is with
# the Python version for cross-tool compatibility.
#
# Duplicate LOOKUPS, however, do not load that whole CSV into memory every
# run. Doing so is what makes a run's startup cost grow linearly with the
# archive's entire history (every file ever imported, by anyone, with
# either tool) even when this run only touches a handful of files - on a
# few-hundred-thousand-row archive that was measured at roughly 15-20
# seconds and ~300MB of RAM, paid again on every single run.
#
# Instead, lookups go through a small on-disk index that is private to
# this tool (never read by the Python version, so it can't affect cross-
# tool compatibility) and is kept in sync incrementally:
#   - The canonical _ingest_tool\manifest.csv is split by the first 2 hex
#     characters of each entry's hash into 256 small "shard" files
#     under _ingest_tool\manifest_index\shards\. A duplicate check for one
#     file only ever has to load its own shard (roughly 1/256th of the
#     archive's history) - not the whole archive.
#   - _ingest_tool\manifest_index\offset.txt records how many bytes of the
#     canonical CSV have already been folded into the shards. Each run
#     reads only the NEW bytes appended since the last sync (by this
#     tool or the Python one) and buckets just those new rows into their
#     shards - so the per-run cost tracks how much has changed since this
#     tool last ran, not how big the archive has grown to.
#   - If the canonical CSV is ever shorter than the recorded offset (it
#     was replaced or edited by hand), the index resets and rebuilds
#     itself from scratch - self-healing, and always safe to delete this
#     folder entirely; it is pure cache, never a source of truth.
#
# For someone importing a steady ~50 files per run into an archive that
# keeps growing, this keeps each run's manifest overhead roughly flat
# instead of creeping up forever with the archive's total size.
# ===========================================================================

function Get-ManifestKey {
    # Duplicate detection uses hash + filename together, not hash alone.
    # Two different, distinctly-named files that happen to contain
    # identical bytes (e.g. two blank/placeholder files, or the same
    # image reused under a different, meaningful standard filename) are
    # NOT the same archive entry and should both be kept. An exact repeat
    # of the same name AND the same content - a re-copy of a file already
    # in the archive, or the same source processed twice - is still caught.
    param([string]$HashValue, [string]$Name)
    return "$HashValue|$Name"
}

function Get-ManifestShardPrefix {
    param([string]$HashValue)
    if ($HashValue.Length -ge 2) { return $HashValue.Substring(0, 2).ToLowerInvariant() }
    return "_short"  # defensive fallback; real SHA-256 hex is always >= 2 chars
}

$script:CsvFieldSplitDelim = [string[]]@('","')

function ConvertFrom-CsvLine {
    # Fast, purpose-built parser for our own quoted-CSV format (every
    # field always wrapped in double quotes by ConvertTo-CsvField, with
    # "" as the escape for a literal quote, and no other field ever
    # containing a literal comma-quote-comma sequence).
    #
    # A per-character parsing loop was tried first and measured far
    # SLOWER than Import-Csv itself here - each character comparison is
    # an interpreted PowerShell statement, and there are tens of millions
    # of them across a few hundred thousand rows. A single-regex-match-
    # per-line approach was tried next and was faster but still took
    # about a minute at 300k rows. What actually wins is doing the one
    # per-line operation that PowerShell hands off entirely to native
    # .NET code: splitting on the fixed 3-character delimiter that only
    # ever appears between fields (","), then trimming the outer quotes
    # once. Verified against 300k synthetic rows: cold index build time
    # dropped from roughly a minute to a couple of seconds, matching
    # Import-Csv's own load time rather than being far slower than it.
    param([string]$Line)
    if ($Line.Length -lt 2) { return @() }
    $trimmed = $Line.Substring(1, $Line.Length - 2)
    $parts = $trimmed.Split($script:CsvFieldSplitDelim, [System.StringSplitOptions]::None)
    for ($j = 0; $j -lt $parts.Length; $j++) {
        if ($parts[$j].IndexOf('"') -ge 0) { $parts[$j] = $parts[$j].Replace('""', '"') }
    }
    return $parts
}

function Get-ManifestIndexDir {
    param([string]$ManifestPath)
    return (Join-Path (Split-Path -Path $ManifestPath -Parent) "manifest_index")
}

function Move-LegacyArchiveLayout {
    # One-time, best-effort tidy-up for archives built by an older
    # version of this tool, back when the manifest/index/logs lived
    # loose at the destination root (.ingest_manifest.csv, _logs, etc.)
    # instead of tucked inside one clearly-named _ingest_tool folder.
    # Never touches actual archive content (category folders) or
    # quarantine - only this tool's own bookkeeping - and never deletes
    # anything it hasn't successfully relocated first: a partial or
    # failed migration just leaves some old files in their old place
    # (harmless clutter), never data loss. Safe to call on every run;
    # once migrated, there's nothing left to do and it's a fast no-op.
    #
    # Deliberately uses Write-Host rather than Write-IngestLog here -
    # this can run before the log file for this session is set up, and
    # a tidy-up notice isn't worth adding that ordering dependency.
    param([string]$DestRoot)

    $newToolDir = Join-Path $DestRoot "_ingest_tool"
    $oldManifest = Join-Path $DestRoot ".ingest_manifest.csv"
    $newManifest = Join-Path $newToolDir "manifest.csv"
    $oldIndex = Join-Path $DestRoot ".ingest_manifest_index"
    $newIndex = Join-Path $newToolDir "manifest_index"
    $oldSqlite = Join-Path $DestRoot ".ingest_manifest.sqlite"
    $newSqlite = Join-Path $newToolDir "manifest_cache.sqlite"
    $oldLogs = Join-Path $DestRoot "_logs"
    $newLogs = Join-Path $newToolDir "logs"

    $hasOldManifest = Test-Path -LiteralPath $oldManifest
    $hasOldLogs = Test-Path -LiteralPath $oldLogs
    if (-not $hasOldManifest -and -not $hasOldLogs) { return }  # nothing old to migrate

    if (-not (Test-Path -LiteralPath $newToolDir)) {
        try { New-Item -ItemType Directory -Path $newToolDir -Force | Out-Null }
        catch { return }  # can't create it - just proceed on the old layout for this run
    }

    if ($hasOldManifest -and -not (Test-Path -LiteralPath $newManifest)) {
        try {
            Write-Host "Tidying up this archive's bookkeeping into one '_ingest_tool' folder (one-time - your actual files aren't touched)..."
            Move-Item -LiteralPath $oldManifest -Destination $newManifest -ErrorAction Stop
        }
        catch { Write-Host "  (Couldn't move the old manifest yet - still using it from its old location this run.)" -ForegroundColor Yellow }
    }
    # The lookup index and Python's SQLite cache are both disposable -
    # if either can't be moved right now, it's simplest to just leave it
    # behind; it costs nothing but a one-time rebuild at the new location.
    if ((Test-Path -LiteralPath $oldIndex) -and -not (Test-Path -LiteralPath $newIndex)) {
        try { Move-Item -LiteralPath $oldIndex -Destination $newIndex -ErrorAction Stop } catch { }
    }
    if ((Test-Path -LiteralPath $oldSqlite) -and -not (Test-Path -LiteralPath $newSqlite)) {
        try { Move-Item -LiteralPath $oldSqlite -Destination $newSqlite -ErrorAction Stop } catch { }
    }
    if ($hasOldLogs) {
        # Move file-by-file (not the whole folder at once) so this still
        # works even if _ingest_tool\logs already exists from an earlier
        # partial migration or a fresh run that started before this one.
        try {
            if (-not (Test-Path -LiteralPath $newLogs)) { New-Item -ItemType Directory -Path $newLogs -Force | Out-Null }
            Get-ChildItem -LiteralPath $oldLogs -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $target = Join-Path $newLogs $_.Name
                if (-not (Test-Path -LiteralPath $target)) {
                    Move-Item -LiteralPath $_.FullName -Destination $target -ErrorAction SilentlyContinue
                }
            }
            if (@(Get-ChildItem -LiteralPath $oldLogs -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $oldLogs -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }  # old logs are historical only; leaving some behind is harmless
    }
}

function Set-IngestToolReadme {
    # Drops a short, plain-language note inside _ingest_tool the first
    # time that folder is created, for the benefit of someone who has
    # never seen this script and stumbles into it later (browsing the
    # archive, migrating it to new storage, etc.). Never overwrites an
    # existing copy, so it's harmless to call this on every run.
    param([string]$ToolDir)
    $readmePath = Join-Path $ToolDir "README.txt"
    if (Test-Path -LiteralPath $readmePath) { return }
    $text = @"
This folder belongs to the Media Ingest Tool - not to the archive's
actual content.

It keeps track of what has already been imported (so re-running an
import never duplicates anything) and holds run logs for reference.

You don't need to open anything in here, and nothing in the rest of
this archive depends on you understanding it. A few things worth
knowing anyway:

  - Safe to leave in place. When you copy, move, or back up this
    whole archive folder, bring this folder along with it (it is a
    normal, visible folder - not hidden - specifically so ordinary
    copy tools don't skip it by accident).
  - Safe to delete, if you really need to. The tool will simply
    rebuild it from scratch the next time you import - it just means
    files already in the archive might briefly look "new" again to
    the tool until it re-scans and recognizes them (nothing gets
    deleted or duplicated in your actual archive from this).
  - manifest.csv is the important file in here: a plain-text record
    of every file ever imported. manifest_index/ and
    manifest_cache.sqlite are just speed optimizations built from it -
    safe to delete on their own any time, at no cost beyond a slightly
    slower next run while they rebuild.
  - logs/ holds a record of each past run, in case something needs
    checking later.
"@
    try { Set-Content -LiteralPath $readmePath -Value $text -Encoding UTF8 } catch { }
}

function Sync-ManifestIndex {
    # Brings the shard files up to date with whatever has been appended
    # to the canonical CSV since this index was last synced (by this
    # tool - possibly a different user or machine - the Python tool
    # never touches this index). Cost is proportional to how much is
    # NEW, not to the archive's total size.
    #
    # Guarded by a short-lived exclusive lock file so that several users
    # syncing at the same moment don't each independently fold the same
    # delta into the shards. Tested directly: without this lock, 4
    # concurrent runs each read the same "what's new" tail and wrote
    # their own copy of it into the shards, so the shard files ended up
    # 4x their correct size - not a correctness bug (duplicate rows in a
    # shard just overwrite the same key with the same value), but it
    # silently erodes the whole point of sharding over time, since shard
    # files never shrink back down. If the lock can't be acquired
    # quickly, this run just skips syncing and uses whatever shards are
    # already on disk - a small loss of lookup freshness, never a
    # correctness issue, since an unrecognized duplicate is still caught
    # safely by the atomic destination-claim logic during the actual copy.
    param([string]$ManifestPath, [string]$IndexDir)

    $shardsDir = Join-Path $IndexDir "shards"
    $offsetPath = Join-Path $IndexDir "offset.txt"
    $lockPath = Join-Path $IndexDir "sync.lock"

    if (-not (Test-Path -LiteralPath $shardsDir)) {
        New-Item -ItemType Directory -Path $shardsDir -Force | Out-Null
    }

    $lockStream = $null
    $lockAttempts = 0
    while ($true) {
        try {
            $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            break
        }
        catch [System.IO.IOException] {
            $lockAttempts++
            if ($lockAttempts -ge 20) { return }  # another process is syncing right now; proceed with the shards as they are
            Start-Sleep -Milliseconds 100
        }
    }

    try {
        Sync-ManifestIndexLocked -ManifestPath $ManifestPath -ShardsDir $shardsDir -OffsetPath $offsetPath
    }
    finally {
        $lockStream.Dispose()
    }
}

function Sync-ManifestIndexLocked {
    param([string]$ManifestPath, [string]$ShardsDir, [string]$OffsetPath)
    $shardsDir = $ShardsDir
    $offsetPath = $OffsetPath

    $currentLength = (Get-Item -LiteralPath $ManifestPath -Force -ErrorAction Stop).Length

    [long]$offset = 0
    if (Test-Path -LiteralPath $offsetPath) {
        $offsetText = (Get-Content -LiteralPath $offsetPath -Raw -ErrorAction SilentlyContinue)
        if (-not [long]::TryParse(($offsetText -replace '\s', ''), [ref]$offset)) { $offset = 0 }
    }

    if ($offset -gt $currentLength) {
        # The canonical CSV is shorter than what we last indexed - it was
        # replaced or hand-edited since. Our shards can no longer be
        # trusted incrementally; wipe and rebuild from byte 0.
        Get-ChildItem -LiteralPath $shardsDir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $offset = 0
    }

    if ($currentLength -eq $offset) { return }  # already fully synced

    if ($currentLength -gt 2MB -and $offset -eq 0) {
        Write-IngestLog "INFO" "Building the lookup index for this archive for the first time (this may take a moment; future runs will be fast)..." -FileOnly
    }

    $fs = [System.IO.File]::OpenRead($ManifestPath)
    try {
        [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
        # detectEncodingFromByteOrderMarks = $false: we are seeking into
        # the middle of the file (except on the very first sync), so the
        # reader must not try to interpret whatever bytes happen to be at
        # this offset as a BOM.
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $false)
        $tail = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose(); $fs.Dispose()
    }

    if ([string]::IsNullOrEmpty($tail)) { return }

    $newOffset = $offset + [System.Text.Encoding]::UTF8.GetByteCount($tail)
    $lines = $tail -split "\r\n|\n"
    if ($lines.Length -gt 0 -and $lines[-1] -eq "") { $lines = $lines[0..($lines.Length - 2)] }

    $byShard = @{}
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($offset -eq 0 -and $line -eq '"hash","original_name","source_path","dest_path","size","imported_at"') { continue }
        $fields = ConvertFrom-CsvLine $line
        if ($fields.Count -lt 1 -or [string]::IsNullOrEmpty($fields[0])) { continue }
        $prefix = Get-ManifestShardPrefix $fields[0]
        if (-not $byShard.ContainsKey($prefix)) { $byShard[$prefix] = New-Object System.Collections.Generic.List[string] }
        $byShard[$prefix].Add($line)
    }

    foreach ($prefix in $byShard.Keys) {
        $shardPath = Join-Path $shardsDir "$prefix.csv"
        # Not Add-Content - see Add-CsvRow for why (same -Encoding-on-append
        # failure mode applies here, and shard files are repeatedly appended
        # to across runs, not just created once).
        $linesToWrite = $byShard[$prefix]
        Invoke-WithIoRetry -Action {
            $fs = [System.IO.File]::Open($shardPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
            try {
                foreach ($l in $linesToWrite) { $writer.WriteLine($l) }
            }
            finally { $writer.Dispose() }
        }
    }

    Set-Content -LiteralPath $offsetPath -Value "$newOffset" -Encoding UTF8 -NoNewline
}

function Read-ManifestShard {
    param([string]$IndexDir, [string]$Prefix)
    $shardPath = Join-Path $IndexDir "shards\$Prefix.csv"
    $table = @{}
    if (Test-Path -LiteralPath $shardPath) {
        foreach ($line in [System.IO.File]::ReadLines($shardPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $fields = ConvertFrom-CsvLine $line
            if ($fields.Count -lt 4) { continue }
            $table[(Get-ManifestKey -HashValue $fields[0] -Name $fields[1])] = $fields[3]
        }
    }
    return $table
}

function Initialize-Manifest {
    param([string]$Path)

    $parentDir = Split-Path -Path $Path -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Set-IngestToolReadme -ToolDir $parentDir
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        # Create the file with its header ATOMICALLY (exclusive create -
        # fails cleanly if it doesn't win the race). Without this, two
        # processes both finding no manifest yet and both writing a
        # header produces a manifest with two header-shaped lines; the
        # second one is then misread as a bogus data row (a "file" whose
        # path is literally the word "dest_path"), which -Verify would
        # then report as a confusing false-alarm "MISSING" entry.
        # Verified directly: this exact scenario was reproduced and
        # fixed. If another process wins this race, we just fall through
        # to reading whatever it wrote below, instead of also writing a
        # second, duplicate header.
        try {
            $headerLine = (@("hash", "original_name", "source_path", "dest_path", "size", "imported_at") |
                ForEach-Object { ConvertTo-CsvField $_ }) -join ','
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $writer = $null
            try {
                $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
                $writer.WriteLine($headerLine)
                $writer.Flush()
            }
            finally {
                if ($writer) { $writer.Dispose() } else { $fs.Dispose() }
            }
        }
        catch {
            # Someone else created it first (or another transient issue) -
            # fine either way; read whatever is there now, below.
        }
    }

    $script:ManifestIndexDir = Get-ManifestIndexDir -ManifestPath $Path
    $script:ManifestShardCache = @{}  # prefix -> hashtable(key -> dest_path), loaded lazily per run

    if (Test-Path -LiteralPath $Path) {
        try {
            Sync-ManifestIndex -ManifestPath $Path -IndexDir $script:ManifestIndexDir
        }
        catch {
            # The index is a pure optimization layer - if syncing it fails
            # for any reason (permissions, disk full, odd filesystem),
            # fall back to reading it fresh per shard as needed below;
            # correctness never depends on the index being up to date,
            # only speed does.
            Write-IngestLog "WARN" "Could not update the manifest lookup index ($($_.Exception.Message)) - continuing, lookups may be slower this run." -FileOnly
        }
    }
}

function Get-ManifestEntry {
    # Returns the recorded destination path for this (hash, name), or
    # $null if it isn't a known duplicate. Loads at most one shard file
    # (a small slice of the archive's total history), cached for the
    # rest of this run.
    param([string]$HashValue, [string]$Name)
    $prefix = Get-ManifestShardPrefix $HashValue
    if (-not $script:ManifestShardCache.ContainsKey($prefix)) {
        $script:ManifestShardCache[$prefix] = Read-ManifestShard -IndexDir $script:ManifestIndexDir -Prefix $prefix
    }
    $key = Get-ManifestKey -HashValue $HashValue -Name $Name
    if ($script:ManifestShardCache[$prefix].ContainsKey($key)) { return $script:ManifestShardCache[$prefix][$key] }
    return $null
}

function Add-ManifestEntry {
    param([string]$HashValue, [string]$Name, [string]$SourcePath, [string]$DestPath, [long]$Size)
    # Update this run's in-memory shard cache immediately, so a second
    # copy of the same file later in the SAME run is still caught as a
    # duplicate without needing to re-read anything from disk. The shard
    # FILE itself is refreshed by the next run's Sync-ManifestIndex,
    # which will pick this row up from the canonical CSV's growth - kept
    # this way (one place that ever writes shard files) so shards never
    # accumulate duplicate copies of the same row.
    $prefix = Get-ManifestShardPrefix $HashValue
    if (-not $script:ManifestShardCache.ContainsKey($prefix)) { $script:ManifestShardCache[$prefix] = @{} }
    $script:ManifestShardCache[$prefix][(Get-ManifestKey -HashValue $HashValue -Name $Name)] = $DestPath
    Add-CsvRow -Path $script:ManifestPath -Fields @($HashValue, $Name, $SourcePath, $DestPath, "$Size", (Get-Date).ToString("o"))
}

# ===========================================================================
# Filesystem helpers
# ===========================================================================

function Get-UniquePath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir  = Split-Path $Path -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [System.IO.Path]::GetExtension($Path)
    $n = 1
    while ($true) {
        $candidate = Join-Path $dir "$name ($n)$ext"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $n++
    }
}

function Test-ShouldIgnore {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Name -like $p.Trim()) { return $true }
    }
    return $false
}

function Copy-AndVerifyAtomic {
    # Atomically claims a destination filename and copies verified content
    # into it. This matters when more than one person/process might be
    # importing into the same destination at the same time: a plain
    # "check if the name is free, then copy" (as a Test-Path check
    # followed by a separate Copy-Item -Force) has a race window between
    # those two steps - two processes can both see a name as free and
    # both proceed, and the second one to finish silently overwrites the
    # first with no error. Verified directly: running two imports at once
    # against a shared destination with colliding filenames caused real,
    # silent data loss in roughly half of repeated trials before this fix.
    #
    # Instead, the underlying create-the-file call itself is the thing
    # that succeeds or fails atomically at the filesystem level: only one
    # process can ever win a given name. The loser simply notices the name
    # is now taken and tries the next available name instead - exactly
    # the same outcome as if the two imports had happened one after the
    # other, just safe when they genuinely overlap in time.
    #
    # Returns the actual path the content was claimed under (may differ
    # from NaivePath if that name was already taken), or $null if the
    # copy didn't verify and was removed.
    param([string]$NaivePath, [string]$SrcPath, [string]$ExpectedHash, [bool]$IsDir)

    $dir  = Split-Path $NaivePath -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($NaivePath)
    $ext  = [System.IO.Path]::GetExtension($NaivePath)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $candidate = $NaivePath
    $n = 0
    while ($true) {
        $claimed = $false
        if ($IsDir) {
            # Directories can't be created "exclusively" the way a single
            # file can, so instead: copy into a private temp name first,
            # then atomically rename it into place. A rename onto an
            # existing name fails cleanly rather than merging or
            # overwriting, giving the same atomic-claim guarantee.
            $tempDir = Join-Path $dir (".ingest_tmp_" + [System.Guid]::NewGuid().ToString("N"))
            try {
                Copy-Item -LiteralPath $SrcPath -Destination $tempDir -Recurse -Force
                [System.IO.Directory]::Move($tempDir, $candidate)
                $claimed = $true
            }
            catch {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $candidate)) { throw }  # a real error, not a name collision
            }
        }
        else {
            try {
                # The .NET call itself, not a preceding Test-Path, is what
                # decides this - overwrite:$false makes it fail rather
                # than silently replacing an existing file.
                [System.IO.File]::Copy($SrcPath, $candidate, $false)
                $claimed = $true
            }
            catch {
                if (-not (Test-Path -LiteralPath $candidate)) { throw }  # a real error, not a name collision
            }
        }

        if ($claimed) { break }
        $n++
        if ($n -gt 1000) { throw "Too many naming collisions while claiming a destination for $NaivePath" }
        $candidate = Join-Path $dir "$name ($n)$ext"
    }

    $actual = if ($IsDir) { Get-Sha256Dir $candidate } else { Get-Sha256File $candidate }
    if ($actual -ne $ExpectedHash) {
        if ($IsDir) { Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue }
        else { Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue }
        return $null
    }
    return $candidate
}

function Remove-SourceItem {
    param([string]$Path, [bool]$IsDir)
    try {
        if ($IsDir) { Remove-Item -LiteralPath $Path -Recurse -Force } else { Remove-Item -LiteralPath $Path -Force }
    }
    catch {
        Write-IngestLog "ERROR" "Could not delete source $Path after import: $($_.Exception.Message)"
    }
}

function Remove-EmptyFolders {
    # Only ever removes a folder that ends up COMPLETELY empty - no files
    # (not even ignored junk like Thumbs.db) and no subfolders. A folder
    # holding anything left behind on purpose (an ignored file, something
    # that failed to copy, an error) is never touched. The root itself
    # (RootPath) is never removed, only its descendants. Processes
    # deepest-first so an emptied child correctly allows its now-empty
    # parent to be removed in the same pass.
    param([string]$RootPath, [string[]]$ExcludePaths)

    $removed = New-Object System.Collections.Generic.List[string]
    $rootFull = (Resolve-Path -LiteralPath $RootPath).ProviderPath

    $allDirs = Get-ChildItem -LiteralPath $rootFull -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { ($_.FullName -split '[\\/]').Count } -Descending

    foreach ($dir in $allDirs) {
        if ($ExcludePaths -contains $dir.FullName) { continue }
        try {
            $hasChildren = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop).Count -gt 0
            if (-not $hasChildren) {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                $removed.Add($dir.FullName)
            }
        }
        catch {
            # Not empty, in use, or no permission - leave it alone. This is
            # a best-effort tidy-up, never worth failing the whole run over.
        }
    }
    return $removed
}

# ===========================================================================
# Core ingest logic. $Options is a plain object carrying this run's mode
# (DryRun / DeleteSource / DeleteDuplicates) - passed explicitly everywhere
# rather than read from ambient globals, so the same engine can safely be
# run twice in one process (wizard: once as a preview, once for real).
# ===========================================================================

function Invoke-IngestItem {
    param([string]$SrcPath, [string]$RelDir, [bool]$IsDir, $Options)

    $name = Split-Path $SrcPath -Leaf

    try {
        if ($IsDir) { $size = Get-DirSize $SrcPath; $hashValue = Get-Sha256Dir $SrcPath }
        else { $size = (Get-Item -LiteralPath $SrcPath -Force).Length; $hashValue = Get-Sha256File $SrcPath }
    }
    catch {
        Write-IngestLog "ERROR" "Could not read ${SrcPath}: $($_.Exception.Message)"
        Add-CsvRow -Path $script:CsvPath -Fields @((Get-Date).ToString("o"), $SrcPath, "error", "", "", "unreadable: $($_.Exception.Message)")
        $script:Stats.Errors++
        return
    }

    $existingDest = Get-ManifestEntry -HashValue $hashValue -Name $name
    if ($null -ne $existingDest) {
        Write-IngestLog "INFO" "DUPLICATE  $SrcPath  (already handled as $existingDest)" -FileOnly
        Add-CsvRow -Path $script:CsvPath -Fields @((Get-Date).ToString("o"), $SrcPath, "duplicate", $existingDest, $hashValue, "")
        $script:Stats.Duplicates++
        if ($Options.DeleteSource -and $Options.DeleteDuplicates -and -not $Options.DryRun) {
            Remove-SourceItem $SrcPath $IsDir
        }
        return
    }

    $validation = Test-MediaFileName -Name $name -Standard $script:Standard
    $errText = $validation.Errors -join "; "

    if ($validation.IsValid) {
        $folder = "_unsorted"
        if ($validation.Groups.ContainsKey('areaCategory') -and $validation.Groups['areaCategory']) {
            $folder = $validation.Groups['areaCategory']
        }
        $naivePath = Join-Path (Join-Path $script:DestResolved $folder) $name
        $action = "imported"
    }
    else {
        $qDir = if ($RelDir) { Join-Path $script:QuarantineResolved $RelDir } else { $script:QuarantineResolved }
        $naivePath = Join-Path $qDir $name
        $action = "quarantined"
        $script:QuarantineDetails.Add("$name  ->  $errText")
    }

    if ($Options.DryRun) {
        $destPath = if (Test-Path -LiteralPath $naivePath) { Get-UniquePath $naivePath } else { $naivePath }
        $suffix = if ($errText) { "  [$errText]" } else { "" }
        Write-IngestLog "INFO" "[PREVIEW] $SrcPath -> $destPath$suffix" -FileOnly
        Add-CsvRow -Path $script:CsvPath -Fields @((Get-Date).ToString("o"), $SrcPath, "preview-$action", $destPath, $hashValue, $errText)
        if ($action -eq "imported") { $script:Stats.Imported++ } else { $script:Stats.Quarantined++ }
        return
    }

    # If something is already sitting at the natural destination path,
    # check whether it is in fact this exact same, already-verified
    # content - most commonly a copy that finished on an earlier,
    # interrupted run (power loss, disconnect, closed window) before it
    # could be recorded in the manifest. If so, adopt it in place rather
    # than leaving that unrecorded file sitting there AND creating a
    # confusing, redundant "(1)" copy next to it. Only a genuine content
    # match is ever adopted this way; anything else already at that path
    # is left completely untouched, and Copy-AndVerifyAtomic below claims
    # a distinct name safely - even if another process is claiming a name
    # at this exact moment.
    $alreadyPresentVerified = $false
    if (Test-Path -LiteralPath $naivePath) {
        $existingIsDir = (Get-Item -LiteralPath $naivePath -Force).PSIsContainer
        if ($existingIsDir -eq $IsDir) {
            try {
                $existingHash = if ($IsDir) { Get-Sha256Dir $naivePath } else { Get-Sha256File $naivePath }
                if ($existingHash -eq $hashValue) { $alreadyPresentVerified = $true }
            }
            catch { }  # unreadable existing item -> fall through to the safe claim below
        }
    }

    if ($alreadyPresentVerified) {
        $destPath = $naivePath
        Write-IngestLog "INFO" "ALREADY THERE $SrcPath -> $destPath (matches exactly - likely left over from an earlier interrupted run; adopted, not re-copied)" -FileOnly
        $csvAction = "$action-already-present"
    }
    else {
        $destPath = $null
        try { $destPath = Copy-AndVerifyAtomic -NaivePath $naivePath -SrcPath $SrcPath -ExpectedHash $hashValue -IsDir $IsDir }
        catch { Write-IngestLog "ERROR" "Copy failed for $SrcPath -> ${naivePath}: $($_.Exception.Message)" }

        if (-not $destPath) {
            Write-IngestLog "ERROR" "VERIFY FAILED copying $SrcPath -> $naivePath (source left untouched)"
            Add-CsvRow -Path $script:CsvPath -Fields @((Get-Date).ToString("o"), $SrcPath, "verify-failed", $naivePath, $hashValue, "")
            $script:Stats.Errors++
            return
        }
        $csvAction = $action
    }

    # Record every successfully copied item (imported OR quarantined) in the
    # manifest, so re-running this tool never re-quarantines the same
    # invalid content again - it will be recognized as a duplicate instead.
    Add-ManifestEntry -HashValue $hashValue -Name $name -SourcePath $SrcPath -DestPath $destPath -Size $size

    if ($action -eq "imported") {
        $script:Stats.Imported++
        $script:Stats.BytesImported += $size
        if (-not $alreadyPresentVerified) { Write-IngestLog "INFO" "IMPORTED   $SrcPath -> $destPath" -FileOnly }
    }
    else {
        $script:Stats.Quarantined++
        if (-not $alreadyPresentVerified) { Write-IngestLog "WARN" "QUARANTINE $SrcPath -> $destPath  [$errText]" -FileOnly }
    }

    Add-CsvRow -Path $script:CsvPath -Fields @((Get-Date).ToString("o"), $SrcPath, $csvAction, $destPath, $hashValue, $errText)

    if ($Options.DeleteSource) { Remove-SourceItem $SrcPath $IsDir }
}

function Get-IngestItemList {
    # Walks the source tree once and returns a flat list of items still to
    # process (files, plus BagIt-style folders treated as one unit each).
    # Collecting this list upfront - rather than processing items inline
    # during the walk - is what lets the progress bar show an accurate
    # "X of Y" and percentage instead of just a moving counter.
    param([string]$CurrentDir, [string]$RelDir, [System.Collections.Generic.List[object]]$Items)

    $children = Get-ChildItem -LiteralPath $CurrentDir -Force -ErrorAction SilentlyContinue
    if (-not $children) { return }

    $dirs  = $children | Where-Object { $_.PSIsContainer }
    $files = $children | Where-Object { -not $_.PSIsContainer }

    foreach ($d in $dirs) {
        if ($d.FullName -eq $script:DestResolved -or $d.FullName -eq $script:QuarantineResolved) { continue }
        if ($script:Standard.IncludeDirs.Match($d.Name).Success) {
            $Items.Add([pscustomobject]@{ SrcPath = $d.FullName; RelDir = $RelDir; IsDir = $true })
        }
        else {
            $childRel = if ($RelDir) { Join-Path $RelDir $d.Name } else { $d.Name }
            Get-IngestItemList -CurrentDir $d.FullName -RelDir $childRel -Items $Items
        }
    }

    foreach ($f in $files) {
        if (Test-ShouldIgnore -Name $f.Name -Patterns $script:IgnoreListArr) { continue }
        $Items.Add([pscustomobject]@{ SrcPath = $f.FullName; RelDir = $RelDir; IsDir = $false })
    }
}

function Invoke-IngestRun {
    # Runs one full pass over the source tree (either a preview or a real
    # run, depending on $Options.DryRun) and returns a Stats object. Safe
    # to call twice in the same process (the wizard does exactly that).
    param($Options)

    # A short random suffix (not just the timestamp) guarantees uniqueness
    # even if two runs against the same destination start in the same
    # second - a real possibility once more than one person can be
    # importing into a shared destination at once. Without it, two such
    # runs would collide on the same log/CSV filename and interleave.
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $unique = [System.Guid]::NewGuid().ToString("N").Substring(0, 6)
    Open-IngestLogFile -Path (Join-Path $script:LogDirResolved "ingest_$ts-$unique.log")
    $script:CsvPath = Join-Path $script:LogDirResolved "ingest_$ts-$unique.csv"
    Add-CsvRow -Path $script:CsvPath -Fields @("timestamp", "source_path", "action", "dest_path", "sha256", "notes")

    Write-IngestLog "INFO" "=== Media Ingest Tool ==="
    Write-IngestLog "INFO" "Source:      $script:SourceResolved"
    Write-IngestLog "INFO" "Destination: $script:DestResolved"
    Write-IngestLog "INFO" "Quarantine:  $script:QuarantineResolved"
    $modeText = if ($Options.DryRun) { "PREVIEW (nothing will be changed)" }
                elseif ($Options.DeleteSource) { "copy + delete verified source (move)" }
                else { "copy only (source kept)" }
    if ($Options.DeleteSource -and $Options.RemoveEmptyFolders) {
        $modeText += if ($Options.DryRun) { " - a real run would also remove any folders left empty afterward" }
                      else { ", then remove any folders left empty on the source" }
    }
    Write-IngestLog "INFO" "Mode:        $modeText"

    $script:Stats = [pscustomobject]@{ Imported = 0; Duplicates = 0; Quarantined = 0; Errors = 0; BytesImported = 0; EmptyFoldersRemoved = 0 }
    $script:QuarantineDetails = New-Object System.Collections.Generic.List[string]

    $activity = if ($Options.DryRun) { "Checking files (preview)" } else { "Importing files" }
    $items = New-Object System.Collections.Generic.List[object]
    Write-Progress -Activity $activity -Status "Scanning..." -PercentComplete 0
    Write-IngestLog "INFO" "Scanning the source for files to process (this can take a moment on a very large source)..."
    Get-IngestItemList -CurrentDir $script:SourceResolved -RelDir "" -Items $items
    $total = $items.Count

    $i = 0
    foreach ($item in $items) {
        $i++
        $percent = if ($total -gt 0) { [int](($i / $total) * 100) } else { 100 }
        Write-Progress -Activity $activity -Status "$i of $total" -PercentComplete $percent -CurrentOperation (Split-Path $item.SrcPath -Leaf)
        Invoke-IngestItem -SrcPath $item.SrcPath -RelDir $item.RelDir -IsDir $item.IsDir -Options $Options
    }
    Write-Progress -Activity $activity -Completed

    $emptyFolders = @()
    if ($Options.DeleteSource -and $Options.RemoveEmptyFolders -and -not $Options.DryRun) {
        $excludePaths = @($script:DestResolved, $script:QuarantineResolved)
        $emptyFolders = Remove-EmptyFolders -RootPath $script:SourceResolved -ExcludePaths $excludePaths
        $script:Stats.EmptyFoldersRemoved = $emptyFolders.Count
        foreach ($f in $emptyFolders) { Write-IngestLog "INFO" "REMOVED EMPTY FOLDER  $f" -FileOnly }
    }

    Write-IngestLog "INFO" ("Imported: {0} | Duplicates skipped: {1} | Quarantined: {2} | Errors: {3} | Data: {4:N1} MiB | Empty folders removed: {5}" -f `
        $script:Stats.Imported, $script:Stats.Duplicates, $script:Stats.Quarantined, $script:Stats.Errors, ($script:Stats.BytesImported / 1MB), $script:Stats.EmptyFoldersRemoved)
    Write-IngestLog "INFO" "Log:  $script:LogFile"
    Write-IngestLog "INFO" "CSV:  $script:CsvPath"

    return [pscustomobject]@{
        Stats             = $script:Stats
        QuarantineDetails = $script:QuarantineDetails
        LogFile           = $script:LogFile
        CsvPath           = $script:CsvPath
    }
}

# ===========================================================================
# Archive verification (-Verify): read-only integrity and completeness
# check against the manifest. Answers two separate questions:
#   1. Is everything the manifest says should be here actually here,
#      unmodified? (checked by re-hashing every tracked file)
#   2. Is there anything present in the archive that the manifest doesn't
#      know about - e.g. a file added manually, outside this tool?
# This never copies, moves, or deletes anything.
# ===========================================================================

function Invoke-ArchiveVerification {
    param([string]$DestRoot)

    Write-Host ""
    Write-Host "=================================================================="
    Write-Host " Verifying archive: $DestRoot"
    Write-Host "=================================================================="
    Write-Host "This only reads and checks - nothing is copied, moved, or deleted."
    Write-Host ""

    Move-LegacyArchiveLayout -DestRoot $DestRoot
    $manifestPath = Join-Path $DestRoot "_ingest_tool\manifest.csv"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Host "No manifest found at: $manifestPath" -ForegroundColor Yellow
        Write-Host "There's nothing recorded to check the archive's contents against." -ForegroundColor Yellow
        Write-Host "If this archive was built with this tool before, the manifest may" -ForegroundColor Yellow
        Write-Host "simply have been lost - re-running a normal import against the" -ForegroundColor Yellow
        Write-Host "original source (if you still have it) will safely rebuild it," -ForegroundColor Yellow
        Write-Host "recognizing everything already here without duplicating anything." -ForegroundColor Yellow
        return
    }

    $rows = @(Import-Csv -LiteralPath $manifestPath)
    Write-Host "Manifest entries to check: $($rows.Count)"
    Write-Host ""

    $logDir = Join-Path $DestRoot "_ingest_tool\logs"
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $reportPath = Join-Path $logDir ("verify_" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 6) + ".csv")
    Add-CsvRow -Path $reportPath -Fields @("category", "path", "recorded_hash", "notes")

    $okCount = 0
    $missing = New-Object System.Collections.Generic.List[string]
    $corrupted = New-Object System.Collections.Generic.List[string]
    $trackedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($row in $rows) {
        $p = $row.dest_path
        if ($p) { [void]$trackedPaths.Add($p) }

        if (-not (Test-Path -LiteralPath $p)) {
            $missing.Add($p)
            Add-CsvRow -Path $reportPath -Fields @("missing", $p, $row.hash, "listed in the manifest but not found on disk")
            continue
        }
        $isDirItem = (Get-Item -LiteralPath $p -Force).PSIsContainer
        try {
            $liveHash = if ($isDirItem) { Get-Sha256Dir $p } else { Get-Sha256File $p }
        }
        catch {
            $corrupted.Add($p)
            Add-CsvRow -Path $reportPath -Fields @("unreadable", $p, $row.hash, $_.Exception.Message)
            continue
        }
        if ($liveHash -ne $row.hash) {
            $corrupted.Add($p)
            Add-CsvRow -Path $reportPath -Fields @("changed", $p, $row.hash, "content on disk no longer matches the recorded hash")
        }
        else {
            $okCount++
        }
    }

    Write-Host "Checked $($rows.Count) tracked item(s):"
    Write-Host "  $okCount OK - content matches exactly what was recorded" -ForegroundColor Green
    if ($missing.Count -gt 0) {
        Write-Host "  $($missing.Count) MISSING - listed in the manifest but not found on disk:" -ForegroundColor Red
        foreach ($m in $missing) { Write-Host "    - $m" }
    }
    if ($corrupted.Count -gt 0) {
        Write-Host "  $($corrupted.Count) CHANGED - content no longer matches what was recorded:" -ForegroundColor Red
        foreach ($c in $corrupted) { Write-Host "    - $c" }
    }

    Write-Host ""
    Write-Host "Scanning for files present in the archive that the manifest doesn't"
    Write-Host "know about (for example, something added manually)..."

    $standard = $null
    try { $standard = Get-Standard -Url $RegexUrl -CachePath (Join-Path $CacheDir "medienstandard.json") -Force $false }
    catch { Write-Host "  (Could not load the naming standard to check untracked filenames - skipping that detail.)" -ForegroundColor Yellow }

    $ingestToolDirNormalized = (Join-Path $DestRoot "_ingest_tool")
    $orphans = New-Object System.Collections.Generic.List[string]

    Get-ChildItem -LiteralPath $DestRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.FullName.StartsWith($ingestToolDirNormalized, [System.StringComparison]::OrdinalIgnoreCase)) { return }
        if ($_.Name -eq ".ingest_manifest.csv" -or $_.Name -eq ".ingest_manifest.sqlite") { return }  # leftovers from an archive not yet tidied up
        if (-not $trackedPaths.Contains($_.FullName)) {
            $note = ""
            if ($standard) {
                $v = Test-MediaFileName -Name $_.Name -Standard $standard
                $note = if ($v.IsValid) { "name matches the standard" } else { "name would NOT pass validation: $($v.Errors -join '; ')" }
            }
            $orphans.Add($_.FullName)
            Add-CsvRow -Path $reportPath -Fields @("untracked", $_.FullName, "", $note)
        }
    }

    if ($orphans.Count -gt 0) {
        Write-Host "  $($orphans.Count) untracked file(s) found:" -ForegroundColor Yellow
        foreach ($o in $orphans) { Write-Host "    - $o" }
        Write-Host "  These aren't necessarily a problem - they just didn't come through" -ForegroundColor Yellow
        Write-Host "  this tool, so their name/content was never checked or recorded." -ForegroundColor Yellow
    }
    else {
        Write-Host "  None found - every file in the archive is accounted for." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Full report: $reportPath"
    Write-Host "=================================================================="
}

# ===========================================================================
# Interactive wizard - plain questions, sensible defaults, always previews
# ===========================================================================
#
# Settings live in a plain-text file next to the script (or, if that's not
# writable, next to wherever you launched it from) - not hidden away in a
# profile folder - so they're easy to find and edit directly for the
# occasional change, without going through the questions again.

function Get-DefaultConfigPath {
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return Join-Path $baseDir "ingest-settings.txt"
}

function Read-IngestConfig {
    # Simple "Key = Value" text format with "#" comments - easy for a
    # non-technical person to open and edit directly.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $values = @{}
        foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
            $idx = $trimmed.IndexOf('=')
            if ($idx -lt 1) { continue }
            $key = $trimmed.Substring(0, $idx).Trim()
            $val = $trimmed.Substring($idx + 1).Trim()
            $values[$key] = $val
        }
        return [pscustomobject]@{
            Source     = $values['Source']
            Dest       = $values['Dest']
            Move       = ($values.ContainsKey('Mode') -and $values['Mode'].Trim().ToLower() -eq 'move')
            Quarantine = $values['Quarantine']
        }
    }
    catch { return $null }
}

function Write-IngestConfig {
    param([string]$Path, [string]$SourcePath, [string]$DestPath, [bool]$Move, [string]$QuarantinePath = "")
    $modeText = if ($Move) { "Move" } else { "Copy" }
    $lines = @(
        "# Media Ingest Tool - Configuration"
        "#"
        "# Edit the values below, save this file, and run the tool again."
        "# Lines starting with # are ignored. These settings are used"
        "# automatically next time - you only need to change them when"
        "# something actually changes (a different source, a different"
        "# destination folder, and so on)."
        ""
        "# Where your files come from:"
        "Source = $SourcePath"
        ""
        "# Where they should go:"
        "Dest = $DestPath"
        ""
        "# Copy (keep the originals at the source too) or Move (delete from"
        "# the source once safely copied and verified)? Type Copy or Move:"
        "Mode = $modeText"
        ""
        "# Advanced (optional). Where files with an invalid name are set"
        "# aside for you to review. Leave blank to use the default shown"
        "# below - it lives at the destination deliberately, so that even in"
        "# Move mode, invalid files still get a safe, verified copy"
        "# somewhere before anything is ever removed from the source."
        "# Default if left blank: $DestPath\_quarantine"
        "Quarantine = $QuarantinePath"
    )
    try {
        Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
        return $true
    }
    catch { return $false }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $resp = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($resp)) { return $DefaultYes }
        $resp = $resp.Trim().ToLower()
        if ($resp -eq 'y' -or $resp -eq 'yes') { return $true }
        if ($resp -eq 'n' -or $resp -eq 'no') { return $false }
        Write-Host "  Please answer y or n." -ForegroundColor Yellow
    }
}

function Read-FolderPath {
    param([string]$Question, [string]$Remembered, [bool]$MustExist)
    Write-Host ""
    Write-Host $Question
    Write-Host "  Tip: you can drag the folder from File Explorer and drop it into this window, then press Enter."
    while ($true) {
        $promptText = if ($Remembered) { "  Folder (Enter to reuse: $Remembered)" } else { "  Folder" }
        $resp = Read-Host $promptText
        if ([string]::IsNullOrWhiteSpace($resp)) {
            if ($Remembered) { $resp = $Remembered } else { Write-Host "  Please enter a folder path." -ForegroundColor Yellow; continue }
        }
        $resp = $resp.Trim().Trim("`"").Trim("'").TrimEnd()
        if ($MustExist) {
            if (-not (Test-Path -LiteralPath $resp -PathType Container)) {
                Write-Host "  Can't find that folder: $resp" -ForegroundColor Yellow
                continue
            }
            return (Resolve-Path -LiteralPath $resp).ProviderPath
        }
        else {
            if (-not (Test-Path -LiteralPath $resp)) {
                $create = Read-YesNo "  That folder doesn't exist yet. Create it?" $true
                if (-not $create) { continue }
                try { New-Item -ItemType Directory -Path $resp -Force | Out-Null }
                catch { Write-Host "  Could not create that folder: $($_.Exception.Message)" -ForegroundColor Yellow; continue }
            }
            return (Resolve-Path -LiteralPath $resp).ProviderPath
        }
    }
}

function Write-QuarantineDetails {
    # Caps how many individual reasons are printed to the console so a
    # large batch of invalid files doesn't flood the screen; the full,
    # uncapped list always lives in the CSV report regardless.
    param([System.Collections.Generic.List[string]]$Details, [int]$MaxShown = 15)
    if ($Details.Count -eq 0) { return }
    Write-Host ""
    Write-Host "  Files that would be set aside, and why:"
    $shown = [Math]::Min($Details.Count, $MaxShown)
    for ($i = 0; $i -lt $shown; $i++) { Write-Host "   - $($Details[$i])" }
    if ($Details.Count -gt $MaxShown) {
        Write-Host "   ... and $($Details.Count - $MaxShown) more - see the full report for the complete list."
    }
}

function Start-Wizard {
    Write-Host ""
    Write-Host "=================================================================="
    Write-Host " Media Ingest Tool"
    Write-Host "=================================================================="
    Write-Host "This copies files from your source into a structured archive at"
    Write-Host "your destination, checking every filename against your naming"
    Write-Host "standard on the way. Files with valid names are sorted into"
    Write-Host "folders automatically; anything with an invalid name is set"
    Write-Host "aside for you to look at - nothing is ever silently dropped."
    Write-Host ""

    $configPath = Get-DefaultConfigPath
    $config = Read-IngestConfig -Path $configPath

    $sourcePath = $null
    $destPath = $null
    $moveChoice = $false
    $quarantineOverride = ""
    $useConfig = $false

    if ($config -and $config.Source -and $config.Dest) {
        $sourceOk = Test-Path -LiteralPath $config.Source -PathType Container
        Write-Host "Found saved settings in: $configPath"
        Write-Host "  Source: $($config.Source)$(if (-not $sourceOk) { '   <- not available right now' })"
        Write-Host "  Dest:   $($config.Dest)"
        Write-Host "  Mode:   $(if ($config.Move) { 'Move' } else { 'Copy' })"
        if ($config.Quarantine) { Write-Host "  Quarantine: $($config.Quarantine)" }
        Write-Host ""
        if ($sourceOk) {
            $useConfig = Read-YesNo "Use these settings?" $true
        }
        else {
            Write-Host "The saved source folder isn't available right now - it may be" -ForegroundColor Yellow
            Write-Host "disconnected, unmounted, or have moved since it was saved." -ForegroundColor Yellow
        }
    }

    if ($useConfig) {
        $sourcePath = (Resolve-Path -LiteralPath $config.Source).ProviderPath
        $destOk = $true
        if (-not (Test-Path -LiteralPath $config.Dest)) {
            try { New-Item -ItemType Directory -Path $config.Dest -Force -ErrorAction Stop | Out-Null }
            catch {
                Write-Host "  Could not reach or create the saved destination: $($config.Dest)" -ForegroundColor Yellow
                Write-Host "  ($($_.Exception.Message))" -ForegroundColor Yellow
                $destOk = $false
            }
        }
        if ($destOk) {
            $destPath = (Resolve-Path -LiteralPath $config.Dest).ProviderPath
            $moveChoice = $config.Move
            $quarantineOverride = $config.Quarantine
        }
        else {
            $useConfig = $false
        }
    }

    if (-not $useConfig) {
        $sourcePath = Read-FolderPath -Question "1) Where are your files coming from?" -Remembered $config.Source -MustExist $true
        $destPath   = Read-FolderPath -Question "2) Where should they go?"  -Remembered $config.Dest   -MustExist $false
        $quarantineOverride = $config.Quarantine

        Write-Host ""
        Write-Host "3) Once a file has been safely copied and double-checked, should the"
        Write-Host "   original also be removed from the source?"
        Write-Host "     [1] No, keep it at the source too (safest - default)"
        Write-Host "     [2] Yes, move it - also cleans up any folders left empty"
        Write-Host "         at the source afterward, to actually free up space"
        $defaultChoice = if ($config.Move) { "2" } else { "1" }
        $moveChoiceAnswered = $false
        while (-not $moveChoiceAnswered) {
            $resp = Read-Host "   Choice (1 or 2, Enter for $defaultChoice)"
            if ([string]::IsNullOrWhiteSpace($resp)) { $resp = $defaultChoice }
            if ($resp -eq '1') { $moveChoice = $false; $moveChoiceAnswered = $true }
            elseif ($resp -eq '2') { $moveChoice = $true; $moveChoiceAnswered = $true }
            else { Write-Host "   Please type 1 or 2." -ForegroundColor Yellow }
        }
    }

    $saved = Write-IngestConfig -Path $configPath -SourcePath $sourcePath -DestPath $destPath -Move $moveChoice -QuarantinePath $quarantineOverride
    Write-Host ""
    if ($saved) {
        Write-Host "(Settings saved to $configPath - edit that file directly any time to change them.)"
    }

    $script:SourceResolved = $sourcePath
    $script:DestResolved = $destPath
    if (-not (Test-Path -LiteralPath $script:DestResolved)) { New-Item -ItemType Directory -Path $script:DestResolved -Force | Out-Null }
    Move-LegacyArchiveLayout -DestRoot $script:DestResolved
    if ($quarantineOverride) {
        if (-not (Test-Path -LiteralPath $quarantineOverride)) { New-Item -ItemType Directory -Path $quarantineOverride -Force | Out-Null }
        $script:QuarantineResolved = (Resolve-Path -LiteralPath $quarantineOverride).ProviderPath
    }
    else {
        $script:QuarantineResolved = Join-Path $script:DestResolved "_quarantine"
        if (-not (Test-Path -LiteralPath $script:QuarantineResolved)) { New-Item -ItemType Directory -Path $script:QuarantineResolved -Force | Out-Null }
    }
    $script:LogDirResolved = Join-Path $script:DestResolved "_ingest_tool\logs"
    if (-not (Test-Path -LiteralPath $script:LogDirResolved)) { New-Item -ItemType Directory -Path $script:LogDirResolved -Force | Out-Null }
    Set-IngestToolReadme -ToolDir (Join-Path $script:DestResolved "_ingest_tool")
    $script:IgnoreListArr = $IgnorePatterns -split ','

    # A throwaway log file just so Write-IngestLog has somewhere to write
    # while the standard loads; Invoke-IngestRun creates the real per-run
    # log/CSV files afterwards.
    Open-IngestLogFile -Path (Join-Path $script:LogDirResolved ("ingest_startup-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 6) + ".log"))

    Write-Host ""
    Write-Host "Loading your naming standard and checking for anything already imported..."
    $script:Standard = Get-Standard -Url $RegexUrl -CachePath (Join-Path $CacheDir "medienstandard.json") -Force $RefreshStandard.IsPresent
    $script:ManifestPath = Join-Path $script:DestResolved "_ingest_tool\manifest.csv"
    Initialize-Manifest -Path $script:ManifestPath

    Write-Host ""
    Write-Host "Checking your files now - this is just a preview, nothing will change yet..."
    Write-Host ""
    $previewOptions = [pscustomobject]@{ DryRun = $true; DeleteSource = $moveChoice; DeleteDuplicates = $moveChoice; RemoveEmptyFolders = $moveChoice }
    $preview = Invoke-IngestRun -Options $previewOptions

    Write-Host ""
    Write-Host "------------------------------------------------------------------"
    Write-Host "Preview complete:"
    Write-Host "  $($preview.Stats.Imported) file(s) would be imported"
    Write-Host "  $($preview.Stats.Quarantined) file(s) would be set aside (invalid names)"
    Write-Host "  $($preview.Stats.Duplicates) file(s) are already in the archive (would be skipped)"
    if ($preview.Stats.Errors -gt 0) { Write-Host "  $($preview.Stats.Errors) file(s) could not even be read - see the log" -ForegroundColor Yellow }
    Write-QuarantineDetails -Details $preview.QuarantineDetails
    Write-Host "------------------------------------------------------------------"

    if ($preview.Stats.Imported -eq 0 -and $preview.Stats.Quarantined -eq 0) {
        Write-Host ""
        Write-Host "Nothing new to do - every file is already in the archive." -ForegroundColor Green
        return
    }

    Write-Host ""
    $goAhead = Read-YesNo "Proceed with the real import now?" $false
    if (-not $goAhead) {
        Write-Host "Cancelled. Nothing was changed."
        return
    }

    Write-Host ""
    Write-Host "Importing for real now..."
    Write-Host ""
    # Re-read the manifest fresh right before the real run: if someone
    # else has been importing into this same destination while this
    # preview was on screen and being decided on, this picks up their
    # changes rather than working from a snapshot that's now stale.
    Initialize-Manifest -Path $script:ManifestPath
    $realOptions = [pscustomobject]@{ DryRun = $false; DeleteSource = $moveChoice; DeleteDuplicates = $moveChoice; RemoveEmptyFolders = $moveChoice }
    $real = Invoke-IngestRun -Options $realOptions

    Write-Host ""
    Write-Host "------------------------------------------------------------------"
    Write-Host "Done!" -ForegroundColor Green
    Write-Host "  $($real.Stats.Imported) file(s) imported into: $script:DestResolved"
    Write-Host "  $($real.Stats.Quarantined) file(s) set aside into: $script:QuarantineResolved"
    Write-Host "  $($real.Stats.Duplicates) duplicate(s) skipped"
    if ($real.Stats.EmptyFoldersRemoved -gt 0) {
        Write-Host "  $($real.Stats.EmptyFoldersRemoved) empty folder(s) removed from the source"
    }
    if ($real.Stats.Errors -gt 0) { Write-Host "  $($real.Stats.Errors) error(s) - see the log for details" -ForegroundColor Yellow }
    Write-Host "  Full report: $($real.CsvPath)"
    Write-Host "------------------------------------------------------------------"
}

# ===========================================================================
# Entry point: -Verify -> read-only archive check (needs -Dest only).
# Explicit -Source/-Dest -> classic single-pass CLI behaviour for power
# users and scripts. Neither given -> interactive wizard.
# ===========================================================================

if ($Verify) {
    if (-not $Dest) {
        Write-Error "-Verify requires -Dest (the archive to check)."
        exit 1
    }
    if (-not (Test-Path -LiteralPath $Dest -PathType Container)) {
        Write-Error "Destination not found: $Dest"
        exit 1
    }
    $destResolvedForVerify = (Resolve-Path -LiteralPath $Dest).ProviderPath
    Move-LegacyArchiveLayout -DestRoot $destResolvedForVerify
    $verifyLogDir = Join-Path $destResolvedForVerify "_ingest_tool\logs"
    if (-not (Test-Path -LiteralPath $verifyLogDir)) { New-Item -ItemType Directory -Path $verifyLogDir -Force | Out-Null }
    # A throwaway log file just so Write-IngestLog (used while the naming
    # standard loads) has somewhere to write.
    Open-IngestLogFile -Path (Join-Path $verifyLogDir "verify_startup.log")
    Invoke-ArchiveVerification -DestRoot $destResolvedForVerify
    Close-IngestLogFile
}
elseif ($PSBoundParameters.ContainsKey('Source') -or $PSBoundParameters.ContainsKey('Dest')) {

    if (-not $Source -or -not $Dest) {
        Write-Error "Both -Source and -Dest are required when running non-interactively."
        exit 1
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Error "Source directory not found: $Source"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $script:SourceResolved = (Resolve-Path -LiteralPath $Source).ProviderPath
    $script:DestResolved = (Resolve-Path -LiteralPath $Dest).ProviderPath
    Move-LegacyArchiveLayout -DestRoot $script:DestResolved

    if (-not $Quarantine) { $Quarantine = Join-Path $script:DestResolved "_quarantine" }
    if (-not (Test-Path -LiteralPath $Quarantine)) { New-Item -ItemType Directory -Path $Quarantine -Force | Out-Null }
    $script:QuarantineResolved = (Resolve-Path -LiteralPath $Quarantine).ProviderPath

    if (-not $LogDir) { $LogDir = Join-Path $script:DestResolved "_ingest_tool\logs" }
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Set-IngestToolReadme -ToolDir (Join-Path $script:DestResolved "_ingest_tool")
    $script:LogDirResolved = (Resolve-Path -LiteralPath $LogDir).ProviderPath
    $script:IgnoreListArr = $IgnorePatterns -split ','

    # A first, throwaway log file just so Write-IngestLog has somewhere to
    # write while the standard loads; Invoke-IngestRun creates the real one.
    Open-IngestLogFile -Path (Join-Path $script:LogDirResolved ("ingest_startup-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 6) + ".log"))

    try {
        $script:Standard = Get-Standard -Url $RegexUrl -CachePath (Join-Path $CacheDir "medienstandard.json") -Force $RefreshStandard.IsPresent
    }
    catch {
        Write-IngestLog "ERROR" $_.Exception.Message
        exit 2
    }

    $script:ManifestPath = Join-Path $script:DestResolved "_ingest_tool\manifest.csv"
    Initialize-Manifest -Path $script:ManifestPath

    $options = [pscustomobject]@{
        DryRun              = $DryRun.IsPresent
        DeleteSource        = $DeleteSource.IsPresent
        DeleteDuplicates    = $DeleteDuplicates.IsPresent
        RemoveEmptyFolders  = $RemoveEmptyFolders.IsPresent
    }
    if ($RemoveEmptyFolders.IsPresent -and -not $DeleteSource.IsPresent) {
        Write-IngestLog "INFO" "-RemoveEmptyFolders has no effect without -DeleteSource (nothing is ever deleted from the source in copy-only mode, so no folder can become empty as a result)."
    }
    [void](Invoke-IngestRun -Options $options)
    Close-IngestLogFile
}
else {
    Start-Wizard
    Close-IngestLogFile
    Write-Host ""
    Read-Host "Press Enter to close this window"
}
