<#
.SYNOPSIS
    Builds dist/vmware-vxrail-expert.zip for Microsoft 365 Copilot (Chat "Upload skill", Agent Builder, Copilot Studio).

.DESCRIPTION
    Copilot Chat requires SKILL.md at the root of the zip with no enclosing folder. This script
    writes every entry with forward slashes (Windows PowerShell 5.1's Compress-Archive can write
    backslashes, which some hosts reject), then runs Test-SkillPackage.ps1 against the result.

.EXAMPLE
    ./tools/Build-SkillPackage.ps1
#>
[CmdletBinding()]
param(
    [string]$SkillDir = (Join-Path $PSScriptRoot '..\skills\vmware-vxrail-expert'),
    [string]$OutFile  = (Join-Path $PSScriptRoot '..\dist\vmware-vxrail-expert.zip')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$SkillDir = (Resolve-Path $SkillDir).Path
$outDir = Split-Path -Parent $OutFile
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$OutFile = Join-Path (Resolve-Path $outDir).Path (Split-Path -Leaf $OutFile)
if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }

$zip = [System.IO.Compression.ZipFile]::Open($OutFile, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -LiteralPath $SkillDir -Recurse -File | Sort-Object FullName | ForEach-Object {
        $entry = $_.FullName.Substring($SkillDir.Length).TrimStart('\', '/') -replace '\\', '/'
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $_.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host "  + $entry"
    }
} finally { $zip.Dispose() }

Write-Host "Built $OutFile ($([math]::Round((Get-Item $OutFile).Length / 1KB, 1)) KB)" -ForegroundColor Green
& (Join-Path $PSScriptRoot 'Test-SkillPackage.ps1') -SkillDir $SkillDir -ZipFile $OutFile
