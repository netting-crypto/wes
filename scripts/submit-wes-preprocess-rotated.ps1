param(
    [string]$Branch = 'feat/wes-germline-skeleton',
    [string[]]$SampleSheets = @(
        'config/wes/samples.from-excel.remaining141.batch02.tsv',
        'config/wes/samples.from-excel.remaining141.batch03.tsv',
        'config/wes/samples.from-excel.remaining141.batch04.tsv',
        'config/wes/samples.from-excel.remaining141.batch05.tsv',
        'config/wes/samples.from-excel.remaining141.batch06.tsv'
    ),
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RequiredEnv {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable is missing: $Name"
    }
    return $value
}

function Get-RepoRoot {
    return Split-Path -Parent $PSScriptRoot
}

function Get-SubmissionRegistryPath {
    $registryDir = Join-Path (Get-RepoRoot) 'output\wes\submission-registry'
    if (-not (Test-Path $registryDir)) {
        New-Item -ItemType Directory -Force -Path $registryDir | Out-Null
    }
    return Join-Path $registryDir 'preprocess-rotated.jsonl'
}

function Append-SubmissionRegistry {
    param([psobject]$Record)

    $registryPath = Get-SubmissionRegistryPath
    ($Record | ConvertTo-Json -Compress -Depth 6) | Add-Content -Path $registryPath -Encoding UTF8
}

$apiBase = 'https://git.ustc.edu.cn/api/v4'
$projectPath = [uri]::EscapeDataString('luoxin23/wes')
$project = $null
$headers = $null
if (-not $DryRun) {
    $token = Get-RequiredEnv 'GITLAB_TOKEN'
    $headers = @{ 'PRIVATE-TOKEN' = $token }
    $project = Invoke-RestMethod -Headers $headers -Uri "$apiBase/projects/$projectPath"
}

$profiles = @(
    @{ Partition = 'CPU-64C256GB';  Qos = 'qos_cpu_64c256gb';  Cpu = '2'; Mem = '8G'; Concurrent = '4'; Job = 'pre-b64a' },
    @{ Partition = 'CPU-96C3TB';    Qos = 'qos_cpu_96c3tb';    Cpu = '2'; Mem = '8G'; Concurrent = '4'; Job = 'pre-b96a' },
    @{ Partition = 'CPU-192C768GB'; Qos = 'qos_cpu_192c768gb'; Cpu = '2'; Mem = '8G'; Concurrent = '4'; Job = 'pre-b192a' }
)

$results = @()
for ($i = 0; $i -lt $SampleSheets.Count; $i++) {
    $sheet = $SampleSheets[$i]
    $profile = $profiles[$i % $profiles.Count]
    $batchTag = [System.IO.Path]::GetFileNameWithoutExtension($sheet) -replace '^samples\.from-excel\.', ''

    $variables = @(
        @{ key = 'WES_MODE'; value = 'preprocess-batch' },
        @{ key = 'WES_SAMPLE_SHEET'; value = '$CI_PROJECT_DIR/' + $sheet },
        @{ key = 'WES_PIPELINE_STAGE'; value = 'preprocess' },
        @{ key = 'WES_PIPELINE_EXTRA_ARGS'; value = '--skip-bqsr --skip-fastqc' },
        @{ key = 'WES_SKIP_FASTQC'; value = '1' },
        @{ key = 'WES_SKIP_BQSR_PREPROCESS'; value = '1' },
        @{ key = 'WES_BATCH_MAX_CONCURRENT'; value = $profile.Concurrent },
        @{ key = 'SLURM_PARTITION'; value = $profile.Partition },
        @{ key = 'SLURM_QOS'; value = $profile.Qos },
        @{ key = 'SLURM_CPUS_PER_TASK'; value = $profile.Cpu },
        @{ key = 'SLURM_MEM'; value = $profile.Mem },
        @{ key = 'SLURM_TIME'; value = '48:00:00' },
        @{ key = 'SLURM_JOB_NAME'; value = "$($profile.Job)-$batchTag" }
    )

    if ($DryRun) {
        $results += [pscustomobject]@{
            sample_sheet = $sheet
            batch_tag = $batchTag
            partition = $profile.Partition
            qos = $profile.Qos
            cpu = $profile.Cpu
            mem = $profile.Mem
            concurrent = $profile.Concurrent
            dry_run = $true
        }
        continue
    }

    $payload = @{ ref = $Branch; variables = $variables }
    $response = Invoke-RestMethod -Method Post -Headers $headers -Uri "$apiBase/projects/$($project.id)/pipeline" -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 6)
    $record = [pscustomobject]@{
        submitted_at = (Get-Date).ToString('o')
        branch = $Branch
        sample_sheet = $sheet
        batch_tag = $batchTag
        partition = $profile.Partition
        qos = $profile.Qos
        cpu = $profile.Cpu
        mem = $profile.Mem
        concurrent = $profile.Concurrent
        pipeline_id = $response.id
        web_url = $response.web_url
        status = $response.status
    }
    $results += $record
    Append-SubmissionRegistry -Record $record
}

if ($Json) {
    $results | ConvertTo-Json -Depth 6
} else {
    $results | Format-Table -AutoSize
}
