param(
    [string]$CompanyResultsPath = "config/wes/company-analysis-results.tsv",
    [string]$SampleSheetPattern = "config/wes/samples.family*.tsv",
    [string]$OutputPath = "config/wes/company-family-targets.tsv"
)

$ErrorActionPreference = "Stop"
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

function Get-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $repoRoot = (Get-RepoRoot).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($repoRoot.Length).TrimStart('\')
    }
    return $fullPath
}

function Get-LabIdFromSampleId {
    param([Parameter(Mandatory = $true)][string]$SampleId)

    if ($SampleId -match '^(\d+S\d+)') {
        return $Matches[1]
    }
    return $null
}

function Import-SampleSheetRows {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rows = Import-Csv -Path $Path -Delimiter "`t"
    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyName sample_sheet_path -NotePropertyValue $Path -Force
    }
    return $rows
}

$companyPath = Resolve-RepoPath -Path $CompanyResultsPath
$outputPath = Resolve-RepoPath -Path $OutputPath
$outputDir = Split-Path -Parent $outputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$sampleSheets = Get-ChildItem -Path (Resolve-RepoPath -Path $SampleSheetPattern) -ErrorAction Stop
$sampleRows = @()
foreach ($sheet in $sampleSheets) {
    $sampleRows += Import-SampleSheetRows -Path $sheet.FullName
}

$sampleByLabId = @{}
$familyStats = @{}
foreach ($row in $sampleRows) {
    $labId = Get-LabIdFromSampleId -SampleId ([string]$row.sample_id)
    if ([string]::IsNullOrWhiteSpace($labId)) {
        continue
    }

    if (-not $sampleByLabId.ContainsKey($labId)) {
        $sampleByLabId[$labId] = @()
    }
    $sampleByLabId[$labId] += $row

    $familyId = [string]$row.family_id
    if (-not $familyStats.ContainsKey($familyId)) {
        $familyStats[$familyId] = [ordered]@{
            sample_count = 0
            bam_ready_count = 0
            role_known_count = 0
            affected_positive_count = 0
        }
    }
    $familyStats[$familyId].sample_count += 1
    if (-not [string]::IsNullOrWhiteSpace([string]$row.bam_path)) {
        $familyStats[$familyId].bam_ready_count += 1
    }
    if ([string]$row.role -and [string]$row.role -ne 'unknown') {
        $familyStats[$familyId].role_known_count += 1
    }
    if ([string]$row.affected -eq '1') {
        $familyStats[$familyId].affected_positive_count += 1
    }
}

$labIndex = 3
$geneIndex = 5
$coordIndex = 7
$variantIndex = 8
$classIndex = 11
$conclusionIndex = 12
$nameIndex = 0
$relationIndex = 1

$currentLab = ''
$currentGene = ''
$currentCoord = ''
$currentVariant = ''
$currentClass = ''
$currentConclusion = ''
$currentName = ''
$currentRelation = ''

$results = New-Object System.Collections.Generic.List[object]
$seenKeys = New-Object System.Collections.Generic.HashSet[string]

$reader = [System.IO.File]::OpenText($companyPath)
try {
    $headerLine = $reader.ReadLine()
    if ($null -eq $headerLine) {
        throw "Company results file is empty: $companyPath"
    }

    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { continue }
        $cols = $line -split "`t", -1
        if ($cols.Count -le $conclusionIndex) {
            $expanded = New-Object string[] ($conclusionIndex + 1)
            for ($i = 0; $i -lt $expanded.Length; $i++) {
                $expanded[$i] = if ($i -lt $cols.Count) { $cols[$i] } else { "" }
            }
            $cols = $expanded
        }

        if (-not [string]::IsNullOrWhiteSpace($cols[$labIndex])) { $currentLab = $cols[$labIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$geneIndex])) { $currentGene = $cols[$geneIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$coordIndex])) { $currentCoord = $cols[$coordIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$variantIndex])) { $currentVariant = $cols[$variantIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$classIndex])) { $currentClass = $cols[$classIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$conclusionIndex])) { $currentConclusion = $cols[$conclusionIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$nameIndex])) { $currentName = $cols[$nameIndex].Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cols[$relationIndex])) { $currentRelation = $cols[$relationIndex].Trim() }

        $rowHasCoordinate = -not [string]::IsNullOrWhiteSpace($cols[$coordIndex]) -and $cols[$coordIndex].Trim() -ne '-'
        if (-not $rowHasCoordinate) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentLab) -or [string]::IsNullOrWhiteSpace($currentGene) -or [string]::IsNullOrWhiteSpace($currentCoord)) {
            continue
        }
        if (-not $sampleByLabId.ContainsKey($currentLab)) {
            continue
        }

        foreach ($sampleRow in $sampleByLabId[$currentLab]) {
            $familyId = [string]$sampleRow.family_id
            $stats = $familyStats[$familyId]
            $key = '{0}|{1}|{2}|{3}' -f $familyId, $currentLab, $currentGene, $currentCoord
            if (-not $seenKeys.Add($key)) {
                continue
            }

            $results.Add([pscustomobject]@{
                family_id = $familyId
                sample_sheet = (Get-RepoRelativePath -Path ([string]$sampleRow.sample_sheet_path))
                company_lab_id = $currentLab
                sample_id = [string]$sampleRow.sample_id
                company_name = $currentName
                company_relation = $currentRelation
                gene = $currentGene
                coordinate = $currentCoord
                variant = $currentVariant
                classification = $currentClass
                conclusion = $currentConclusion
                family_sample_count = $stats.sample_count
                family_bam_ready_count = $stats.bam_ready_count
                family_role_known_count = $stats.role_known_count
                family_affected_positive_count = $stats.affected_positive_count
            })
        }
    }
} finally {
    $reader.Close()
}

$results |
    Sort-Object family_id, company_lab_id, gene, coordinate |
    Export-Csv -Path $outputPath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation

Write-Host $outputPath
Write-Host ("family_count={0}" -f (@($results.family_id | Sort-Object -Unique).Count))
Write-Host ("record_count={0}" -f $results.Count)
