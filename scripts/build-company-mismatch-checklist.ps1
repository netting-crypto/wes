param(
    [string]$CompanyTargetsPath = 'config/wes/company-family-targets.tsv',
    [string]$OutputPath = 'output/wes/reports/company-mismatch-checklist.md'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path (Get-RepoRoot) $Path
}

$targets = Import-Csv -Path (Resolve-RepoPath -Path $CompanyTargetsPath) -Delimiter "`t"
$outputPath = Resolve-RepoPath -Path $OutputPath
$outputDir = Split-Path -Parent $outputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$lines = @()
$lines += '# Company Mismatch Checklist'
$lines += ''
$lines += ('- generated_at: {0}' -f (Get-Date).ToString('o'))
$lines += ''

$families = $targets | Group-Object family_id | Sort-Object Name
foreach ($family in $families) {
    $familyId = [string]$family.Name
    $rows = @($family.Group)
    $sampleSheet = $rows[0].sample_sheet
    $sampleRows = Import-Csv -Path (Resolve-RepoPath -Path $sampleSheet) -Delimiter "`t"
    $bamReadyCount = @($sampleRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.bam_path) }).Count
    $rolesKnownCount = @($sampleRows | Where-Object { [string]$_.role -and [string]$_.role -ne 'unknown' }).Count
    $affectedPositiveCount = @($sampleRows | Where-Object { [string]$_.affected -eq '1' }).Count
    $genes = @($rows.gene | Sort-Object -Unique)
    $labs = @($rows.company_lab_id | Sort-Object -Unique)

    $lines += "## $familyId"
    $lines += ''
    $lines += ('- sample_sheet: `{0}`' -f $sampleSheet.Replace('\', '/'))
    $lines += ('- company_locus_count: {0}' -f $rows.Count)
    $lines += ('- company_lab_ids: {0}' -f ($labs -join ', '))
    $lines += ('- genes: {0}' -f ($genes -join ', '))
    $lines += ('- sample_count: {0}' -f $sampleRows.Count)
    $lines += ('- bam_ready_count: {0}' -f $bamReadyCount)
    $lines += ('- role_known_count: {0}' -f $rolesKnownCount)
    $lines += ('- affected_positive_count: {0}' -f $affectedPositiveCount)
    $lines += ''
    $lines += '- non_bed_checks:'
    $lines += ('  sample_mapping: {0}' -f ($(if ($rolesKnownCount -eq $sampleRows.Count) { 'ready' } else { 'needs_mapping' })))
    $lines += ('  bam_reuse: {0}' -f ($(if ($bamReadyCount -eq $sampleRows.Count) { 'full' } elseif ($bamReadyCount -gt 0) { 'partial' } else { 'missing' })))
    $lines += ('  pedigree_flags: {0}' -f ($(if ($affectedPositiveCount -gt 0) { 'present' } else { 'missing' })))
    $lines += '  exact_call_check: pending'
    $lines += '  locus_support_check: pending'
    $lines += '  reference_build_check: pending'
    $lines += ''
}

$lines | Set-Content -Path $outputPath -Encoding UTF8
Write-Host $outputPath
