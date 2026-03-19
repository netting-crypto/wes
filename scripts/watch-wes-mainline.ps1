param(
    [string]$ConfigPath = "config/wes/mainline-controller.json",
    [int]$PollIntervalSeconds = 600,
    [switch]$RunOnce,
    [int]$MaxIterations = 0
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}

function Get-RequiredEnv {
    param([Parameter(Mandatory = $true)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, "User")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable is missing: $Name"
    }
    return $value
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Invoke-GitLabApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST")] [string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body
    )

    $headers = @{ "PRIVATE-TOKEN" = (Get-RequiredEnv -Name "GITLAB_TOKEN") }
    if ($PSBoundParameters.ContainsKey("Body")) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body $Body
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Load-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-Content -Raw -Path $Path -Encoding UTF8 | ConvertFrom-Json
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $Value | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $null
}

function Get-ProjectId {
    param([Parameter(Mandatory = $true)][psobject]$Config)
    $encoded = [System.Uri]::EscapeDataString([string]$Config.project_path)
    $project = Invoke-GitLabApi -Method GET -Uri "$($Config.api_base)/projects/$encoded"
    return [int]$project.id
}

function Get-Pipeline {
    param(
        [Parameter(Mandatory = $true)][psobject]$Config,
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)][int]$PipelineId
    )
    return Invoke-GitLabApi -Method GET -Uri "$($Config.api_base)/projects/$ProjectId/pipelines/$PipelineId"
}

function Get-StageState {
    param(
        [Parameter(Mandatory = $true)][psobject]$FamilyState,
        [Parameter(Mandatory = $true)][string]$StageName
    )
    return @($FamilyState.stages | Where-Object { $_.name -eq $StageName })[0]
}

function Submit-Stage {
    param(
        [Parameter(Mandatory = $true)][psobject]$Config,
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)][psobject]$FamilyState,
        [Parameter(Mandatory = $true)][psobject]$StageState
    )

    $variables = @()
    $variables += @{ key = "WES_SAMPLE_SHEET"; value = '$CI_PROJECT_DIR/' + [string]$FamilyState.sample_sheet }
    $variables += @{ key = "SLURM_PARTITION"; value = [string]$StageState.resources.partition }
    $variables += @{ key = "SLURM_QOS"; value = [string]$StageState.resources.qos }
    $variables += @{ key = "SLURM_CPUS_PER_TASK"; value = [string]$StageState.resources.cpus }
    $variables += @{ key = "SLURM_MEM"; value = [string]$StageState.resources.mem }
    $variables += @{ key = "SLURM_TIME"; value = [string]$StageState.resources.time }
    $variables += @{ key = "SLURM_JOB_NAME"; value = [string]$StageState.resources.job_name }
    $variables += @{ key = "WES_SKIP_FASTQC"; value = "1" }
    $variables += @{ key = "WES_SKIP_BQSR_PREPROCESS"; value = "1" }

    if ([string]$StageState.mode -eq "preprocess-batch") {
        $variables += @{ key = "WES_MODE"; value = "preprocess-batch" }
        $variables += @{ key = "WES_PIPELINE_STAGE"; value = "preprocess" }
        $variables += @{ key = "WES_PIPELINE_EXTRA_ARGS"; value = "--skip-bqsr --skip-fastqc" }
        $variables += @{ key = "WES_BATCH_MAX_CONCURRENT"; value = [string]$StageState.resources.concurrent }
    } elseif ([string]$StageState.mode -eq "pipeline") {
        $variables += @{ key = "WES_MODE"; value = "pipeline" }
        $variables += @{ key = "WES_STAGE_OUT_DIR"; value = [string]$StageState.stage_out_dir }
        $variables += @{ key = "WES_PIPELINE_STAGE"; value = [string]$StageState.pipeline_stage }
        $variables += @{ key = "WES_PIPELINE_EXTRA_ARGS"; value = "--skip-bqsr --skip-fastqc" }
    } else {
        throw "Unsupported stage mode: $($StageState.mode)"
    }

    $body = @{
        ref = [string]$Config.branch
        variables = $variables
    } | ConvertTo-Json -Depth 8

    return Invoke-GitLabApi -Method POST -Uri "$($Config.api_base)/projects/$ProjectId/pipeline" -Body $body
}

function Invoke-Diagnosis {
    param([Parameter(Mandatory = $true)][int]$PipelineId)
    & "$PSScriptRoot\diagnose-wes-pipeline.ps1" -PipelineId $PipelineId -DownloadTrace -DownloadArtifacts | Out-Null
    $path = Join-Path (Get-RepoRoot) ("output\wes\gitlab-status\pipeline-{0}-diagnosis.json" -f $PipelineId)
    if (Test-Path $path) {
        return Load-JsonFile -Path $path
    }
    return $null
}

function Initialize-State {
    param([Parameter(Mandatory = $true)][psobject]$Config)

    $families = @()
    foreach ($family in $Config.families) {
        $stageStates = @()
        foreach ($stage in $family.stages) {
            $stageStates += [pscustomobject]@{
                name = [string]$stage.name
                mode = [string]$stage.mode
                pipeline_stage = [string](Get-OptionalProperty -Object $stage -Name "pipeline_stage")
                stage_out_dir = [string](Get-OptionalProperty -Object $stage -Name "stage_out_dir")
                auto_advance_to = [string](Get-OptionalProperty -Object $stage -Name "auto_advance_to")
                resources = $stage.resources
                active_pipeline_id = Get-OptionalProperty -Object $stage -Name "active_pipeline_id"
                last_terminal_pipeline_id = $null
                last_terminal_status = $null
                last_failure_code = $null
                last_failure_summary = $null
                retry_count = 0
                completed = $false
                last_seen_status = $null
                last_seen_at = $null
            }
        }

        $families += [pscustomobject]@{
            family_id = [string]$family.family_id
            sample_sheet = [string]$family.sample_sheet
            stages = $stageStates
        }
    }

    return [pscustomobject]@{
        generated_from = [string]$ConfigPath
        updated_at = (Get-Date).ToString("o")
        pending_actions = @()
        action_log = @()
        families = $families
    }
}

function Add-PendingAction {
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$FamilyId,
        [Parameter(Mandatory = $true)][string]$StageName,
        [Parameter(Mandatory = $true)][int]$PipelineId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$Summary
    )

    $State.pending_actions += [pscustomobject]@{
        created_at = (Get-Date).ToString("o")
        family_id = $FamilyId
        stage = $StageName
        pipeline_id = $PipelineId
        reason = $Reason
        summary = $Summary
    }
}

function Write-Summary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][psobject]$State
    )

    $lines = @()
    $lines += "# WES Mainline Controller"
    $lines += ""
    $lines += "- updated_at: $($State.updated_at)"
    $lines += ""
    $lines += "## Families"
    foreach ($family in $State.families) {
        $lines += ""
        $lines += "### $($family.family_id)"
        foreach ($stage in $family.stages) {
            $active = if ($null -ne $stage.active_pipeline_id) { [string]$stage.active_pipeline_id } else { "-" }
            $lines += "- $($stage.name): active=$active last_seen=$($stage.last_seen_status) terminal=$($stage.last_terminal_status) retry_count=$($stage.retry_count) completed=$($stage.completed)"
        }
    }
    $lines += ""
    $lines += "## Pending Actions"
    if (@($State.pending_actions).Count -eq 0) {
        $lines += "- none"
    } else {
        foreach ($item in $State.pending_actions) {
            $lines += "- [$($item.family_id) / $($item.stage) / pipeline $($item.pipeline_id)] $($item.reason): $($item.summary)"
        }
    }
    $lines += ""
    $lines += "## Action Log"
    if (@($State.action_log).Count -eq 0) {
        $lines += "- none"
    } else {
        foreach ($item in $State.action_log | Select-Object -Last 20) {
            $lines += "- $($item.at): $($item.action)"
        }
    }

    $lines | Set-Content -Path $Path -Encoding UTF8
}

$repoRoot = Get-RepoRoot
$resolvedConfigPath = Join-Path $repoRoot $ConfigPath
$config = Load-JsonFile -Path $resolvedConfigPath
$projectId = Get-ProjectId -Config $config

$controllerDir = Join-Path $repoRoot "output\wes\controller"
Ensure-Directory -Path $controllerDir
$statePath = Join-Path $controllerDir "mainline-state.json"
$summaryPath = Join-Path $controllerDir "mainline-summary.md"

if (Test-Path $statePath) {
    $state = Load-JsonFile -Path $statePath
} else {
    $state = Initialize-State -Config $config
}

$terminalStates = @("success", "failed", "canceled", "skipped", "manual")
$iteration = 0

do {
    $state.updated_at = (Get-Date).ToString("o")

    foreach ($family in $state.families) {
        foreach ($stage in $family.stages) {
            if ($null -eq $stage.active_pipeline_id) {
                continue
            }

            $pipeline = Get-Pipeline -Config $config -ProjectId $projectId -PipelineId ([int]$stage.active_pipeline_id)
            $stage.last_seen_status = [string]$pipeline.status
            $stage.last_seen_at = (Get-Date).ToString("o")

            if ($terminalStates -notcontains [string]$pipeline.status) {
                continue
            }

            $currentPipelineId = [int]$stage.active_pipeline_id
            $stage.last_terminal_pipeline_id = $currentPipelineId
            $stage.last_terminal_status = [string]$pipeline.status
            $stage.active_pipeline_id = $null

            if ([string]$pipeline.status -eq "success") {
                $stage.completed = $true
                $state.action_log += [pscustomobject]@{
                    at = (Get-Date).ToString("o")
                    action = "success: $($family.family_id) / $($stage.name) / pipeline $currentPipelineId"
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$stage.auto_advance_to)) {
                    $nextStage = Get-StageState -FamilyState $family -StageName ([string]$stage.auto_advance_to)
                    if ($null -ne $nextStage -and $null -eq $nextStage.active_pipeline_id -and -not $nextStage.completed) {
                        $submission = Submit-Stage -Config $config -ProjectId $projectId -FamilyState $family -StageState $nextStage
                        $nextStage.active_pipeline_id = [int]$submission.id
                        $nextStage.last_seen_status = [string]$submission.status
                        $nextStage.last_seen_at = (Get-Date).ToString("o")
                        $state.action_log += [pscustomobject]@{
                            at = (Get-Date).ToString("o")
                            action = "auto-advance: $($family.family_id) -> $($nextStage.name) / pipeline $($submission.id)"
                        }
                    }
                }
            } else {
                $diagnosis = Invoke-Diagnosis -PipelineId $currentPipelineId
                if ($null -ne $diagnosis) {
                    $stage.last_failure_code = [string]$diagnosis.failure_code
                    $stage.last_failure_summary = [string]$diagnosis.summary
                }

                $canRetry = $false
                if ($null -ne $diagnosis) {
                    $allowedCodes = @($config.auto_retry_failure_codes)
                    if ($allowedCodes -contains [string]$diagnosis.failure_code -and [int]$stage.retry_count -lt [int]$config.max_auto_retries_per_stage) {
                        $canRetry = $true
                    }
                }

                if ($canRetry) {
                    $submission = Submit-Stage -Config $config -ProjectId $projectId -FamilyState $family -StageState $stage
                    $stage.retry_count = [int]$stage.retry_count + 1
                    $stage.active_pipeline_id = [int]$submission.id
                    $stage.last_seen_status = [string]$submission.status
                    $stage.last_seen_at = (Get-Date).ToString("o")
                    $state.action_log += [pscustomobject]@{
                        at = (Get-Date).ToString("o")
                        action = "auto-retry: $($family.family_id) / $($stage.name) / old $currentPipelineId -> new $($submission.id)"
                    }
                } else {
                    Add-PendingAction -State $state -FamilyId ([string]$family.family_id) -StageName ([string]$stage.name) -PipelineId $currentPipelineId -Reason ([string]($diagnosis.failure_code)) -Summary ([string]($diagnosis.summary))
                    $state.action_log += [pscustomobject]@{
                        at = (Get-Date).ToString("o")
                        action = "pending: $($family.family_id) / $($stage.name) / pipeline $currentPipelineId"
                    }
                }
            }
        }
    }

    Save-JsonFile -Path $statePath -Value $state
    Write-Summary -Path $summaryPath -State $state
    Write-Host "Controller snapshot written: $summaryPath"

    $iteration += 1
    if ($RunOnce) { break }
    if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) { break }
    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)
