param(
    [Parameter(Mandatory = $true)]
    [int]$PipelineId,
    [int]$PollIntervalSeconds = 60,
    [int]$TimeoutMinutes = 720,
    [string]$FeishuWebhookUrl = "",
    [switch]$DownloadLatestTrace
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
        [string]$Uri,
        [object]$Body
    )

    $token = Get-RequiredEnv -Name "GITLAB_TOKEN"
    $headers = @{ "PRIVATE-TOKEN" = $token }
    if ($PSBoundParameters.ContainsKey("Body")) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $Body -ContentType "application/json"
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
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
    $jobs = if ($jobsResponse -is [System.Array]) { $jobsResponse } else { @($jobsResponse) }
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
        StatusDir = $statusDir
    }
}

function Save-LatestTrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [Parameter(Mandatory = $true)]
        [int]$ProjectId,
        [Parameter(Mandatory = $true)]
        [object[]]$Jobs,
        [Parameter(Mandatory = $true)]
        [string]$StatusDir
    )

    $job = $Jobs | Sort-Object id -Descending | Select-Object -First 1
    if ($null -eq $job) {
        return $null
    }

    $traceUri = "$ApiBase/projects/$ProjectId/jobs/$($job.id)/trace"
    $tracePath = Join-Path $StatusDir "job-$($job.id)-trace.log"
    $token = Get-RequiredEnv -Name "GITLAB_TOKEN"
    $headers = @{ "PRIVATE-TOKEN" = $token }
    Invoke-RestMethod -Headers $headers -Uri $traceUri -OutFile $tracePath
    return $tracePath
}

function Show-WindowsNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Message
        $notify.Visible = $true
        $notify.ShowBalloonTip(10000)
        Start-Sleep -Seconds 12
        $notify.Dispose()
    } catch {
        [console]::beep(1000, 400)
        Write-Warning "Windows notification failed: $($_.Exception.Message)"
    }
}

function Send-FeishuNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebhookUrl,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $payload = @{
        msg_type = "text"
        content = @{
            text = $Message
        }
    } | ConvertTo-Json -Depth 4

    Invoke-RestMethod -Method POST -Uri $WebhookUrl -Body $payload -ContentType "application/json" | Out-Null
}

$repoRoot = (Get-Location).Path
$remoteUrl = [string]::Concat((Invoke-Git -Args @("remote", "get-url", "origin"))).Trim()
$projectPath = Get-ProjectPathFromRemote -RemoteUrl $remoteUrl
$apiBase = Get-ApiBaseFromRemote -RemoteUrl $remoteUrl
$encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)
$project = Invoke-GitLabApi -Method GET -Uri "$apiBase/projects/$encodedProjectPath"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$terminalStates = @("success", "failed", "canceled", "skipped", "manual")

if ([string]::IsNullOrWhiteSpace($FeishuWebhookUrl)) {
    $FeishuWebhookUrl = [Environment]::GetEnvironmentVariable("FEISHU_WEBHOOK_URL")
}

Write-Host "Watching pipeline $PipelineId"
Write-Host "Project: $projectPath"
Write-Host "Poll interval: $PollIntervalSeconds seconds"

do {
    $snapshot = Get-PipelineSnapshot -ApiBase $apiBase -ProjectId $project.id -PipelineId $PipelineId
    $saved = Save-Snapshot -RepoRoot $repoRoot -PipelineId $PipelineId -Snapshot $snapshot

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
        throw "Timed out waiting for pipeline $PipelineId to finish"
    }
    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

$tracePath = $null
if ($DownloadLatestTrace) {
    $tracePath = Save-LatestTrace -ApiBase $apiBase -ProjectId $project.id -Jobs $snapshot.Jobs -StatusDir $saved.StatusDir
}

$jobSummary = (($snapshot.Jobs | Sort-Object id | ForEach-Object { "[{0}] {1}/{2}" -f $_.status, $_.stage, $_.name }) -join "; ")
$message = "WES pipeline $PipelineId finished: $($snapshot.Pipeline.status)`n$jobSummary`n$($snapshot.Pipeline.web_url)"
if ($tracePath) {
    $message += "`ntrace=$tracePath"
}

Show-WindowsNotification -Title "WES Pipeline $PipelineId" -Message "Status: $($snapshot.Pipeline.status)"
if (-not [string]::IsNullOrWhiteSpace($FeishuWebhookUrl)) {
    Send-FeishuNotification -WebhookUrl $FeishuWebhookUrl -Message $message
}

Write-Host ""
Write-Host "Final pipeline status: $($snapshot.Pipeline.status)"
Write-Host "Pipeline URL: $($snapshot.Pipeline.web_url)"
if ($tracePath) {
    Write-Host "Latest trace: $tracePath"
}
