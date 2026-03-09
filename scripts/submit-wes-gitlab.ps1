param(
    [string]$CommitMessage = "chore: continue WES mainline",
    [int]$PollIntervalSeconds = 20,
    [int]$TimeoutMinutes = 180,
    [switch]$SkipCommit,
    [switch]$SkipPush,
    [switch]$WatchOnly
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
        if ($null -eq $stdout) { $stdout = "" }
        if ($null -eq $stderr) { $stderr = "" }
        $combined = [string]((@($stdout.TrimEnd(), $stderr.TrimEnd()) | Where-Object { $_ }) -join [Environment]::NewLine)

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

    $value = [Environment]::GetEnvironmentVariable($Name)
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
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $token = Get-RequiredEnv -Name "GITLAB_TOKEN"
    $headers = @{ "PRIVATE-TOKEN" = $token }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Get-ProjectInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    $encodedProjectPath = [System.Uri]::EscapeDataString($ProjectPath)
    $projectUri = "$ApiBase/projects/$encodedProjectPath"
    return Invoke-GitLabApi -Method GET -Uri $projectUri
}

function Wait-ForPipeline {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [Parameter(Mandatory = $true)]
        [int]$ProjectId,
        [Parameter(Mandatory = $true)]
        [string]$Branch,
        [Parameter(Mandatory = $true)]
        [string]$Sha,
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline,
        [Parameter(Mandatory = $true)]
        [int]$PollIntervalSeconds
    )

    $encodedBranch = [System.Uri]::EscapeDataString($Branch)
    while ((Get-Date) -lt $Deadline) {
        $pipelinesUri = "$ApiBase/projects/$ProjectId/pipelines?ref=$encodedBranch&per_page=20"
        $pipelinesResponse = Invoke-GitLabApi -Method GET -Uri $pipelinesUri
        if ($pipelinesResponse -is [System.Array]) {
            $pipelines = $pipelinesResponse
        } else {
            $pipelines = @($pipelinesResponse)
        }
        $matched = $pipelines | Where-Object { [string]$_.sha -eq $Sha } | Sort-Object id -Descending | Select-Object -First 1
        if ($null -ne $matched) {
            return $matched
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for a pipeline for commit $Sha on branch $Branch"
}

function Get-PipelineSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [Parameter(Mandatory = $true)]
        [int]$ProjectId,
        [Parameter(Mandatory = $true)]
        [int]$PipelineId
    )

    $pipelineUri = "$ApiBase/projects/$ProjectId/pipelines/$PipelineId"
    $jobsUri = "$ApiBase/projects/$ProjectId/pipelines/$PipelineId/jobs?per_page=100"
    $pipeline = Invoke-GitLabApi -Method GET -Uri $pipelineUri
    $jobsResponse = Invoke-GitLabApi -Method GET -Uri $jobsUri
    if ($jobsResponse -is [System.Array]) {
        $jobs = $jobsResponse
    } else {
        $jobs = @($jobsResponse)
    }
    return [pscustomobject]@{
        Pipeline = $pipeline
        Jobs = $jobs
    }
}

function Save-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [int]$PipelineId,
        [Parameter(Mandatory = $true)]
        [psobject]$Snapshot
    )

    $statusDir = Join-Path $RepoRoot "output\wes\gitlab-status"
    if (!(Test-Path $statusDir)) {
        New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
    }

    $jsonPath = Join-Path $statusDir "pipeline-$PipelineId.json"
    $txtPath = Join-Path $statusDir "pipeline-$PipelineId.txt"

    $Snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @()
    $lines += "pipeline_id=$PipelineId"
    $lines += "status=$($Snapshot.Pipeline.status)"
    $lines += "web_url=$($Snapshot.Pipeline.web_url)"
    $lines += "ref=$($Snapshot.Pipeline.ref)"
    $lines += "sha=$($Snapshot.Pipeline.sha)"
    $lines += "updated_at=$($Snapshot.Pipeline.updated_at)"
    $lines += ""
    $lines += "jobs:"
    foreach ($job in $Snapshot.Jobs | Sort-Object id) {
        $lines += "[$($job.status)] stage=$($job.stage) name=$($job.name) id=$($job.id) web_url=$($job.web_url)"
    }
    $lines | Set-Content -Path $txtPath -Encoding UTF8

    return [pscustomobject]@{
        JsonPath = $jsonPath
        TextPath = $txtPath
    }
}

$repoRoot = (Get-Location).Path
$branchOutput = Invoke-Git -Args @("branch", "--show-current")
$branch = [string]::Concat($branchOutput).Trim()
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw "Could not determine current branch"
}

$remoteUrlOutput = Invoke-Git -Args @("remote", "get-url", "origin")
$remoteUrl = [string]::Concat($remoteUrlOutput).Trim()
$projectPath = Get-ProjectPathFromRemote -RemoteUrl $remoteUrl
$apiBase = Get-ApiBaseFromRemote -RemoteUrl $remoteUrl

if (-not $WatchOnly) {
    $status = @(Invoke-Git -Args @("status", "--short"))
    if ($status.Count -gt 0 -and -not $SkipCommit) {
        Invoke-Git -Args @("add", "-A") | Out-Null
        Invoke-Git -Args @("commit", "-m", $CommitMessage) | Out-Null
    }

    if (-not $SkipPush) {
        Invoke-Git -Args @("push", "origin", "HEAD") | Out-Null
    }
}

$shaOutput = Invoke-Git -Args @("rev-parse", "HEAD")
$sha = [string]::Concat($shaOutput).Trim()
$project = Get-ProjectInfo -ApiBase $apiBase -ProjectPath $projectPath
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$pipeline = Wait-ForPipeline -ApiBase $apiBase -ProjectId $project.id -Branch $branch -Sha $sha -Deadline $deadline -PollIntervalSeconds $PollIntervalSeconds

Write-Host "Pipeline detected: id=$($pipeline.id) status=$($pipeline.status)"
Write-Host "Pipeline URL: $($pipeline.web_url)"

$terminalStates = @("success", "failed", "canceled", "skipped", "manual")
do {
    $snapshot = Get-PipelineSnapshot -ApiBase $apiBase -ProjectId $project.id -PipelineId $pipeline.id
    $saved = Save-Snapshot -RepoRoot $repoRoot -PipelineId $pipeline.id -Snapshot $snapshot

    Write-Host ""
    Write-Host ("[{0}] pipeline {1} updated_at={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $snapshot.Pipeline.status, $snapshot.Pipeline.updated_at)
    foreach ($job in $snapshot.Jobs | Sort-Object id) {
        Write-Host ("  [{0}] {1}/{2}" -f $job.status, $job.stage, $job.name)
    }
    Write-Host "Saved snapshot: $($saved.TextPath)"

    if ($terminalStates -contains $snapshot.Pipeline.status) {
        break
    }
    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting for pipeline $($pipeline.id) to finish"
    }
    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

Write-Host ""
Write-Host "Final pipeline status: $($snapshot.Pipeline.status)"
Write-Host "Pipeline URL: $($snapshot.Pipeline.web_url)"
