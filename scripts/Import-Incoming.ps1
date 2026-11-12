# Hourly: tag anything the upstream tool left in T:\incoming and file it into T:\music,
# then have Navidrome pick it up.
#
# Safe by design:
#   - does nothing if the upstream tool is still writing (any file touched in the last 2 min)
#   - beets quiet mode applies confident matches only; anything ambiguous is
#     left in T:\incoming and retried next hour
#   - partial albums score too low to match, so they wait until the album is
#     complete. Files are never deleted, only moved.

$ErrorActionPreference = 'Stop'

$Staging   = 'T:\incoming'
$Library   = 'T:\music'
$ConfigDir = 'D:\Projects\beets\config'
$Log       = 'D:\Projects\beets\import.log'
$Image     = 'linuxserver/beets:latest'
$QuietMins = 2

function Write-Log([string]$msg) {
    Add-Content -LiteralPath $Log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
}

try {
    if (-not (Test-Path -LiteralPath $Staging)) { exit 0 }

    $audio = @(Get-ChildItem -LiteralPath $Staging -File -Recurse -Include *.mp3, *.wav, *.flac -ErrorAction SilentlyContinue)
    if ($audio.Count -eq 0) { exit 0 }   # nothing staged, stay quiet

    # The upstream tool writes files over time; don't touch a file mid-write.
    $busy = @($audio | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-$QuietMins) })
    if ($busy.Count -gt 0) {
        Write-Log ("SKIP - {0} of {1} file(s) still being written" -f $busy.Count, $audio.Count)
        exit 0
    }

    Write-Log ("START - {0} file(s) staged" -f $audio.Count)

    # -g/--group-albums is required: beets treats a directory as one release, and
    # staging is a flat folder holding tracks from several different albums.
    $out = docker run --rm `
        -v "${ConfigDir}:/config" `
        -v "${Staging}:/incoming" `
        -v "${Library}:/library" `
        --entrypoint /bin/sh $Image `
        -c "beet -c /config/config.yaml import -q -g /incoming 2>&1"

    $matched = @($out | Select-String -Pattern 'Match \(' -AllMatches).Count
    $skipped = @($out | Select-String -Pattern '^Skipping\.' -AllMatches).Count

    $left  = @(Get-ChildItem -LiteralPath $Staging -File -Recurse -Include *.mp3, *.wav, *.flac -ErrorAction SilentlyContinue)

    # Count the files from THIS batch that beets actually moved out, rather than
    # differencing the two totals. The upstream tool keeps writing during the run, so a file
    # that arrives mid-import inflates $left: 6 staged - 7 left reported "filed -1",
    # and because the rescan is gated on $filed -gt 0 a run that really did file
    # tracks could skip the rescan whenever new arrivals outnumbered them.
    $filed = @($audio | Where-Object { -not (Test-Path -LiteralPath $_.FullName) }).Count

    Write-Log ("DONE - filed {0} file(s); {1} album(s) matched, {2} skipped; {3} file(s) left staged" -f `
               $filed, $matched, $skipped, $left.Count)

    if ($filed -gt 0) {
        # Navidrome writes its startup banner to stderr, and Windows PowerShell 5.1 turns a
        # native command's stderr into ErrorRecords. With $ErrorActionPreference = 'Stop'
        # the banner's first line became a terminating error, so every successful run logged
        # "ERROR -  _  _ ..." and the task exited 1. 2>$null does NOT prevent this in 5.1 -
        # the records are created before the redirection applies - so drop the preference
        # for this one call and judge the scan by its exit code instead.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        docker exec navidrome /app/navidrome scan 2>&1 | Out-Null
        $scanRc = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        if ($scanRc -eq 0) { Write-Log "Navidrome rescan triggered" }
        else { Write-Log ("Navidrome rescan returned exit code {0}" -f $scanRc) }
    }
}
catch {
    Write-Log ("ERROR - {0}" -f $_.Exception.Message)
    exit 1
}
