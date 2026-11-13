<#
.SYNOPSIS
    Checks the skill, the Agent Builder instructions and the built zip against Microsoft Copilot,
    GitHub Copilot and Agent Skills limits (as published on Microsoft Learn / GitHub Docs, November 2026).

.EXAMPLE
    ./tools/Test-SkillPackage.ps1 -ZipFile ./dist/vmware-vxrail-expert.zip
#>
[CmdletBinding()]
param(
    [string]$SkillDir = (Join-Path $PSScriptRoot '..\skills\vmware-vxrail-expert'),
    [string]$Instructions = (Join-Path $PSScriptRoot '..\agent\instructions.txt'),
    [string]$AgentName = 'VMware & VxRail Expert',
    [string]$ZipFile
)
$ErrorActionPreference = 'Stop'
$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  PASS  $Name  ($Detail)" -ForegroundColor Green }
    else     { Write-Host "  FAIL  $Name  ($Detail)" -ForegroundColor Red; $script:failures++ }
}

$SkillDir  = (Resolve-Path $SkillDir).Path
$skillFile = Join-Path $SkillDir 'SKILL.md'
$folder    = Split-Path -Leaf $SkillDir
$bytes     = [System.IO.File]::ReadAllBytes($skillFile)
$text      = [System.Text.Encoding]::UTF8.GetString($bytes)

Write-Host 'SKILL.md' -ForegroundColor Cyan
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
Check 'UTF-8 without BOM' (-not $hasBom) $(if ($hasBom) { 'BOM found' } else { 'no BOM' })
Check 'Under 20,000 characters' ($text.Length -lt 20000) "$($text.Length) chars"

$fm = [regex]::Match($text, '^---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
Check 'YAML front matter present' $fm.Success 'leading --- block'
if ($fm.Success) {
    $keys = [regex]::Matches($fm.Groups[1].Value, '(?m)^([A-Za-z_-]+):') | ForEach-Object { $_.Groups[1].Value }
    Check 'Only name and description keys' (-not ($keys | Where-Object { $_ -notin 'name', 'description' })) ($keys -join ', ')
    $name = [regex]::Match($fm.Groups[1].Value, '(?m)^name:\s*(.+?)\s*$').Groups[1].Value
    $desc = [regex]::Match($fm.Groups[1].Value, '(?m)^description:\s*(.+?)\s*$').Groups[1].Value
    Check 'name pattern' ($name -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$') $name
    Check 'name <= 64 chars' ($name.Length -le 64) "$($name.Length)"
    Check 'name matches folder' ($name -eq $folder) "folder '$folder'"
    Check 'description 1-1,024 chars' ($desc.Length -ge 1 -and $desc.Length -le 1024) "$($desc.Length)"
    Check 'description has no XML tags' ($desc -notmatch '<[^>]+>') 'no <tags>'
    Check 'description is third person' ($desc -notmatch '^(I |You |We )') ($desc.Substring(0, [math]::Min(40, $desc.Length)) + '...')
}

$refs = Get-ChildItem -LiteralPath (Join-Path $SkillDir 'references') -File -ErrorAction SilentlyContinue
foreach ($r in $refs) {
    $linked = $text -match [regex]::Escape("references/$($r.Name)")
    Check "linked from SKILL.md: $($r.Name)" $linked 'progressive disclosure'
    $rb = [System.IO.File]::ReadAllBytes($r.FullName)
    Check "under 25 MB and no BOM: $($r.Name)" ($rb.Length -lt 25MB -and -not ($rb.Length -ge 3 -and $rb[0] -eq 0xEF -and $rb[1] -eq 0xBB)) "$([math]::Round($rb.Length/1KB,1)) KB"
}

Write-Host 'Agent Builder' -ForegroundColor Cyan
if (Test-Path -LiteralPath $Instructions) {
    $ins = [System.IO.File]::ReadAllText((Resolve-Path $Instructions).Path)
    Check 'instructions.txt under 8,000 characters' ($ins.Length -lt 8000) "$($ins.Length) chars"
} else { Check 'instructions.txt exists' $false $Instructions }
Check 'Agent name <= 30 characters' ($AgentName.Length -le 30) "'$AgentName' = $($AgentName.Length)"

if ($ZipFile) {
    Write-Host 'Zip package' -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = (Resolve-Path $ZipFile).Path
    $size = (Get-Item $zipPath).Length
    Check 'Zip under 50 MB' ($size -lt 50MB) "$([math]::Round($size/1KB,1)) KB"
    $z = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($z.Entries | Where-Object { $_.Name } | ForEach-Object FullName)
        Check 'SKILL.md at zip root' ($names -contains 'SKILL.md') 'no enclosing folder'
        Check 'Forward slashes only' (-not ($names | Where-Object { $_ -match '\\' })) "$($names.Count) entries"
        $depth = ($names | ForEach-Object { ($_ -split '/').Count - 1 } | Measure-Object -Maximum).Maximum
        Check 'Directory depth <= 3' ($depth -le 3) "max $depth"
        Check '350 files or fewer' ($names.Count -le 350) "$($names.Count)"
        $big = $z.Entries | Where-Object { $_.Length -gt 25MB }
        Check 'Each file <= 25 MB' (-not $big) 'per-file limit'
    } finally { $z.Dispose() }
}

Write-Host ''
if ($failures) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
