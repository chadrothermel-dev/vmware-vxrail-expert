<#
.SYNOPSIS
    Extracts and filters VMware / VxRail support bundles into small text files you can paste or upload to Copilot.

.DESCRIPTION
    Microsoft Copilot can't open .tgz support bundles, and chat uploads have per-file size limits.
    This script does the boring part locally:
      1. Extracts a vm-support / vc-support / VxRail / SoS bundle (.tgz, .tar.gz, .tar, .zip) or reads a folder.
         Nested bundles inside (for example host bundles inside a vCenter bundle) are extracted too.
      2. Decompresses rotated logs (*.gz).
      3. Keeps only lines that match known VMware/VxRail failure signatures, optionally within a time window.
      4. Writes size-limited .txt chunks plus a summary of hits per file and category.

    Nothing leaves your machine. Review the output before sharing it, and use -MaskIPs if your
    policy requires it.

.PARAMETER Path
    Bundle file or an already-extracted folder.

.PARAMETER EventTime
    When the problem happened, in your local time unless -EventTimeIsUtc is set.
    ESXi and vCenter logs are written in UTC; the script converts for you.
    The window treats every log timestamp as UTC. Some logs (VxRail Manager, SDDC Manager, Aria
    appliances, guest OS logs) may be written in local time - for those, widen -WindowMinutes by
    your UTC offset or leave -EventTime out.

.PARAMETER WindowMinutes
    Minutes either side of EventTime to keep. Default 30.

.PARAMETER EventTimeIsUtc
    Treat EventTime as UTC instead of local time.

.PARAMETER Context
    Lines of context to keep before each match. Default 2.

.PARAMETER MaxChunkChars
    Maximum characters per output file. Default 25000, which stays under Copilot Studio's
    30,000-characters-per-file limit for uploads without code interpreter.

.PARAMETER Category
    Limit matching to these categories (see Get-Help -Full for the list). Default: all.

.PARAMETER MaskIPs
    Replace IPv4 addresses with consistent tokens (IP-001, IP-002 ...). The mapping is written to
    ip-map.csv in the output folder so you can translate answers back; don't share that file.

.PARAMETER IncludeGenericErrors
    Also keep any line containing a generic error/warning/failed marker. Off by default because it
    keeps most of hostd/vpxd and produces far more output; use it with -EventTime and a short window.

.PARAMETER OutDir
    Output folder. Default: .\triage-<timestamp> next to where you run the script.

.EXAMPLE
    ./Invoke-LogTriage.ps1 -Path .\esx-host01-2026-11-10.tgz -EventTime '2026-11-10 14:05'

.EXAMPLE
    ./Invoke-LogTriage.ps1 -Path .\vc-support.tgz -Category vcenter,certificates -MaskIPs

.NOTES
    Works in PowerShell 7+ (recommended) and Windows PowerShell 5.1. Needs tar.exe for .tgz/.tar
    (built into Windows 10 1803+ and Windows 11, macOS and Linux).
    Categories: storage, psod, network, host, vsan, ha, vcenter, certificates, space, vxrail, vcf, nsx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [datetime]$EventTime,
    [int]$WindowMinutes = 30,
    [switch]$EventTimeIsUtc,
    [int]$Context = 2,
    [int]$MaxChunkChars = 25000,
    [string[]]$Category,
    [switch]$MaskIPs,
    [switch]$IncludeGenericErrors,
    [string]$OutDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Signature catalogue. Case-insensitive regex. Keep in sync with references/log-triage.md.
# ---------------------------------------------------------------------------
$Signatures = [ordered]@{
    storage      = 'H:0x[1-9a-f]|D:0x[1-9a-f]|Valid sense data|\bAPD\b|PERM LOSS|permanently (unavailable|inaccessible)|\bPDL\b|is blocked\. Not starting I/O|no more open connections|performance has deteriorated|Lost access to volume|Successfully restored access|ATS Miscompare|redundancy (lost|degraded)|\bpath\b.*\b(dead|changing to)\b|\bcorrupt(ed|ion)?\b'
    psod         = '\bPSOD\b|\bPanic\b|Exception (13|14)|#PF|#GP|\bLINT1\b|\bNMI\b|\bMCE\b|Machine Check|didn''t have a heartbeat|no heartbeat|Spin count exceeded|TLB invalidate|vmkernel-zdump'
    network      = 'NIC Link is (Down|Up)|linkstate|Duplicate IP|out of sync|\blacp\b.*\b(down|fail|timeout|error)|vmotion.*\b(fail|timeout|error)|Migrate:.*\b(fail|error)|Failed waiting for data|switchover time'
    host         = 'not responding|hostd.*\b(hang|hung|timeout|crash)|\bTimed out\b|watchdog.*\b(restart|fail)|ramdisk .*full|No space left on device'
    vsan         = 'permanent error|DISK_UNDER_PERM_ERROR|LogCong|Congestion|IMPENDING FAILURE|devicewithhighlatency|lsom\.diskerror|devicerepair|CONTROLLER_STATE_FAILED|\b(vsan|cluster|network)\b.*\bpartition(ed)?\b|\bpartition(ed)?\b.*\b(vsan|cluster|network)\b|unicast.*\b(fail|missing|not configured)|\binaccessible\b|\bDDH\b'
    ha           = 'UninitializedState|GenericFdmFault|\bisolated\b|isolation (address|response)|fdm.*\b(error|fail)|insufficient (failover )?resources|ClusterElection'
    vcenter      = '-- ERROR task-|vim\.fault|503 Service Unavailable|no healthy upstream|Failed to connect to endpoint|failedSteps|firstboot.*\b(error|fail)|Encountered an internal error|ODBC error|OutOfMemoryError'
    certificates = 'certificate.*\b(expired|expir\w*|invalid|not valid|mismatch|untrusted|fail\w*|error)\b|SSLHandshake|Signing certificate is not valid|thumbprint.*\b(mismatch|invalid)\b|trust anchor|PKIX|\bexpired\b'
    space        = 'No space left on device|disk (is )?full|\bis full\b|inode.*\b(exhaust\w*|full|no free)\b|ramdisk .*full'
    vxrail       = 'func_\S+.*\b(fail\w*|error|exception)\b|microservice\.\S+.*\b(ERROR|Exception|failed)\b|refresh token|pre-?check.*\b(fail\w*|error)\b|VxVerify.*\b(fail|warn)|lockbox.*\b(fail|error|mismatch)|loudmouth.*\b(fail|error)|PTAgent.*\b(fail|error|timeout)|platformsvc.*\b(fail|error)|ExpansionValidation|Failed to login by session cookie|\bMYSTIC\d+|\bVXR\d+'
    vcf          = '(domainmanager|operationsmanager|lcm).*\b(ERROR|Exception|failed)\b|depot.*\b(error|fail\w*|unable)\b|dl\.broadcom\.com.*\b(fail\w*|error|unable|403|401)\b|IDENTITY_INTERNAL_SERVER_ERROR|password.*\b(expired|rotation fail\w*|remediat\w*)'
    nsx          = 'tunnel.*\bdown\b|\bBFD\b.*\bdown\b|\bTEPs?\b.*\b(down|fail\w*|unreachable|faulty)\b|Faulty TEP|password-expiration|transport node.*\b(fail\w*|down|degraded)\b|\bnsx\w*.*\b(error|fail\w*)\b'
}
# Generic severity markers. Only used with -IncludeGenericErrors, because they match a large share
# of routine hostd/vpxd lines and would flood the output.
$SeverityPattern = '\b(Er|Cr|Al|Em)\(\d+\)|\berror\b|\bwarning\b|\bfailed\b|\bfatal\b'

if ($Category) {
    $unknown = $Category | Where-Object { -not $Signatures.Contains($_) }
    if ($unknown) { throw "Unknown category: $($unknown -join ', '). Valid: $($Signatures.Keys -join ', ')" }
    $active = [ordered]@{}
    foreach ($c in $Category) { $active[$c] = $Signatures[$c] }
} else {
    $active = $Signatures
}
$compiled = [ordered]@{}
foreach ($k in $active.Keys) {
    $compiled[$k] = [regex]::new($active[$k], [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Compiled')
}
$severityRx = [regex]::new($SeverityPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Compiled')
$timeRx     = [regex]::new('^\D{0,4}(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})', 'Compiled')
$ipRx       = [regex]::new('\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b', 'Compiled')

# ---------------------------------------------------------------------------
# Time window
# ---------------------------------------------------------------------------
$windowStart = $null; $windowEnd = $null
if ($PSBoundParameters.ContainsKey('EventTime')) {
    $utc = if ($EventTimeIsUtc) { [datetime]::SpecifyKind($EventTime, 'Utc') } else { $EventTime.ToUniversalTime() }
    $windowStart = $utc.AddMinutes(-$WindowMinutes)
    $windowEnd   = $utc.AddMinutes($WindowMinutes)
}

# ---------------------------------------------------------------------------
# Folders. Extracted bundle content goes in its own empty folder, apart from this script.
# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) { $OutDir = Join-Path (Get-Location) "triage-$stamp" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$resolved = (Resolve-Path $Path).Path
$workRoot = $null
function Expand-Bundle {
    param([string]$Archive, [string]$Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    if ($Archive -match '\.zip$') {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
    } else {
        $tar = Get-Command tar -ErrorAction SilentlyContinue
        if (-not $tar) { throw 'tar is required to extract .tgz/.tar bundles. Extract the bundle manually and pass the folder instead.' }
        # Bundles can contain device nodes or absolute links; ignore extraction warnings, keep going.
        & $tar.Source -xf $Archive -C $Destination 2>$null
    }
}

if (Test-Path -LiteralPath $resolved -PathType Container) {
    $scanRoot = $resolved
} else {
    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmw-triage-$stamp"
    Write-Host "Extracting $([System.IO.Path]::GetFileName($resolved)) ..." -ForegroundColor Cyan
    Expand-Bundle -Archive $resolved -Destination $workRoot
    $scanRoot = $workRoot
}

# Nested bundles (two levels is enough for vc-support → host bundles).
for ($depth = 0; $depth -lt 2; $depth++) {
    $nested = @(Get-ChildItem -LiteralPath $scanRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(tgz|tar\.gz|tar)$' -and $_.Length -gt 0 })
    if ($nested.Count -eq 0) { break }
    foreach ($n in $nested) {
        $dest = Join-Path $n.DirectoryName ($n.Name -replace '\.(tgz|tar\.gz|tar)$', '_extracted')
        if (Test-Path -LiteralPath $dest) { continue }
        Write-Host "  nested bundle: $($n.Name)" -ForegroundColor DarkCyan
        try { Expand-Bundle -Archive $n.FullName -Destination $dest; Remove-Item -LiteralPath $n.FullName -Force }
        catch { Write-Warning "Could not extract $($n.FullName): $_" }
    }
}

# ---------------------------------------------------------------------------
# Candidate files: logs, rotated logs, and a few known JSON status files.
# ---------------------------------------------------------------------------
$files = @(Get-ChildItem -LiteralPath $scanRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -match '\.(log|txt|out)(\.\d+)?(\.gz)?$' -or
     $_.Name -match '^(vmkernel|vobd|vmkwarning|vmksummary|hostd|vpxa|fdm|syslog|messages|clomd|vsanmgmt|vsandevicemonitord|vsansystem|osfsd|lifecycle|esxupdate|loadESX)' -or
     $_.Name -match '^(firstbootStatus|fbInstall)\.json$') -and $_.Length -gt 0
})
if ($files.Count -eq 0) { throw "No log files found under $scanRoot." }
Write-Host "Scanning $($files.Count) files ..." -ForegroundColor Cyan

function Open-LogReader {
    param([System.IO.FileInfo]$File)
    $stream = [System.IO.File]::OpenRead($File.FullName)
    if ($File.Name -match '\.gz$') {
        $stream = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress)
    }
    return [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
}

$ipMap = @{}
function Protect-Line {
    param([string]$Line)
    if (-not $MaskIPs) { return $Line }
    return $ipRx.Replace($Line, {
        param($m)
        if (-not $ipMap.ContainsKey($m.Value)) { $ipMap[$m.Value] = 'IP-{0:D3}' -f ($ipMap.Count + 1) }
        $ipMap[$m.Value]
    })
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
$results  = [System.Collections.Generic.List[object]]::new()
$summary  = [System.Collections.Generic.List[object]]::new()

foreach ($f in $files) {
    $rel = $f.FullName.Substring($scanRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    $counts = [ordered]@{}; foreach ($k in $compiled.Keys) { $counts[$k] = 0 }
    $kept = [System.Collections.Generic.List[string]]::new()
    $buffer = [System.Collections.Generic.Queue[string]]::new()
    $inWindow = $true
    $lastEmitted = -10
    $lineNo = 0
    $isStatusJson = $f.Name -match '\.json$'

    try { $reader = Open-LogReader -File $f } catch { Write-Warning "Skipping $rel : $_"; continue }
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNo++
            if ($windowStart) {
                $tm = $timeRx.Match($line)
                if ($tm.Success) {
                    $ts = [datetime]::MinValue
                    if ([datetime]::TryParse("$($tm.Groups[1].Value)T$($tm.Groups[2].Value)Z", [cultureinfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$ts)) {
                        $inWindow = ($ts -ge $windowStart -and $ts -le $windowEnd)
                    }
                }
                if (-not $inWindow) { $buffer.Clear(); continue }
            }

            $hit = $isStatusJson
            foreach ($k in $compiled.Keys) {
                if ($compiled[$k].IsMatch($line)) { $counts[$k]++; $hit = $true }
            }
            if (-not $hit -and $IncludeGenericErrors -and $severityRx.IsMatch($line)) { $hit = $true }

            if ($hit) {
                if ($lineNo - $lastEmitted -gt $Context + 1 -and $kept.Count -gt 0) { $kept.Add('  ...') }
                while ($buffer.Count -gt 0) { $kept.Add((Protect-Line $buffer.Dequeue())) }
                $kept.Add((Protect-Line $line))
                $lastEmitted = $lineNo
            } else {
                $buffer.Enqueue($line)
                while ($buffer.Count -gt $Context) { [void]$buffer.Dequeue() }
            }
        }
    } finally { $reader.Dispose() }

    $total = [int](($counts.Values | Measure-Object -Sum).Sum)
    if ($kept.Count -gt 0) {
        $results.Add([pscustomobject]@{ File = $rel; Lines = $kept })
        $row = [ordered]@{ File = $rel; KeptLines = $kept.Count; SignatureHits = $total }
        foreach ($k in $counts.Keys) { $row[$k] = $counts[$k] }
        $summary.Add([pscustomobject]$row)
    }
}

if ($results.Count -eq 0) {
    Write-Warning 'No matching lines. Widen -WindowMinutes, check the -EventTime timezone, or drop -Category.'
    if ($workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    return
}

# ---------------------------------------------------------------------------
# Write chunks: most relevant files first.
# ---------------------------------------------------------------------------
$ordered = $results | Sort-Object { ($summary | Where-Object File -eq $_.File).SignatureHits } -Descending
$header = @(
    '# VMware/VxRail log triage extract'
    "# Source: $([System.IO.Path]::GetFileName($resolved))"
    $(if ($windowStart) { "# Window (UTC): $($windowStart.ToString('u')) to $($windowEnd.ToString('u'))" } else { '# Window: whole file' })
    '# Lines are filtered; "..." marks skipped lines. Timestamps are as written in each log (ESXi/vCenter = UTC).'
    ''
) -join [Environment]::NewLine

$chunk = 1; $sb = [System.Text.StringBuilder]::new($header)
$written = [System.Collections.Generic.List[string]]::new()
function Save-Chunk {
    $name = Join-Path $OutDir ('triage-{0:D3}.txt' -f $script:chunk)
    [System.IO.File]::WriteAllText($name, $script:sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    $script:written.Add($name)
    $script:chunk++
    $script:sb = [System.Text.StringBuilder]::new($header)
}
foreach ($r in $ordered) {
    $block = "### $($r.File)" + [Environment]::NewLine
    foreach ($l in $r.Lines) {
        if ($l.Length -gt 2000) { $l = $l.Substring(0, 2000) + ' [truncated]' }
        $entry = $l + [Environment]::NewLine
        if ($sb.Length + $block.Length + $entry.Length -gt $MaxChunkChars) {
            if ($block.Length -gt 0) { [void]$sb.Append($block) }
            Save-Chunk
            $block = "### $($r.File) (continued)" + [Environment]::NewLine
        }
        $block += $entry
    }
    [void]$sb.Append($block + [Environment]::NewLine)
}
if ($sb.Length -gt $header.Length) { Save-Chunk }

$summary | Sort-Object SignatureHits -Descending |
    Select-Object (@('File', 'KeptLines', 'SignatureHits') + @($compiled.Keys)) |
    Export-Csv -Path (Join-Path $OutDir 'summary.csv') -NoTypeInformation -Encoding UTF8
if ($MaskIPs -and $ipMap.Count) {
    $ipMap.GetEnumerator() | Sort-Object Value | Select-Object @{n='Token';e={$_.Value}}, @{n='IPAddress';e={$_.Key}} |
        Export-Csv -Path (Join-Path $OutDir 'ip-map.csv') -NoTypeInformation -Encoding UTF8
}
if ($workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host "Done. $($written.Count) file(s) in $OutDir" -ForegroundColor Green
if ($written.Count -gt 10) {
    Write-Warning "That's a lot to upload. Narrow it with -EventTime (and -WindowMinutes) or -Category, and start with triage-001.txt - the busiest files come first."
}
$summary | Sort-Object SignatureHits -Descending | Select-Object -First 10 File, KeptLines, SignatureHits | Format-Table -AutoSize
Write-Host 'Next: upload triage-001.txt (and more if needed) to Copilot with the time of the event and what changed before it.'
if ($MaskIPs) { Write-Host 'ip-map.csv maps tokens back to real IPs. Keep it local.' -ForegroundColor Yellow }
