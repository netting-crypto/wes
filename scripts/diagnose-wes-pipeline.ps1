param(
    [Parameter(Mandatory = $true)]
    [int]$PipelineId,
    [int]$JobId = 0,
    [string]$RepoRoot = "",
    [string]$StatusDir = "",
    [switch]$DownloadTrace,
    [switch]$DownloadArtifacts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $argString = ($Args | ForEach-Object {
            if ($_ -match '\s|"') {
                '"' + ($_ -replace '"', '\"') + '"'
            } else {
                $_
            }
        }) -join ' '

        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/d /c git $argString" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path $stdoutPath) { [string](Get-Content -Raw -Path $stdoutPath) } else { "" }
        $stderr = if (Test-Path $stderrPath) { [string](Get-Content -Raw -Path $stderrPath) } else { "" }
        $stdoutText = if ([string]::IsNullOrEmpty($stdout)) { "" } else { $stdout.TrimEnd() }
        $stderrText = if ([string]::IsNullOrEmpty($stderr)) { "" } else { $stderr.TrimEnd() }
        $combined = [string]((@($stdoutText, $stderrText) | Where-Object { $_ }) -join [Environment]::NewLine)

        if ($process.ExitCode -ne 0) {
            throw "git $($Args -join ' ') failed:`n$combined"
        }
        return [string]$combined
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
    }
}

function Get-RequiredEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "User")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable is missing: $Name"
    }
    return $value
}

function Get-ProjectPathFromRemote {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    if ($RemoteUrl -match 'https?://[^/]+/(.+?)(?:\.git)?$') {
        return $Matches[1]
    }
    if ($RemoteUrl -match '^[^@]+@[^:]+:(.+?)(?:\.git)?$') {
        return $Matches[1]
    }
    throw "Unsupported git remote URL: $RemoteUrl"
}

function Get-ApiBaseFromRemote {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    if ($RemoteUrl -match '^https?://') {
        $uri = [System.Uri]$RemoteUrl
        return "{0}://{1}/api/v4" -f $uri.Scheme, $uri.Authority
    }
    if ($RemoteUrl -match '^[^@]+@([^:]+):') {
        return "https://$($Matches[1])/api/v4"
    }
    throw "Unsupported git remote URL: $RemoteUrl"
}

function Invoke-GitLabApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET")]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $token = Get-RequiredEnv -Name "GITLAB_TOKEN"
    $headers = @{ "PRIVATE-TOKEN" = $token }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Get-RepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-Path $RepoRoot).Path
    }
    return (Get-Location).Path
}

function Get-StatusDirPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedRepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($StatusDir)) {
        return (Resolve-Path $StatusDir).Path
    }

    $path = Join-Path $ResolvedRepoRoot "output\wes\gitlab-status"
    if (!(Test-Path $path)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    return $path
}

function Get-TextIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path $Path) {
        return [string](Get-Content -Raw -Path $Path -Encoding UTF8)
    }
    return ""
}

function Parse-KeyValueText {
    param(
        [string]$Text
    )

    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $result
    }

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([^=]+)=(.*)$') {
            $result[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    return $result
}

function Normalize-ToArray {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value)
    }
    return @($Value)
}

function Save-PipelineSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedStatusDir,
        [Parameter(Mandatory = $true)]
        [int]$CurrentPipelineId,
        [Parameter(Mandatory = $true)]
        [psobject]$Snapshot
    )

    $jsonPath = Join-Path $ResolvedStatusDir "pipeline-$CurrentPipelineId.json"
    $txtPath = Join-Path $ResolvedStatusDir "pipeline-$CurrentPipelineId.txt"

    $Snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @()
    $lines += "pipeline_id=$CurrentPipelineId"
    $lines += "status=$($Snapshot.Pipeline.status)"
    $lines += "web_url=$($Snapshot.Pipeline.web_url)"
    $lines += "updated_at=$($Snapshot.Pipeline.updated_at)"
    $lines += ""
    $lines += "jobs:"
    foreach ($job in (Normalize-ToArray $Snapshot.Jobs | Sort-Object id)) {
        $lines += "[$($job.status)] stage=$($job.stage) name=$($job.name) id=$($job.id) web_url=$($job.web_url)"
    }
    $lines | Set-Content -Path $txtPath -Encoding UTF8

    return [pscustomobject]@{
        JsonPath = $jsonPath
        TextPath = $txtPath
    }
}

function Get-PipelineSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedRepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedStatusDir,
        [Parameter(Mandatory = $true)]
        [int]$CurrentPipelineId
    )

    $jsonPath = Join-Path $ResolvedStatusDir "pipeline-$CurrentPipelineId.json"
    if (Test-Path $jsonPath) {
        return Get-Content -Raw -Path $jsonPath -Encoding UTF8 | ConvertFrom-Json
    }

    $remoteUrl = [string]::Concat((Invoke-Git -Args @("remote", "get-url", "origin"))).Trim()
    $projectPath = Get-ProjectPathFromRemote -RemoteUrl $remoteUrl
    $apiBase = Get-ApiBaseFromRemote -RemoteUrl $remoteUrl
    $encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)
    $project = Invoke-GitLabApi -Method GET -Uri "$apiBase/projects/$encodedProjectPath"
    $pipeline = Invoke-GitLabApi -Method GET -Uri "$apiBase/projects/$($project.id)/pipelines/$CurrentPipelineId"
    $jobsResponse = Invoke-GitLabApi -Method GET -Uri "$apiBase/projects/$($project.id)/pipelines/$CurrentPipelineId/jobs?per_page=100"
    $jobs = Normalize-ToArray $jobsResponse

    $snapshot = [pscustomobject]@{
        Pipeline = $pipeline
        Jobs = $jobs
    }

    Save-PipelineSnapshot -ResolvedStatusDir $ResolvedStatusDir -CurrentPipelineId $CurrentPipelineId -Snapshot $snapshot | Out-Null
    return $snapshot
}

function Resolve-TargetJob {
    param(
        [int]$RequestedJobId,
        [psobject]$Snapshot
    )

    if ($RequestedJobId -gt 0) {
        $job = Normalize-ToArray $Snapshot.Jobs | Where-Object { [int]$_.id -eq $RequestedJobId } | Select-Object -First 1
        if ($null -ne $job) {
            return $job
        }

        return [pscustomobject]@{
            id = $RequestedJobId
            status = ""
            stage = ""
            name = ""
            web_url = ""
        }
    }

    $jobs = @(Normalize-ToArray $Snapshot.Jobs)
    if ($jobs.Count -eq 0) {
        return $null
    }

    $preferred = $jobs |
        Where-Object { $_.status -in @("failed", "canceled", "manual") } |
        Sort-Object id -Descending |
        Select-Object -First 1
    if ($null -ne $preferred) {
        return $preferred
    }

    return $jobs | Sort-Object id -Descending | Select-Object -First 1
}

function Ensure-JobTrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedStatusDir,
        [Parameter(Mandatory = $true)]
        [int]$CurrentJobId,
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $tracePath = Join-Path $ResolvedStatusDir "job-$CurrentJobId-trace.log"
    if ((Test-Path $tracePath) -and -not $DownloadTrace) {
        return $tracePath
    }

    if ($CurrentJobId -le 0) {
        return $tracePath
    }

    $projectPath = Get-ProjectPathFromRemote -RemoteUrl $RemoteUrl
    $apiBase = Get-ApiBaseFromRemote -RemoteUrl $RemoteUrl
    $encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)
    $project = Invoke-GitLabApi -Method GET -Uri "$apiBase/projects/$encodedProjectPath"
    $traceUri = "$apiBase/projects/$($project.id)/jobs/$CurrentJobId/trace"
    $token = Get-RequiredEnv -Name "GITLAB_TOKEN"
    $headers = @{ "PRIVATE-TOKEN" = $token }
    Invoke-RestMethod -Headers $headers -Uri $traceUri -OutFile $tracePath
    return $tracePath
}

function Ensure-JobArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedStatusDir,
        [Parameter(Mandatory = $true)]
        [int]$CurrentJobId,
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $artifactDir = Join-Path $ResolvedStatusDir "job-$CurrentJobId-artifacts"
    if (Test-Path $artifactDir) {
        return $artifactDir
    }

    $legacyArtifactDir = Join-Path $ResolvedStatusDir "artifacts-$CurrentJobId"
    if (Test-Path $legacyArtifactDir) {
        return $legacyArtifactDir
    }

    $zipPath = Join-Path $ResolvedStatusDir "job-$CurrentJobId-artifacts.zip"
    if ((Test-Path $zipPath) -and -not $DownloadArtifacts) {
        Expand-Archive -Path $zipPath -DestinationPath $artifactDir -Force
        return $artifactDir
    }

    if (-not $DownloadArtifacts -and !(Test-Path $zipPath)) {
        return $artifactDir
    }

    if ($CurrentJobId -le 0) {
        return $artifactDir
    }

    $projectPath = Get-ProjectPathFromRemote -RemoteUrl $RemoteUrl
    $apiBase = Get-ApiBaseFromRemote -RemoteUrl $RemoteUrl
    $encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)
    $project = Invoke-GitLabApi -Method GET -Uri "$apiBase/projects/$encodedProjectPath"
    $artifactUri = "$apiBase/projects/$($project.id)/jobs/$CurrentJobId/artifacts"
    $token = Get-RequiredEnv -Name "GITLAB_TOKEN"
    $headers = @{ "PRIVATE-TOKEN" = $token }
    Invoke-RestMethod -Headers $headers -Uri $artifactUri -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $artifactDir -Force
    return $artifactDir
}

function Get-Excerpt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$Head = 30,
        [int]$Tail = 120
    )

    if (!(Test-Path $Path)) {
        return ""
    }

    $headLines = @(Get-Content -Path $Path -Encoding UTF8 -TotalCount $Head)
    $tailLines = @(Get-Content -Path $Path -Encoding UTF8 -Tail $Tail)
    $combined = @()
    $combined += $headLines
    $combined += "..."
    $combined += $tailLines
    return [string]($combined -join [Environment]::NewLine)
}

function Get-SampleIdFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $match = [regex]::Match($Text, '(?m)^sample_id=(.+)$')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return ""
}

function Get-JsonPathFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $match = [regex]::Match($Text, '([A-Za-z]:\\[^\r\n''"]+\.json|/[^\s\r\n''"]+\.json)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function New-Diagnosis {
    param(
        [string]$Layer,
        [string]$FailureCode,
        [string]$Decision,
        [bool]$SafeToResubmit,
        [bool]$RequiresModelFix,
        [string]$RetryScope,
        [string]$Summary,
        [string]$StopReason,
        [string]$SampleId,
        [string]$SlurmJobId,
        [string[]]$EvidencePaths,
        [bool]$NeedsNotification,
        [string]$NotificationTitle,
        [string]$NotificationMessage,
        [string]$PipelineStatus,
        [string]$JobStatus,
        [string]$JobName,
        [string]$JobStage,
        [string]$PipelineUrl,
        [string]$JobUrl
    )

    return [pscustomobject]@{
        pipeline_id = $PipelineId
        pipeline_status = $PipelineStatus
        pipeline_url = $PipelineUrl
        job_id = if ($JobId -gt 0) { $JobId } else { $null }
        job_status = $JobStatus
        job_name = $JobName
        job_stage = $JobStage
        job_url = $JobUrl
        layer = $Layer
        failure_code = $FailureCode
        decision = $Decision
        safe_to_resubmit = $SafeToResubmit
        requires_model_fix = $RequiresModelFix
        retry_scope = $RetryScope
        summary = $Summary
        stop_reason = $StopReason
        sample_id = $SampleId
        slurm_job_id = $SlurmJobId
        needs_notification = $NeedsNotification
        notification_title = $NotificationTitle
        notification_message = $NotificationMessage
        evidence_paths = @(
            $EvidencePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } |
            Select-Object -Unique
        )
        generated_at = (Get-Date).ToString("o")
    }
}

function New-NotificationDraft {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Diagnosis
    )

    return [pscustomobject]@{
        pipeline_id = $Diagnosis.pipeline_id
        job_id = $Diagnosis.job_id
        layer = $Diagnosis.layer
        failure_code = $Diagnosis.failure_code
        title = $Diagnosis.notification_title
        message = $Diagnosis.notification_message
        evidence_paths = $Diagnosis.evidence_paths
        generated_at = (Get-Date).ToString("o")
    }
}

function Find-FirstMatch {
    param(
        [object[]]$Entries,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        return $null
    }

    foreach ($entry in $Entries) {
        foreach ($pattern in $Patterns) {
            if ($entry.Text -match $pattern) {
                return $entry
            }
        }
    }
    return $null
}

function Render-Markdown {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Diagnosis
    )

    $lines = @()
    $lines += "# WES Pipeline Diagnosis"
    $lines += ""
    $lines += "- pipeline_id: $($Diagnosis.pipeline_id)"
    $lines += "- pipeline_status: $($Diagnosis.pipeline_status)"
    $lines += "- layer: $($Diagnosis.layer)"
    $lines += "- failure_code: $($Diagnosis.failure_code)"
    $lines += "- decision: $($Diagnosis.decision)"
    $lines += "- safe_to_resubmit: $($Diagnosis.safe_to_resubmit)"
    $lines += "- requires_model_fix: $($Diagnosis.requires_model_fix)"
    $lines += "- retry_scope: $($Diagnosis.retry_scope)"
    $lines += "- needs_notification: $($Diagnosis.needs_notification)"
    if (-not [string]::IsNullOrWhiteSpace([string]$Diagnosis.job_id)) {
        $lines += "- job_id: $($Diagnosis.job_id)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Diagnosis.slurm_job_id)) {
        $lines += "- slurm_job_id: $($Diagnosis.slurm_job_id)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Diagnosis.sample_id)) {
        $lines += "- sample_id: $($Diagnosis.sample_id)"
    }
    $lines += "- summary: $($Diagnosis.summary)"
    $lines += "- stop_reason: $($Diagnosis.stop_reason)"
    if ($Diagnosis.needs_notification) {
        $lines += "- notification_title: $($Diagnosis.notification_title)"
        $lines += "- notification_message: $($Diagnosis.notification_message)"
    }
    $lines += ""
    $lines += "## Evidence"
    foreach ($path in $Diagnosis.evidence_paths) {
        $lines += "- $path"
    }
    $lines += ""
    $lines += "## Links"
    if (-not [string]::IsNullOrWhiteSpace($Diagnosis.pipeline_url)) {
        $lines += "- pipeline_url: $($Diagnosis.pipeline_url)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Diagnosis.job_url)) {
        $lines += "- job_url: $($Diagnosis.job_url)"
    }

    return [string]($lines -join [Environment]::NewLine)
}

$resolvedRepoRoot = Get-RepoRoot
Set-Location -Path $resolvedRepoRoot
$resolvedStatusDir = Get-StatusDirPath -ResolvedRepoRoot $resolvedRepoRoot
$remoteUrl = [string]::Concat((Invoke-Git -Args @("remote", "get-url", "origin"))).Trim()
$snapshot = Get-PipelineSnapshot -ResolvedRepoRoot $resolvedRepoRoot -ResolvedStatusDir $resolvedStatusDir -CurrentPipelineId $PipelineId
$pipeline = $snapshot.Pipeline
$targetJob = Resolve-TargetJob -RequestedJobId $JobId -Snapshot $snapshot

if ($null -eq $targetJob) {
    throw "No jobs were found for pipeline $PipelineId"
}

$JobId = if ($targetJob.PSObject.Properties.Name -contains "id") { [int]$targetJob.id } else { $JobId }

$tracePath = ""
if ($JobId -gt 0) {
    $tracePath = Ensure-JobTrace -ResolvedStatusDir $resolvedStatusDir -CurrentJobId $JobId -RemoteUrl $remoteUrl
}

$artifactDir = ""
if ($JobId -gt 0) {
    $artifactDir = Ensure-JobArtifacts -ResolvedStatusDir $resolvedStatusDir -CurrentJobId $JobId -RemoteUrl $remoteUrl
}

$traceText = if (-not [string]::IsNullOrWhiteSpace($tracePath)) { Get-TextIfExists -Path $tracePath } else { "" }
$manifestPath = if (-not [string]::IsNullOrWhiteSpace($artifactDir)) { Join-Path $artifactDir "output\wes\result-manifest.txt" } else { "" }
if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and !(Test-Path $manifestPath)) {
    $manifestPath = if (-not [string]::IsNullOrWhiteSpace($artifactDir)) { Join-Path $artifactDir "result-manifest.txt" } else { "" }
}
$failureSummaryPath = if (-not [string]::IsNullOrWhiteSpace($artifactDir)) { Join-Path $artifactDir "output\wes\failed-task-summary.txt" } else { "" }
if (-not [string]::IsNullOrWhiteSpace($failureSummaryPath) -and !(Test-Path $failureSummaryPath)) {
    $failureSummaryPath = if (-not [string]::IsNullOrWhiteSpace($artifactDir)) { Join-Path $artifactDir "failed-task-summary.txt" } else { "" }
}

$manifestText = if (-not [string]::IsNullOrWhiteSpace($manifestPath)) { Get-TextIfExists -Path $manifestPath } else { "" }
$failureSummaryText = if (-not [string]::IsNullOrWhiteSpace($failureSummaryPath)) { Get-TextIfExists -Path $failureSummaryPath } else { "" }
$manifest = Parse-KeyValueText -Text $manifestText

$logEntries = @()
if (-not [string]::IsNullOrWhiteSpace($artifactDir)) {
    $candidateFiles = @()
    $candidateFiles += Get-ChildItem -Path $artifactDir -Recurse -File -Filter "*.log" -ErrorAction SilentlyContinue
    $candidateFiles += Get-ChildItem -Path $artifactDir -Recurse -File -Filter "*.out" -ErrorAction SilentlyContinue
    $candidateFiles += Get-ChildItem -Path $artifactDir -Recurse -File -Filter "*.err" -ErrorAction SilentlyContinue
    foreach ($file in ($candidateFiles | Sort-Object FullName -Unique)) {
        $excerpt = Get-Excerpt -Path $file.FullName
        $logEntries += [pscustomobject]@{
            Path = $file.FullName
            Text = $excerpt
            SampleId = Get-SampleIdFromText -Text $excerpt
        }
    }
}

$pipelineStatus = [string]$pipeline.status
$jobStatus = if ($targetJob.PSObject.Properties.Name -contains "status") { [string]$targetJob.status } else { "" }
$jobName = if ($targetJob.PSObject.Properties.Name -contains "name") { [string]$targetJob.name } else { "" }
$jobStage = if ($targetJob.PSObject.Properties.Name -contains "stage") { [string]$targetJob.stage } else { "" }
$pipelineUrl = if ($pipeline.PSObject.Properties.Name -contains "web_url") { [string]$pipeline.web_url } else { "" }
$jobUrl = if ($targetJob.PSObject.Properties.Name -contains "web_url") { [string]$targetJob.web_url } else { "" }
$slurmJobId = if ($manifest.ContainsKey("job_id")) { [string]$manifest["job_id"] } else { "" }

$diagnosis = $null

if ($pipelineStatus -in @("running", "pending")) {
    $diagnosis = New-Diagnosis `
        -Layer "pipeline_observing" `
        -FailureCode "observe.non_terminal" `
        -Decision "observe_only" `
        -SafeToResubmit $false `
        -RequiresModelFix $false `
        -RetryScope "none" `
        -Summary "Pipeline is still active; sidecar stays in observe-only mode." `
        -StopReason "Pipeline has not reached a terminal state." `
        -SampleId "" `
        -SlurmJobId $slurmJobId `
        -EvidencePaths @($tracePath, $manifestPath, $failureSummaryPath) `
        -NeedsNotification $false `
        -NotificationTitle "" `
        -NotificationMessage "" `
        -PipelineStatus $pipelineStatus `
        -JobStatus $jobStatus `
        -JobName $jobName `
        -JobStage $jobStage `
        -PipelineUrl $pipelineUrl `
        -JobUrl $jobUrl
}

if ($null -eq $diagnosis -and $pipelineStatus -eq "success") {
    $diagnosis = New-Diagnosis `
        -Layer "pipeline_success" `
        -FailureCode "success.no_debug" `
        -Decision "observe_only" `
        -SafeToResubmit $false `
        -RequiresModelFix $false `
        -RetryScope "none" `
        -Summary "Pipeline finished successfully; no automatic debug action is needed." `
        -StopReason "Pipeline completed successfully." `
        -SampleId "" `
        -SlurmJobId $slurmJobId `
        -EvidencePaths @($tracePath, $manifestPath) `
        -NeedsNotification $false `
        -NotificationTitle "" `
        -NotificationMessage "" `
        -PipelineStatus $pipelineStatus `
        -JobStatus $jobStatus `
        -JobName $jobName `
        -JobStage $jobStage `
        -PipelineUrl $pipelineUrl `
        -JobUrl $jobUrl
}

if ($null -eq $diagnosis) {
    $getSourcesIndex = $traceText.IndexOf("Getting source from Git repository", [System.StringComparison]::OrdinalIgnoreCase)
    $stepScriptIndex = $traceText.IndexOf('Executing "step_script" stage of the job script', [System.StringComparison]::OrdinalIgnoreCase)
    $quotaIndex = $traceText.IndexOf("Disk quota exceeded", [System.StringComparison]::OrdinalIgnoreCase)
    if ($quotaIndex -ge 0 -and $getSourcesIndex -ge 0 -and ($stepScriptIndex -lt 0 -or $quotaIndex -lt $stepScriptIndex)) {
        $diagnosis = New-Diagnosis `
            -Layer "runner_checkout" `
            -FailureCode "runner.disk_quota" `
            -Decision "notify_user" `
            -SafeToResubmit $false `
            -RequiresModelFix $false `
            -RetryScope "none" `
            -Summary "Runner failed before entering sample logic; checkout hit disk quota." `
            -StopReason "This is runner/storage capacity, so sidecar should notify rather than resubmit." `
            -SampleId "" `
            -SlurmJobId "" `
            -EvidencePaths @($tracePath) `
            -NeedsNotification $true `
            -NotificationTitle "WES pipeline $PipelineId blocked on runner quota" `
            -NotificationMessage "Pipeline $PipelineId failed before entering step_script. Root cause is runner checkout disk quota; do not auto-resubmit until runner storage is released." `
            -PipelineStatus $pipelineStatus `
            -JobStatus $jobStatus `
            -JobName $jobName `
            -JobStage $jobStage `
            -PipelineUrl $pipelineUrl `
            -JobUrl $jobUrl
    }
}

if ($null -eq $diagnosis) {
    $combinedSubmitText = @($traceText, $failureSummaryText, $manifestText) -join "`n"
    if ($combinedSubmitText -match "QOSMaxSubmitJobPerUserLimit") {
        $diagnosis = New-Diagnosis `
            -Layer "slurm_submit" `
            -FailureCode "slurm.qos_submit_limit" `
            -Decision "notify_user" `
            -SafeToResubmit $false `
            -RequiresModelFix $false `
            -RetryScope "none" `
            -Summary "Submission was blocked before a Slurm array job started; this is a server-side QOS gate." `
            -StopReason "User asked to notify on server/queue limits instead of auto-resubmitting." `
            -SampleId "" `
            -SlurmJobId $slurmJobId `
            -EvidencePaths @($tracePath, $failureSummaryPath, $manifestPath) `
            -NeedsNotification $true `
            -NotificationTitle "WES pipeline $PipelineId hit Slurm QOS submit limit" `
            -NotificationMessage "Pipeline $PipelineId was rejected at sbatch submit with QOSMaxSubmitJobPerUserLimit. No safe auto-resubmit is performed; wait for queue relief or adjust submission strategy." `
            -PipelineStatus $pipelineStatus `
            -JobStatus $jobStatus `
            -JobName $jobName `
            -JobStage $jobStage `
            -PipelineUrl $pipelineUrl `
            -JobUrl $jobUrl
    }
}

if ($null -eq $diagnosis) {
    $envEntry = Find-FirstMatch -Entries $logEntries -Patterns @(
        "conda is required when WES_PIPELINE_USE_CONDA=1",
        "Neither python3, node, nor nodejs is available on PATH",
        "command not found"
    )

    if ($null -ne $envEntry) {
        $sampleId = if (-not [string]::IsNullOrWhiteSpace($envEntry.SampleId)) { $envEntry.SampleId } else { "" }
        $diagnosis = New-Diagnosis `
            -Layer "compute_env" `
            -FailureCode "env.bootstrap_missing_tool" `
            -Decision "notify_user" `
            -SafeToResubmit $false `
            -RequiresModelFix $false `
            -RetryScope "none" `
            -Summary "Compute-node bootstrap failed before the sample pipeline could run normally." `
            -StopReason "This is compute-node environment drift, so sidecar should notify instead of resubmitting." `
            -SampleId $sampleId `
            -SlurmJobId $slurmJobId `
            -EvidencePaths @($envEntry.Path, $tracePath, $manifestPath) `
            -NeedsNotification $true `
            -NotificationTitle "WES pipeline $PipelineId blocked by compute-node environment" `
            -NotificationMessage "Pipeline $PipelineId failed on compute-node bootstrap (conda/PATH/bash init). This is an environment issue and should be notified for manual repair before resubmission." `
            -PipelineStatus $pipelineStatus `
            -JobStatus $jobStatus `
            -JobName $jobName `
            -JobStage $jobStage `
            -PipelineUrl $pipelineUrl `
            -JobUrl $jobUrl
    }
}

if ($null -eq $diagnosis) {
    $envTracePatterns = @(
        "conda is required when WES_PIPELINE_USE_CONDA=1",
        "Neither python3, node, nor nodejs is available on PATH",
        "command not found"
    )

    foreach ($pattern in $envTracePatterns) {
        if ($traceText -match $pattern) {
            $diagnosis = New-Diagnosis `
                -Layer "runtime_environment" `
                -FailureCode "runtime.env_missing" `
                -Decision "notify_user" `
                -SafeToResubmit $false `
                -RequiresModelFix $false `
                -RetryScope "none" `
                -Summary "Pipeline reached the compute node, but the runtime environment was not initialized with the required tools." `
                -StopReason "The compute node did not expose conda/tooling, so this needs environment setup rather than sample-level retry." `
                -SampleId "" `
                -SlurmJobId $slurmJobId `
                -EvidencePaths @($tracePath, $failureSummaryPath, $manifestPath) `
                -NeedsNotification $true `
                -NotificationTitle "WES pipeline $PipelineId blocked by runtime environment setup" `
                -NotificationMessage "Pipeline $PipelineId reached the compute node but could not find the required runtime environment. Check SLURM_ENV_SETUP / conda initialization before retrying." `
                -PipelineStatus $pipelineStatus `
                -JobStatus $jobStatus `
                -JobName $jobName `
                -JobStage $jobStage `
                -PipelineUrl $pipelineUrl `
                -JobUrl $jobUrl
            break
        }
    }
}

if ($null -eq $diagnosis) {
    $qcEntry = Find-FirstMatch -Entries $logEntries -Patterns @(
        "JSONDecodeError",
        "json\.decoder\.JSONDecodeError",
        "Unexpected token",
        "SyntaxError:\s*Unexpected",
        "Expecting value",
        "Extra data",
        "invalid control character"
    )

    if ($null -ne $qcEntry -and ($traceText -match "Generating WES QC report" -or $jobName -match "qc" -or $jobStage -match "wes")) {
        $jsonPath = Get-JsonPathFromText -Text $qcEntry.Text
        $summary = "QC report parsing failed on malformed JSON input."
        if (-not [string]::IsNullOrWhiteSpace($jsonPath)) {
            $summary = "QC report parsing failed on malformed JSON input: $jsonPath"
        }

        $diagnosis = New-Diagnosis `
            -Layer "qc_report" `
            -FailureCode "report.bad_json" `
            -Decision "resubmit_after_model_fix" `
            -SafeToResubmit $false `
            -RequiresModelFix $true `
            -RetryScope "qc_only" `
            -Summary $summary `
            -StopReason "This is a report/parser robustness issue. Improve the QC handling first, then rerun QC only." `
            -SampleId "" `
            -SlurmJobId $slurmJobId `
            -EvidencePaths @($qcEntry.Path, $tracePath) `
            -NeedsNotification $false `
            -NotificationTitle "" `
            -NotificationMessage "" `
            -PipelineStatus $pipelineStatus `
            -JobStatus $jobStatus `
            -JobName $jobName `
            -JobStage $jobStage `
            -PipelineUrl $pipelineUrl `
            -JobUrl $jobUrl
    }
}

if ($null -eq $diagnosis) {
    $sortEntry = Find-FirstMatch -Entries $logEntries -Patterns @(
        "samtools sort: failed writing to .*No such file or directory"
    )

    if ($null -ne $sortEntry) {
        $sampleId = if (-not [string]::IsNullOrWhiteSpace($sortEntry.SampleId)) { $sortEntry.SampleId } else { "" }
        $diagnosis = New-Diagnosis `
            -Layer "sample_runtime" `
            -FailureCode "sample.samtools_sort_tmp_path" `
            -Decision "resubmit_after_model_fix" `
            -SafeToResubmit $false `
            -RequiresModelFix $true `
            -RetryScope "debug_subset" `
            -Summary "Sample runtime failed inside samtools sort temporary-file handling." `
            -StopReason "This is a pipeline logic/path issue. Fix it on the model/code side, then rerun the affected debug subset." `
            -SampleId $sampleId `
            -SlurmJobId $slurmJobId `
            -EvidencePaths @($sortEntry.Path, $failureSummaryPath, $manifestPath) `
            -NeedsNotification $false `
            -NotificationTitle "" `
            -NotificationMessage "" `
            -PipelineStatus $pipelineStatus `
            -JobStatus $jobStatus `
            -JobName $jobName `
            -JobStage $jobStage `
            -PipelineUrl $pipelineUrl `
            -JobUrl $jobUrl
    }
}

if ($null -eq $diagnosis) {
    $quotaEntry = Find-FirstMatch -Entries $logEntries -Patterns @(
        "Disk quota exceeded",
        "htsjdk\.samtools\.SAMException",
        "Write error; BinaryCodec"
    )

    if ($null -ne $quotaEntry) {
        $sampleId = if (-not [string]::IsNullOrWhiteSpace($quotaEntry.SampleId)) { $quotaEntry.SampleId } else { "" }
        $failureCode = "sample.runtime_disk_quota"
        $summary = "Sample runtime failed after entering the Slurm task; output writing hit disk quota."
        if ($quotaEntry.Text -match "MarkDuplicates") {
            $failureCode = "sample.markdup_disk_quota"
            $summary = "Sample runtime failed during MarkDuplicates/BAM writing because of disk quota."
        }

        $diagnosis = New-Diagnosis `
            -Layer "sample_runtime" `
            -FailureCode $failureCode `
            -Decision "notify_user" `
            -SafeToResubmit $false `
            -RequiresModelFix $false `
            -RetryScope "debug_subset" `
            -Summary $summary `
            -StopReason "This is storage/quota pressure during sample execution, so sidecar should notify instead of resubmitting." `
            -SampleId $sampleId `
            -SlurmJobId $slurmJobId `
            -EvidencePaths @($quotaEntry.Path, $failureSummaryPath, $manifestPath) `
            -NeedsNotification $true `
            -NotificationTitle "WES pipeline $PipelineId hit sample-stage quota/storage limit" `
            -NotificationMessage "Pipeline $PipelineId failed during sample runtime because of storage/quota pressure. This needs manual intervention before any resubmission." `
            -PipelineStatus $pipelineStatus `
            -JobStatus $jobStatus `
            -JobName $jobName `
            -JobStage $jobStage `
            -PipelineUrl $pipelineUrl `
            -JobUrl $jobUrl
    }
}

if ($null -eq $diagnosis -and $failureSummaryText -match "No failed task records were returned by sacct") {
    $diagnosis = New-Diagnosis `
        -Layer "slurm_array" `
        -FailureCode "array.failed_without_task_records" `
        -Decision "notify_user" `
        -SafeToResubmit $false `
        -RequiresModelFix $false `
        -RetryScope "none" `
        -Summary "Slurm array failed, but sacct did not return per-task failure records." `
        -StopReason "Evidence is incomplete, so sidecar should notify instead of guessing and resubmitting." `
        -SampleId "" `
        -SlurmJobId $slurmJobId `
        -EvidencePaths @($failureSummaryPath, $manifestPath) `
        -NeedsNotification $true `
        -NotificationTitle "WES pipeline $PipelineId needs manual review" `
        -NotificationMessage "Pipeline $PipelineId failed, but Slurm did not return per-task failure records. Manual inspection is required before any resubmission." `
        -PipelineStatus $pipelineStatus `
        -JobStatus $jobStatus `
        -JobName $jobName `
        -JobStage $jobStage `
        -PipelineUrl $pipelineUrl `
        -JobUrl $jobUrl
}

if ($null -eq $diagnosis) {
    $diagnosis = New-Diagnosis `
        -Layer "unknown" `
        -FailureCode "unknown.needs_manual" `
        -Decision "notify_user" `
        -SafeToResubmit $false `
        -RequiresModelFix $false `
        -RetryScope "none" `
        -Summary "Sidecar could not classify this failure into a safe automatic branch." `
        -StopReason "Evidence was incomplete or conflicting; manual review is required." `
        -SampleId "" `
        -SlurmJobId $slurmJobId `
        -EvidencePaths @($tracePath, $failureSummaryPath, $manifestPath) `
        -NeedsNotification $true `
        -NotificationTitle "WES pipeline $PipelineId requires manual review" `
        -NotificationMessage "Pipeline $PipelineId could not be classified into a safe auto-resubmit branch. Manual review is required." `
        -PipelineStatus $pipelineStatus `
        -JobStatus $jobStatus `
        -JobName $jobName `
        -JobStage $jobStage `
        -PipelineUrl $pipelineUrl `
        -JobUrl $jobUrl
}

$jsonOutputPath = Join-Path $resolvedStatusDir "pipeline-$PipelineId-diagnosis.json"
$markdownOutputPath = Join-Path $resolvedStatusDir "pipeline-$PipelineId-diagnosis.md"

$diagnosis | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonOutputPath -Encoding UTF8
Render-Markdown -Diagnosis $diagnosis | Set-Content -Path $markdownOutputPath -Encoding UTF8

if ($diagnosis.needs_notification) {
    $notificationJsonPath = Join-Path $resolvedStatusDir "pipeline-$PipelineId-notification.json"
    $notificationMarkdownPath = Join-Path $resolvedStatusDir "pipeline-$PipelineId-notification.md"
    $notification = New-NotificationDraft -Diagnosis $diagnosis
    $notification | ConvertTo-Json -Depth 4 | Set-Content -Path $notificationJsonPath -Encoding UTF8

    $notificationLines = @()
    $notificationLines += "# WES Notification Draft"
    $notificationLines += ""
    $notificationLines += "- title: $($notification.title)"
    $notificationLines += "- pipeline_id: $($notification.pipeline_id)"
    if (-not [string]::IsNullOrWhiteSpace([string]$notification.job_id)) {
        $notificationLines += "- job_id: $($notification.job_id)"
    }
    $notificationLines += "- layer: $($notification.layer)"
    $notificationLines += "- failure_code: $($notification.failure_code)"
    $notificationLines += "- message: $($notification.message)"
    $notificationLines += ""
    $notificationLines += "## Evidence"
    foreach ($path in $notification.evidence_paths) {
        $notificationLines += "- $path"
    }
    [string]($notificationLines -join [Environment]::NewLine) | Set-Content -Path $notificationMarkdownPath -Encoding UTF8
}

Write-Host "Diagnosis written:"
Write-Host "  $jsonOutputPath"
Write-Host "  $markdownOutputPath"
Write-Host ""
Write-Host "decision=$($diagnosis.decision)"
Write-Host "layer=$($diagnosis.layer)"
Write-Host "failure_code=$($diagnosis.failure_code)"
