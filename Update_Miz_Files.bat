@echo off
rem ===========================================================================
rem  Fix-RequiredModules.bat
rem
rem  Does two independent jobs to every .miz found under this file's folder
rem  (recursively), in a single rewrite of each archive:
rem
rem  1. requiredModules  - clears the ["requiredModules"] table in the archive's
rem     "mission" entry, so DCS clients are not blocked from joining for want of
rem     a module they do not own. Missions whose FILENAME contains WWII or WW2
rem     instead get:
rem         ["requiredModules"] = { ["WWII Armour and Technics"] = "..." }
rem
rem  2. customizations   - replaces the compiled customizations bundle inside
rem     l10n\DEFAULT with the current one from the repo beside this script:
rem         normal missions   l10n\DEFAULT\customizations.lua
rem         WWII missions     l10n\DEFAULT\ww2_customizations.lua
rem     Only that one .lua entry's bytes are swapped. The "mission" entry is not
rem     touched by this job, and does not need to be: "mission" refers to the
rem     script by resource key (ResKey_Action_nnn), and l10n\DEFAULT\mapResource
rem     maps that key to the file NAME. Same name in, same name out, so both
rem     stay valid.
rem
rem     The bundle is only ever REPLACED, never added. A .miz with no such entry
rem     is reported and left alone - dropping a new file into the archive would
rem     leave it with no resource key and no trigger, so DCS would never load it
rem     and the mission would silently run without the customizations.
rem
rem     This script NEVER builds. It ships the bundle exactly as it sits on
rem     disk right now, byte for byte, whatever that happens to be - including
rem     a hand-edited or half-experimented-on one. Compiling is yours to do,
rem     when you decide to, and nothing here will do it behind your back.
rem
rem  The .miz is edited as a zip in place - never renamed to .zip, never
rem  unpacked to a folder. Only the entries being changed are rewritten; every
rem  other resource is copied across as-is.
rem
rem  The DCS Mission Editor rebuilds requiredModules from the units in the
rem  mission every time you save, so re-run this after any round of edits.
rem  It is safe to run repeatedly - missions already correct are left alone.
rem
rem  Usage:
rem      Fix-RequiredModules.bat                       both jobs, keep backups
rem      Fix-RequiredModules.bat --dry-run             report only, change nothing
rem      Fix-RequiredModules.bat --no-backup           fix without making backups
rem      Fix-RequiredModules.bat --no-customizations   requiredModules only
rem      Fix-RequiredModules.bat --no-modules          customizations only
rem      Fix-RequiredModules.bat --src "D:\repo"       take bundles from elsewhere
rem      Fix-RequiredModules.bat "D:\some\dir"         scan a different folder
rem ===========================================================================

setlocal
set "MIZ_SELF=%~f0"
set "MIZ_ARGS=%*"

set "PSEXE=powershell"
where pwsh >nul 2>&1 && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:MIZ_SELF); Invoke-Expression $c.Substring($c.LastIndexOf('<##PS##>')+8)"

set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%

<##PS##>

$ErrorActionPreference = 'Stop'
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }

# ---------------------------------------------------------------- arguments --
$dryRun    = $false
$noBackup  = $false
$doModules = $true
$doCustom  = $true

$scriptDir = Split-Path -Parent $env:MIZ_SELF
$root      = $scriptDir

# Bundles live in the repo checked out beside this script. Anchored to the
# script rather than to $root, so that pointing the scan at some other folder
# of .miz files still takes its sources from here.
$srcDir = Join-Path $scriptDir 'custom_leka_foothold'

$rest = [string]$env:MIZ_ARGS
if ($rest -match '(?i)(^|\s)(--?|/)dry-run(\s|$)')          { $dryRun    = $true;  $rest = $rest -replace '(?i)(--?|/)dry-run','' }
if ($rest -match '(?i)(^|\s)(--?|/)no-backup(\s|$)')        { $noBackup  = $true;  $rest = $rest -replace '(?i)(--?|/)no-backup','' }
if ($rest -match '(?i)(^|\s)(--?|/)no-customizations(\s|$)'){ $doCustom  = $false; $rest = $rest -replace '(?i)(--?|/)no-customizations','' }
if ($rest -match '(?i)(^|\s)(--?|/)no-modules(\s|$)')       { $doModules = $false; $rest = $rest -replace '(?i)(--?|/)no-modules','' }

if ($rest -match '(?i)(^|\s)(--?|/)src[=\s]+(?:"([^"]+)"|(\S+))') {
    $srcDir = if ($Matches[3]) { $Matches[3] } else { $Matches[4] }
    $rest   = $rest -replace '(?i)(--?|/)src[=\s]+(?:"[^"]+"|\S+)',''
}

$rest = $rest.Trim().Trim('"').Trim()
if ($rest) { $root = $rest }

if (-not $doModules -and -not $doCustom) {
    Write-Host 'Nothing to do: --no-modules and --no-customizations cancel each other out.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host "Not a folder: $root" -ForegroundColor Red
    exit 1
}
$root = (Resolve-Path -LiteralPath $root).Path

# The bundles are read once, up front. Discovering halfway through a run that a
# source file is missing would leave some missions updated and some not.
$bundles = @{}   # archive entry name -> byte[] of the current bundle
if ($doCustom) {
    if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
        Write-Host "Customizations source folder not found: $srcDir" -ForegroundColor Red
        Write-Host 'Use --src "path" to point at it, or --no-customizations to skip that job.'
        exit 1
    }
    $srcDir = (Resolve-Path -LiteralPath $srcDir).Path

    foreach ($name in @('customizations.lua','ww2_customizations.lua')) {
        $p = Join-Path $srcDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-Host "Missing bundle: $p" -ForegroundColor Red
            Write-Host 'Nothing was built or generated - put the file there, or use'
            Write-Host '--no-customizations to skip that job.'
            exit 1
        }
        # Read as raw bytes, never as text. The bundle is UTF-8 with no BOM;
        # round-tripping through a string risks re-encoding it with one, and a
        # BOM is not a Lua comment - the mission would fail to load the file.
        # Bytes in, bytes out: whatever is in this file is what ships.
        $bundles["l10n/DEFAULT/$name"] = [IO.File]::ReadAllBytes($p)
    }
}

# ------------------------------------------------------------------ helpers --

# Matches both spellings DCS writes:
#     ["requiredModules"] = {},
#     ["requiredModules"] =
#     {
#         ["X"] = "X",
#     }, -- end of ["requiredModules"]
# The inner [^{}]* is safe because the table's values are plain strings, never
# nested tables. The trailing comma and "-- end of" comment are consumed so both
# input forms normalise to one output shape.
$rx = [regex]'(?m)^([ \t]*)\["requiredModules"\][ \t]*=[ \t]*\r?\n?[ \t]*\{[^{}]*\}[ \t]*,?[ \t]*(?:--[^\r\n]*)?'

function New-RequiredModulesBlock {
    param([string]$Indent, [bool]$IsWWII)

    if (-not $IsWWII) { return $Indent + '["requiredModules"] = {},' }

    # DCS emits a trailing space after "= " on the block form; match it exactly.
    @(
        $Indent + '["requiredModules"] = '
        $Indent + '{'
        $Indent + "`t" + '["WWII Armour and Technics"] = "WWII Armour and Technics",'
        $Indent + '}, -- end of ["requiredModules"]'
    ) -join "`n"
}

function Read-ZipEntryBytes {
    param([IO.Compression.ZipArchive]$Zip, [string]$Name)

    $entry = $Zip.GetEntry($Name)
    if (-not $entry) { return $null }

    $stream = $entry.Open()
    try {
        $ms = New-Object IO.MemoryStream
        try { $stream.CopyTo($ms); return $ms.ToArray() } finally { $ms.Dispose() }
    } finally { $stream.Dispose() }
}

# One open of the archive per mission, returning everything the main loop needs
# to decide what - if anything - has to change.
function Read-MizState {
    param([string]$Path, [bool]$IsWWII)

    $utf8 = New-Object Text.UTF8Encoding($false)
    $zip  = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $missionBytes = Read-ZipEntryBytes -Zip $zip -Name 'mission'
        $missionText  = if ($null -ne $missionBytes) { $utf8.GetString($missionBytes) } else { $null }

        $bundleName = if ($IsWWII) { 'l10n/DEFAULT/ww2_customizations.lua' }
                      else         { 'l10n/DEFAULT/customizations.lua' }

        # mapResource is what ties the file NAME to the resource key the mission's
        # DO SCRIPT FILE trigger uses. If the bundle is not named in there, then
        # replacing it would be changing a file DCS never reads.
        $mapBytes = Read-ZipEntryBytes -Zip $zip -Name 'l10n/DEFAULT/mapResource'
        $mapText  = if ($null -ne $mapBytes) { $utf8.GetString($mapBytes) } else { $null }

        return [pscustomobject]@{
            MissionText  = $missionText
            BundleName   = $bundleName
            BundleBytes  = Read-ZipEntryBytes -Zip $zip -Name $bundleName
            BundleMapped = ($null -ne $mapText) -and
                           $mapText.Contains('"' + (Split-Path -Leaf $bundleName) + '"')
        }
    } finally { $zip.Dispose() }
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)

    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length)       { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

# Rebuilds the archive into a temp file with the entries in their original
# order, substituting only the names in $Replacements. Every other entry is
# copied stream to stream, so its content is untouched. A zip entry cannot be
# patched in place because changing its content changes its compressed size,
# which shifts the offset of everything after it.
function Write-MizEntries {
    param(
        [string] $Path,
        [System.Collections.Generic.Dictionary[string,byte[]]] $Replacements
    )

    $tmp = $Path + '.tmp'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

    $src = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $fs = [IO.File]::Create($tmp)
        try {
            $dst = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entry in $src.Entries) {
                    $new = $dst.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
                    $new.LastWriteTime = $entry.LastWriteTime
                    if ($entry.FullName.EndsWith('/')) { continue }   # directory marker

                    $out = $new.Open()
                    try {
                        # Ordinal lookup - zip entry names are case sensitive.
                        $bytes = $null
                        if ($Replacements.TryGetValue($entry.FullName, [ref]$bytes)) {
                            $out.Write($bytes, 0, $bytes.Length)
                        } else {
                            $in = $entry.Open()
                            try { $in.CopyTo($out) } finally { $in.Dispose() }
                        }
                    } finally { $out.Dispose() }
                }
            } finally { $dst.Dispose() }      # writes the central directory
        } finally { $fs.Dispose() }
    } finally { $src.Dispose() }

    $target = Get-Item -LiteralPath $Path
    if ($target.IsReadOnly) { $target.IsReadOnly = $false }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# The Mission Editor holds a lock while it writes a .miz. Bail out loudly
# rather than reading a file that is halfway through being saved.
function Test-FileReady {
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Dispose()
        return $true
    } catch { return $false }
}

# --------------------------------------------------------------------- main --

$backupRoot = Join-Path $root ("_miz_backup_" + (Get-Date -Format 'yyyyMMdd-HHmmss'))

$files = @(
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.miz |
        Where-Object { $_.FullName -notmatch '\\_miz_backup_' } |
        Sort-Object FullName
)

$jobs = @()
if ($doModules) { $jobs += 'requiredModules' }
if ($doCustom)  { $jobs += 'customizations' }

Write-Host ''
Write-Host "Root   : $root"
Write-Host "Jobs   : $($jobs -join ' + ')"
if ($doCustom) { Write-Host "Source : $srcDir" }
Write-Host "Found  : $($files.Count) .miz file(s)"
if ($dryRun)       { Write-Host 'Mode   : DRY RUN - nothing will be written' -ForegroundColor Yellow }
elseif ($noBackup) { Write-Host 'Mode   : edit in place, NO BACKUPS' -ForegroundColor Yellow }
else               { Write-Host "Backup : $backupRoot" }
Write-Host ''

$updated = 0; $unchanged = 0; $failed = 0

foreach ($file in $files) {
    $label  = $file.FullName.Substring($root.Length).TrimStart('\')
    $isWWII = $file.Name -match '(?i)WW(II|2)'
    $tag    = if ($isWWII) { '[WWII]' } else { '      ' }

    try {
        if (-not $dryRun -and -not (Test-FileReady $file.FullName)) {
            Write-Host "$tag SKIP    $label" -ForegroundColor Red
            Write-Host '         file is open elsewhere - close the Mission Editor and re-run' -ForegroundColor Red
            $failed++; continue
        }

        $state = Read-MizState -Path $file.FullName -IsWWII $isWWII

        # Replacements accumulate across both jobs and are written in one pass,
        # so a mission needing both changes is still rebuilt only once.
        $repl      = New-Object 'System.Collections.Generic.Dictionary[string,byte[]]' ([StringComparer]::Ordinal)
        $notes     = @()
        $hardFail  = $false
        $jobFailed = $false

        # -- job 1: requiredModules, in the "mission" entry -------------------
        if ($doModules) {
            if ($null -eq $state.MissionText) {
                Write-Host "$tag SKIP    $label" -ForegroundColor Red
                Write-Host "         no 'mission' entry in archive" -ForegroundColor Red
                $hardFail = $true
            }
            else {
                $hits = $rx.Matches($state.MissionText)
                if ($hits.Count -ne 1) {
                    Write-Host "$tag SKIP    $label" -ForegroundColor Red
                    Write-Host "         expected 1 requiredModules match, found $($hits.Count)" -ForegroundColor Red
                    $hardFail = $true
                }
                else {
                    $hit     = $hits[0]
                    $block   = New-RequiredModulesBlock -Indent $hit.Groups[1].Value -IsWWII $isWWII
                    $newText = $state.MissionText.Substring(0, $hit.Index) + $block +
                               $state.MissionText.Substring($hit.Index + $hit.Length)

                    if ($newText -cne $state.MissionText) {
                        $repl['mission'] = (New-Object Text.UTF8Encoding($false)).GetBytes($newText)
                        $notes += 'requiredModules was: ' + (($hit.Value -replace '[\r\n\t]+',' ').Trim())
                    }
                }
            }
        }

        if ($hardFail) { $failed++; continue }

        # -- job 2: customizations bundle, in l10n/DEFAULT --------------------
        if ($doCustom) {
            $short = Split-Path -Leaf $state.BundleName
            $new   = $bundles[$state.BundleName]

            if ($null -eq $state.BundleBytes) {
                # Not an error: not every .miz under this tree is one of ours.
                # Adding the entry here would produce a file with no resource key,
                # which DCS would never load - so say so and leave it alone.
                $notes += "$short not present in archive - not added"
            }
            elseif (-not $state.BundleMapped) {
                # Something is wrong with this mission: the bundle is in the
                # archive but no resource key points at it, so DCS is not
                # loading it and replacing it would achieve nothing. Left alone
                # and flagged. The requiredModules job above is unaffected -
                # the two are independent, and that one is still worth doing.
                Write-Host "$tag PROBLEM $label" -ForegroundColor Red
                Write-Host "         $short is in the archive but not named in mapResource" -ForegroundColor Red
                Write-Host "         DCS is not loading it - bundle left untouched, fix the mission" -ForegroundColor Red
                $jobFailed = $true
            }
            elseif (Test-BytesEqual $state.BundleBytes $new) {
                # already current, nothing to do
            }
            else {
                $repl[$state.BundleName] = $new
                $notes += ("{0}: {1} -> {2} bytes" -f $short, $state.BundleBytes.Length, $new.Length)
            }
        }

        # -- write -------------------------------------------------------------
        if ($repl.Count -eq 0) {
            if (-not $jobFailed) {
                Write-Host "$tag ok      $label" -ForegroundColor DarkGray
                $unchanged++
            } else { $failed++ }
            foreach ($n in $notes) { Write-Host "         $n" -ForegroundColor DarkGray }
            continue
        }

        if ($dryRun) {
            Write-Host "$tag WOULD   $label" -ForegroundColor Cyan
            foreach ($n in $notes) { Write-Host "         $n" -ForegroundColor DarkGray }
            if ($jobFailed) { $failed++ } else { $updated++ }
            continue
        }

        if (-not $noBackup) {
            $dest = Join-Path $backupRoot $label
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        }

        Write-MizEntries -Path $file.FullName -Replacements $repl
        Write-Host "$tag UPDATED $label" -ForegroundColor Green
        foreach ($n in $notes) { Write-Host "         $n" -ForegroundColor DarkGray }
        if ($jobFailed) { $failed++ } else { $updated++ }
    }
    catch {
        Write-Host "$tag FAILED  $label" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ''
$verb = if ($dryRun) { 'would change' } else { 'updated' }
Write-Host ("{0} {1}, {2} already correct, {3} failed" -f $updated, $verb, $unchanged, $failed)
if ($failed) { exit 1 }
exit 0
