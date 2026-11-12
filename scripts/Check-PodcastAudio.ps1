<#
.SYNOPSIS
    Read-only check of podcast audio files for corrupt or incomplete downloads.

.DESCRIPTION
    For every audio file in -Path, runs ffprobe (and optionally a full ffmpeg decode)
    and flags files that look broken. Nothing is deleted or moved.

    Flags:
      PROBE_FAILED   ffprobe could not read the file, or it has no audio stream
      ZERO_DURATION  duration missing or 0
      SHORT          duration is under -ShortPercent of the folder's median duration
      TRUNCATED      file is smaller than the header's duration x bitrate implies
                     (download stopped early; only detectable when the MP3 has a Xing/VBRI header)
      DECODE_ERRORS  ffmpeg reported errors while decoding the whole file

.EXAMPLE
    .\Check-PodcastAudio.ps1 -Path 'T:\podcasts\gPodder\Downloads\Some Show'

.EXAMPLE
    .\Check-PodcastAudio.ps1 -Path 'T:\podcasts\gPodder\Downloads\Some Show' -SkipDecode
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    # Flag files shorter than this percentage of the folder's median duration.
    [int]$ShortPercent = 50,

    # Flag as truncated when actual size is below this percentage of expected size.
    [int]$TruncatedPercent = 90,

    # Skip the full ffmpeg decode pass (much faster, misses mid-file corruption).
    [switch]$SkipDecode,

    [string]$OutCsv = (Join-Path $PWD 'podcast-audio-check.csv')
)

$ErrorActionPreference = 'Stop'

foreach ($tool in 'ffprobe', 'ffmpeg') {
    if ($tool -eq 'ffmpeg' -and $SkipDecode) { continue }
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found on PATH."
    }
}

$extensions = '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.flac', '.wav'
$files = Get-ChildItem -LiteralPath $Path -File | Where-Object { $extensions -contains $_.Extension.ToLower() }
if (-not $files) { throw "No audio files found in $Path" }

$results = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($f in $files) {
    $i++
    Write-Progress -Activity 'Checking audio' -Status $f.Name -PercentComplete ($i / $files.Count * 100)

    $row = [ordered]@{
        File         = $f.Name
        SizeMB       = [math]::Round($f.Length / 1MB, 1)
        DurationMin  = $null
        BitrateKbps  = $null
        ExpectedMB   = $null
        DecodeErrors = $null
        Flags        = [System.Collections.Generic.List[string]]::new()
        ProbeError   = $null
    }

    $probeJson = & ffprobe -v error -show_entries 'format=duration,bit_rate:stream=codec_type' -of json -- $f.FullName 2>&1
    $probeErrLines = $probeJson | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    $probeOut = ($probeJson | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"

    $probe = $null
    if ($LASTEXITCODE -eq 0 -and $probeOut) {
        try { $probe = $probeOut | ConvertFrom-Json } catch { $probe = $null }
    }

    if (-not $probe -or -not ($probe.streams | Where-Object codec_type -eq 'audio')) {
        $row.Flags.Add('PROBE_FAILED')
        $row.ProbeError = ($probeErrLines | ForEach-Object { $_.ToString() }) -join ' | '
    }
    else {
        $duration = 0.0
        [double]::TryParse([string]$probe.format.duration, [ref]$duration) | Out-Null
        $bitrate = 0.0
        [double]::TryParse([string]$probe.format.bit_rate, [ref]$bitrate) | Out-Null

        $row.DurationMin = [math]::Round($duration / 60, 1)
        if ($bitrate -gt 0) { $row.BitrateKbps = [math]::Round($bitrate / 1000) }

        if ($duration -le 0) {
            $row.Flags.Add('ZERO_DURATION')
        }
        elseif ($bitrate -gt 0) {
            $expectedBytes = $duration * $bitrate / 8
            $row.ExpectedMB = [math]::Round($expectedBytes / 1MB, 1)
            if ($f.Length -lt $expectedBytes * $TruncatedPercent / 100) {
                $row.Flags.Add('TRUNCATED')
            }
        }
    }

    if (-not $SkipDecode -and -not $row.Flags.Contains('PROBE_FAILED')) {
        $decodeOut = & ffmpeg -nostdin -hide_banner -v error -i $f.FullName -f null - 2>&1
        $errCount = @($decodeOut | Where-Object { "$_".Trim() }).Count
        $row.DecodeErrors = $errCount
        if ($errCount -gt 0) { $row.Flags.Add('DECODE_ERRORS') }
    }

    $results.Add([pscustomobject]$row)
}
Write-Progress -Activity 'Checking audio' -Completed

# Relative length check against the folder median.
$durations = $results | Where-Object { $_.DurationMin -gt 0 } | Sort-Object DurationMin | Select-Object -ExpandProperty DurationMin
if ($durations) {
    $median = $durations[[int][math]::Floor($durations.Count / 2)]
    $threshold = $median * $ShortPercent / 100
    foreach ($r in $results) {
        if ($r.DurationMin -gt 0 -and $r.DurationMin -lt $threshold) { $r.Flags.Add('SHORT') }
    }
    Write-Host ("Median duration: {0} min. SHORT threshold: {1:N1} min." -f $median, $threshold)
}

$output = $results | Select-Object File, SizeMB, DurationMin, BitrateKbps, ExpectedMB, DecodeErrors,
    @{ n = 'Flags'; e = { $_.Flags -join ',' } }, ProbeError

$output | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding utf8

$suspects = $output | Where-Object Flags
Write-Host ("Checked {0} files. Suspect: {1}. Full results: {2}" -f $results.Count, @($suspects).Count, $OutCsv)
if ($suspects) {
    $suspects | Sort-Object Flags, File | Format-Table File, SizeMB, DurationMin, ExpectedMB, DecodeErrors, Flags -AutoSize
}
