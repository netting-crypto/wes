param(
    [string]$Branch = 'codex/fam22-rescue-retry',
    [string[]]$Families = @(),
    [string]$ControllerConfigPath = 'config/wes/mainline-controller.json',
    [string]$CompanyTargetsPath = 'config/wes/company-family-targets.tsv',
    [string]$ExtraIntervalBedPath = 'config/wes/company-hotspots.bed',
    [switch]$DryRun,
    [switch]$Json
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

function Get-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $repoRoot = (Get-RepoRoot).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($repoRoot.Length).TrimStart('\')
    }
    return $fullPath
}

function Get-RequiredEnv {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable is missing: $Name"
    }
    return $value
}

function Get-SubmissionRegistryPath {
    $registryDir = Join-Path (Get-RepoRoot) 'output\wes\submission-registry'
    if (-not (Test-Path $registryDir)) {
        New-Item -ItemType Directory -Force -Path $registryDir | Out-Null
    }
    return Join-Path $registryDir 'family-rescue.jsonl'
}

function Append-SubmissionRegistry {
    param([psobject]$Record)

    ($Record | ConvertTo-Json -Compress -Depth 8) | Add-Content -Path (Get-SubmissionRegistryPath) -Encoding UTF8
}

function Get-ProjectId {
    $apiBase = 'https://git.ustc.edu.cn/api/v4'
    $projectPath = [uri]::EscapeDataString('luoxin23/wes')
    $headers = @{ 'PRIVATE-TOKEN' = (Get-RequiredEnv -Name 'GITLAB_TOKEN') }
    $project = Invoke-RestMethod -Headers $headers -Uri "$apiBase/projects/$projectPath"
    return [int]$project.id
}

$repoRoot = Get-RepoRoot
$config = Get-Content -Raw (Resolve-RepoPath -Path $ControllerConfigPath) | ConvertFrom-Json
$targets = Import-Csv -Path (Resolve-RepoPath -Path $CompanyTargetsPath) -Delimiter "`t"
$extraBedRepoPath = Get-RepoRelativePath -Path (Resolve-RepoPath -Path $ExtraIntervalBedPath)

$selectedFamilies = if ($Families.Count -gt 0) {
    $Families
} else {
    @($targets.family_id | Sort-Object -Unique)
}

$headers = $null
$projectId = $null
if (-not $DryRun) {
    $headers = @{ 'PRIVATE-TOKEN' = (Get-RequiredEnv -Name 'GITLAB_TOKEN') }
    $projectId = Get-ProjectId
}

$results = @()
foreach ($familyId in $selectedFamilies) {
    $familyConfig = @($config.families | Where-Object { $_.family_id -eq $familyId })[0]
    if ($null -eq $familyConfig) {
        Write-Warning "Skip ${familyId}: not found in controller config"
        continue
    }

    $familyTargets = @($targets | Where-Object { $_.family_id -eq $familyId })
    if ($familyTargets.Count -eq 0) {
        Write-Warning "Skip ${familyId}: no company loci mapped to current sample sheets"
        continue
    }

    $compareStage = @($familyConfig.stages | Where-Object { $_.name -eq 'compare' })[0]
    if ($null -eq $compareStage) {
        Write-Warning "Skip ${familyId}: compare stage missing in controller config"
        continue
    }

    $sampleSheet = [string]$familyConfig.sample_sheet
    $rescueOutDir = ([string]$compareStage.stage_out_dir).TrimEnd('/') + '-rescue-bed500'
    $jobName = ([string]$compareStage.resources.job_name) + '-r500'
    $familySampleRows = Import-Csv -Path (Resolve-RepoPath -Path $sampleSheet) -Delimiter "`t"
    $bamReadyCount = @($familySampleRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.bam_path) }).Count

    $variables = @(
        @{ key = 'WES_MODE'; value = 'pipeline' },
        @{ key = 'WES_SAMPLE_SHEET'; value = '$CI_PROJECT_DIR/' + $sampleSheet.Replace('\', '/') },
        @{ key = 'WES_PIPELINE_STAGE'; value = 'all' },
        @{ key = 'WES_PIPELINE_EXTRA_ARGS'; value = '--skip-bqsr --skip-fastqc' },
        @{ key = 'WES_STAGE_OUT_DIR'; value = $rescueOutDir },
        @{ key = 'WES_EXTRA_INTERVAL_BED'; value = '$CI_PROJECT_DIR/' + $extraBedRepoPath.Replace('\', '/') },
        @{ key = 'WES_SKIP_FASTQC'; value = '1' },
        @{ key = 'WES_SKIP_BQSR_PREPROCESS'; value = '1' },
        @{ key = 'SLURM_PARTITION'; value = [string]$compareStage.resources.partition },
        @{ key = 'SLURM_QOS'; value = [string]$compareStage.resources.qos },
        @{ key = 'SLURM_CPUS_PER_TASK'; value = [string]$compareStage.resources.cpus },
        @{ key = 'SLURM_MEM'; value = [string]$compareStage.resources.mem },
        @{ key = 'SLURM_TIME'; value = [string]$compareStage.resources.time },
        @{ key = 'SLURM_JOB_NAME'; value = $jobName }
    )

    if ($DryRun) {
        $results += [pscustomobject]@{
            family_id = $familyId
            sample_sheet = $sampleSheet
            rescue_out_dir = $rescueOutDir
            company_locus_count = $familyTargets.Count
            bam_ready_count = $bamReadyCount
            sample_count = $familySampleRows.Count
            branch = $Branch
            dry_run = $true
        }
        continue
    }

    $payload = @{ ref = $Branch; variables = $variables }
    $response = Invoke-RestMethod -Method Post -Headers $headers -Uri "https://git.ustc.edu.cn/api/v4/projects/$projectId/pipeline" -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 8)
    $record = [pscustomobject]@{
        submitted_at = (Get-Date).ToString('o')
        family_id = $familyId
        branch = $Branch
        sample_sheet = $sampleSheet
        rescue_out_dir = $rescueOutDir
        company_locus_count = $familyTargets.Count
        bam_ready_count = $bamReadyCount
        sample_count = $familySampleRows.Count
        pipeline_id = $response.id
        web_url = $response.web_url
        status = $response.status
    }
    $results += $record
    Append-SubmissionRegistry -Record $record
}

if ($Json) {
    $results | ConvertTo-Json -Depth 8
} else {
    $results | Format-Table -AutoSize
}
