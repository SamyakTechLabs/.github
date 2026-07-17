[CmdletBinding()]
param(
    [string]$EnvFile = ".env",
    [switch]$NonInteractive,
    [switch]$PlanOnly,
    [switch]$SkipDockerBuild
)

$ErrorActionPreference = "Stop"
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:TerraformDir = Join-Path (Join-Path $script:RepoRoot "infra") "terraform"
$script:GeneratedDir = Join-Path $script:TerraformDir "generated"
$script:ReportsDir = Join-Path $script:RepoRoot "reports"
$script:RunStartedAt = Get-Date
$script:RunId = $script:RunStartedAt.ToString("yyyyMMdd-HHmmss")
$script:CommandResults = New-Object System.Collections.Generic.List[object]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Import-DotEnvFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

function ConvertTo-PlainHashtable {
    param([object]$InputObject)

    $result = @{}
    if ($null -eq $InputObject) {
        return $result
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = [string]$property.Value
    }

    return $result
}

function Get-ConfigValue {
    param(
        [string]$Name,
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required,
        [switch]$Secret
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($value) {
        return $value
    }

    if ($NonInteractive) {
        if ($Required -and -not $Default) {
            throw "Missing required environment variable $Name"
        }
        return $Default
    }

    $display = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    if ($Secret) {
        $secure = Read-Host $display -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } else {
        $value = Read-Host $display
    }

    if (-not $value) {
        $value = $Default
    }
    if ($Required -and -not $value) {
        throw "Missing required value for $Name"
    }

    [Environment]::SetEnvironmentVariable($Name, $value, "Process")
    return $value
}

function Redact-Value {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    $secretValues = @(
        [Environment]::GetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", "Process"),
        [Environment]::GetEnvironmentVariable("AWS_ACCESS_KEY_ID", "Process"),
        [Environment]::GetEnvironmentVariable("SLACK_WEBHOOK_URL", "Process")
    ) | Where-Object { $_ }

    foreach ($secretValue in $secretValues) {
        $text = $text.Replace($secretValue, "[REDACTED]")
    }

    return ($text -replace '(?i)(database_url|private_key|secret|password|token)["'']?\s*[:=]\s*["'']?[^,"''\r\n]+', '$1=[REDACTED]')
}

function Invoke-CheckedCommand {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $script:RepoRoot,
        [switch]$AllowFailure
    )

    Push-Location $WorkingDirectory
    $commandErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.Exception.Message
            } else {
                $_.ToString()
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $commandErrorActionPreference
        Pop-Location
    }

    $record = [ordered]@{
        name      = $Name
        command   = "$FilePath $($Arguments -join ' ')"
        exit_code = $exitCode
        output    = Redact-Value (($output | Out-String).Trim())
    }
    $script:CommandResults.Add([pscustomobject]$record)

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$Name failed with exit code $exitCode"
    }

    return $output
}

function Assert-CommandExists {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH"
    }
}

function Get-AwsAccountId {
    $json = Invoke-CheckedCommand -Name "aws sts get-caller-identity" -FilePath "aws" -Arguments @("sts", "get-caller-identity", "--output", "json")
    return (($json | Out-String) | ConvertFrom-Json).Account
}

function Initialize-AwsEnvironment {
    param(
        [string]$Region,
        [string]$AccessKeyId,
        [string]$SecretAccessKey,
        [string]$SessionToken
    )

    [Environment]::SetEnvironmentVariable("AWS_ACCESS_KEY_ID", $AccessKeyId, "Process")
    [Environment]::SetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", $SecretAccessKey, "Process")
    if ($SessionToken) {
        [Environment]::SetEnvironmentVariable("AWS_SESSION_TOKEN", $SessionToken, "Process")
    } else {
        [Environment]::SetEnvironmentVariable("AWS_SESSION_TOKEN", $null, "Process")
    }

    [Environment]::SetEnvironmentVariable("AWS_PROFILE", $null, "Process")
    [Environment]::SetEnvironmentVariable("AWS_DEFAULT_PROFILE", $null, "Process")
    [Environment]::SetEnvironmentVariable("AWS_REGION", $Region, "Process")
    [Environment]::SetEnvironmentVariable("AWS_DEFAULT_REGION", $Region, "Process")
    [Environment]::SetEnvironmentVariable("AWS_EC2_METADATA_DISABLED", "true", "Process")
    $script:Warnings.Add("Using isolated AWS environment for this deploy; AWS_PROFILE and AWS_DEFAULT_PROFILE were cleared.")
}

function Test-EcrRepositoryExists {
    param(
        [string]$RepositoryName,
        [string]$Region
    )

    Invoke-CheckedCommand -Name "aws ecr describe-repositories" -FilePath "aws" -Arguments @("ecr", "describe-repositories", "--repository-names", $RepositoryName, "--region", $Region, "--output", "json") -AllowFailure | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-TerraformStateHasResource {
    param([string]$Address)

    $state = Invoke-CheckedCommand -Name "terraform state list" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "state", "list") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return (($state | Out-String) -split "`r?`n") -contains $Address
}

function Get-TerraformWorkspaceName {
    param(
        [string]$ProjectName,
        [string]$DeployEnv
    )

    $workspaceName = ("$ProjectName-$DeployEnv").ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    $workspaceName = $workspaceName.Trim([char[]]"_-")
    if (-not $workspaceName) {
        throw "Unable to derive Terraform workspace name from project '$ProjectName' and environment '$DeployEnv'"
    }

    return $workspaceName
}

function Get-TerraformCurrentWorkspace {
    $workspace = Invoke-CheckedCommand -Name "terraform workspace show" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "workspace", "show") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        return "default"
    }

    return (($workspace | Out-String).Trim())
}

function Get-TerraformStateEcrRepositoryName {
    $state = Invoke-CheckedCommand -Name "terraform state show ecr" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "state", "show", "-no-color", "aws_ecr_repository.app") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $match = [regex]::Match(($state | Out-String), '(?m)^\s*name\s+=\s+"([^"]+)"')
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value
}

function Select-TerraformWorkspace {
    param([string]$WorkspaceName)

    Invoke-CheckedCommand -Name "terraform workspace select" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "workspace", "select", $WorkspaceName) -AllowFailure | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Invoke-CheckedCommand -Name "terraform workspace new" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "workspace", "new", $WorkspaceName) | Out-Null
}

function Initialize-TerraformWorkspace {
    param(
        [string]$ProjectName,
        [string]$DeployEnv,
        [string]$EcrRepositoryName
    )

    $workspaceName = Get-TerraformWorkspaceName -ProjectName $ProjectName -DeployEnv $DeployEnv
    $currentWorkspace = Get-TerraformCurrentWorkspace
    $stateRepositoryName = Get-TerraformStateEcrRepositoryName
    $shouldSelectWorkspace = $false

    if ($currentWorkspace -ne $workspaceName) {
        if ($currentWorkspace -ne "default") {
            $shouldSelectWorkspace = $true
        } elseif (-not $stateRepositoryName) {
            $shouldSelectWorkspace = $true
        } elseif ($stateRepositoryName -ne $EcrRepositoryName) {
            $shouldSelectWorkspace = $true
            $script:Warnings.Add("Current Terraform state contains ECR repository '$stateRepositoryName'; selecting workspace '$workspaceName' for '$ProjectName/$DeployEnv'.")
        }
    }

    if ($shouldSelectWorkspace) {
        Select-TerraformWorkspace -WorkspaceName $workspaceName
        $currentWorkspace = Get-TerraformCurrentWorkspace
    }

    return $currentWorkspace
}

function Write-TfVarsFile {
    param([hashtable]$Config)

    New-Item -ItemType Directory -Force -Path $script:GeneratedDir | Out-Null
    $path = Join-Path $script:GeneratedDir "$($Config.project_name)-$($Config.deploy_env).auto.tfvars.json"
    $tfvarsJson = $Config | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $tfvarsJson, $utf8NoBom)
    return $path
}

function Clear-LegacyDockerContextVariable {
    param([string]$BuildContext)

    $dockerCliContext = [Environment]::GetEnvironmentVariable("DOCKER_CONTEXT", "Process")
    if (-not $dockerCliContext) {
        return
    }

    if ($dockerCliContext -eq $BuildContext -or $dockerCliContext -eq "." -or $dockerCliContext -match '[\\/]') {
        [Environment]::SetEnvironmentVariable("DOCKER_CONTEXT", $null, "Process")
        $script:Warnings.Add("Cleared DOCKER_CONTEXT because Docker uses it for CLI contexts. Use DOCKER_BUILD_CONTEXT for Docker build paths.")
    }
}

function Initialize-DockerConfig {
    $dockerConfigDir = Join-Path $script:GeneratedDir "docker-config-$script:RunId"
    New-Item -ItemType Directory -Force -Path $dockerConfigDir | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $dockerConfigDir "config.json"), '{"auths":{}}', $utf8NoBom)
    [Environment]::SetEnvironmentVariable("DOCKER_CONFIG", $dockerConfigDir, "Process")
    [Environment]::SetEnvironmentVariable("DOCKER_AUTH_CONFIG", $null, "Process")
    $script:Warnings.Add("Using isolated Docker config for this deploy: $dockerConfigDir")
}

function Write-EcrDockerAuthConfig {
    param(
        [string]$Region,
        [string]$Registry
    )

    $dockerConfigDir = [Environment]::GetEnvironmentVariable("DOCKER_CONFIG", "Process")
    if (-not $dockerConfigDir) {
        throw "DOCKER_CONFIG was not initialized"
    }

    $password = & aws ecr get-login-password --region $Region
    if ($LASTEXITCODE -ne 0) {
        throw "aws ecr get-login-password failed"
    }

    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("AWS:$password"))
    $config = [ordered]@{
        auths = [ordered]@{
            $Registry = [ordered]@{
                auth = $auth
            }
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $dockerConfigDir "config.json"), ($config | ConvertTo-Json -Depth 5), $utf8NoBom)

    $script:CommandResults.Add([pscustomobject]@{
        name      = "docker auth config"
        command   = "aws ecr get-login-password --region $Region > isolated Docker config for $Registry"
        exit_code = 0
        output    = "Wrote isolated Docker auth config for $Registry"
    })
}

function Invoke-DockerBuildAndPush {
    param(
        [string]$ImageUri,
        [string]$DockerfilePath,
        [string]$DockerContext
    )

    Invoke-CheckedCommand -Name "docker build" -FilePath "docker" -Arguments @("build", "--platform", "linux/amd64", "--provenance=false", "-f", $DockerfilePath, "-t", $ImageUri, $DockerContext)
    Invoke-CheckedCommand -Name "docker push" -FilePath "docker" -Arguments @("push", $ImageUri)
}

function Get-TerraformOutputs {
    if (-not (Get-Command "terraform" -ErrorAction SilentlyContinue)) {
        return @{}
    }

    $json = Invoke-CheckedCommand -Name "terraform output" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "output", "-json") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        return @{}
    }

    return (($json | Out-String) | ConvertFrom-Json)
}

function Get-TerraformOutputValue {
    param(
        [object]$TerraformOutputs,
        [string]$Name
    )

    if ($null -eq $TerraformOutputs) {
        return ""
    }

    $property = $TerraformOutputs.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }

    return [string]$property.Value.value
}

function Get-TerraformChangeSummary {
    $patterns = @(
        'Plan: \d+ to add, \d+ to change, \d+ to destroy\.',
        'Apply complete! Resources: \d+ added, \d+ changed, \d+ destroyed\.'
    )

    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($command in $script:CommandResults) {
        foreach ($pattern in $patterns) {
            $found = [regex]::Matches([string]$command.output, $pattern)
            foreach ($match in $found) {
                $matches.Add($match.Value)
            }
        }
    }

    if ($matches.Count -eq 0) {
        return "Terraform change summary was not available."
    }

    return (($matches | Select-Object -Unique) -join " ")
}

function New-SlackPayload {
    param(
        [hashtable]$Config,
        [string]$Status,
        [object]$TerraformOutputs,
        [string]$ErrorMessage,
        [hashtable]$ReportPaths
    )

    $apiInvokeUrl = Get-TerraformOutputValue -TerraformOutputs $TerraformOutputs -Name "api_invoke_url"
    $lambdaFunctionName = Get-TerraformOutputValue -TerraformOutputs $TerraformOutputs -Name "lambda_function_name"
    $changeSummary = Get-TerraformChangeSummary
    $safeError = Redact-Value $ErrorMessage

    $title = "AWS deploy $Status"
    if ($Config.project_name) {
        $title = "$($Config.project_name) $($Config.deploy_env) deploy $Status"
    }

    $lines = @(
        "*$title*",
        "Project: $($Config.project_name)",
        "Environment: $($Config.deploy_env)",
        "Region: $($Config.aws_region)",
        "ECR repository: $($Config.ecr_repository_name)",
        "Image: ``$($Config.image_uri)``",
        "Lambda: $lambdaFunctionName",
        "API: $apiInvokeUrl",
        "AWS changes: $changeSummary",
        "Markdown report: $($ReportPaths.markdown)",
        "JSON report: $($ReportPaths.json)"
    )

    if ($safeError) {
        $lines += "Error: $safeError"
    }

    return @{
        text = (($lines | Where-Object { $_ -and ($_ -notmatch ':\s*$') }) -join "`n")
    }
}

function Send-SlackNotification {
    param(
        [hashtable]$Config,
        [string]$Status,
        [object]$TerraformOutputs,
        [string]$ErrorMessage,
        [hashtable]$ReportPaths
    )

    $webhookUrl = [Environment]::GetEnvironmentVariable("SLACK_WEBHOOK_URL", "Process")
    if (-not $webhookUrl) {
        return @{
            enabled = $false
            status  = "skipped"
            message = "SLACK_WEBHOOK_URL was not set."
        }
    }

    try {
        $payload = New-SlackPayload -Config $Config -Status $Status -TerraformOutputs $TerraformOutputs -ErrorMessage $ErrorMessage -ReportPaths $ReportPaths
        $payloadJson = $payload | ConvertTo-Json -Depth 8
        Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType "application/json" -Body $payloadJson -TimeoutSec 10 | Out-Null
        return @{
            enabled = $true
            status  = "sent"
            message = "Slack notification sent."
        }
    } catch {
        $message = "Slack notification failed: $(Redact-Value $_.Exception.Message)"
        $script:Warnings.Add($message)
        return @{
            enabled = $true
            status  = "failed"
            message = $message
        }
    }
}

function Write-DeploymentReport {
    param(
        [hashtable]$Config,
        [string]$Status,
        [object]$TerraformOutputs,
        [string]$ErrorMessage = "",
        [hashtable]$SlackNotification = @{}
    )

    New-Item -ItemType Directory -Force -Path $script:ReportsDir | Out-Null
    $reportBase = Join-Path $script:ReportsDir "deploy-$script:RunId"
    $jsonPath = "$reportBase.json"
    $mdPath = "$reportBase.md"

    $safeConfig = @{}
    foreach ($key in $Config.Keys) {
        if ($key -match '(?i)secret|password|token|private|database') {
            $safeConfig[$key] = "[REDACTED]"
        } else {
            $safeConfig[$key] = $Config[$key]
        }
    }

    $report = [ordered]@{
        run_id            = $script:RunId
        started_at        = $script:RunStartedAt.ToString("o")
        finished_at       = (Get-Date).ToString("o")
        status            = $Status
        config            = $safeConfig
        terraform_outputs = $TerraformOutputs
        commands          = $script:CommandResults
        warnings          = $script:Warnings
        slack_notification = $SlackNotification
        error             = (Redact-Value $ErrorMessage)
    }

    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = @(
        "# Deployment Report $script:RunId",
        "",
        "- Status: $Status",
        "- Project: $($safeConfig.project_name)",
        "- Environment: $($safeConfig.deploy_env)",
        "- Region: $($safeConfig.aws_region)",
        "- ECR repository: $($safeConfig.ecr_repository_name)",
        "- Image URI: $($safeConfig.image_uri)",
        "",
        "## Commands"
    )

    foreach ($command in $script:CommandResults) {
        $lines += "- $($command.name): exit $($command.exit_code)"
    }

    if ($script:Warnings.Count -gt 0) {
        $lines += ""
        $lines += "## Warnings"
        foreach ($warning in $script:Warnings) {
            $lines += "- $warning"
        }
    }

    if ($SlackNotification.Count -gt 0) {
        $lines += ""
        $lines += "## Slack Notification"
        $lines += "- Enabled: $($SlackNotification.enabled)"
        $lines += "- Status: $($SlackNotification.status)"
        $lines += "- Message: $($SlackNotification.message)"
    }

    if ($ErrorMessage) {
        $lines += ""
        $lines += "## Error"
        $lines += Redact-Value $ErrorMessage
    }

    $lines | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return @{
        markdown = $mdPath
        json     = $jsonPath
    }
}

$status = "failed"
$errorMessage = ""
$config = @{}

try {
    Import-DotEnvFile -Path (Join-Path $script:RepoRoot $EnvFile)

    Assert-CommandExists "aws"
    Assert-CommandExists "terraform"
    if (-not $SkipDockerBuild) {
        Assert-CommandExists "docker"
    }

    $awsRegion = Get-ConfigValue -Name "AWS_REGION" -Prompt "AWS region" -Default "ap-south-1" -Required
    $projectName = Get-ConfigValue -Name "PROJECT_NAME" -Prompt "Project name" -Default "mju-be" -Required
    $deployEnv = Get-ConfigValue -Name "DEPLOY_ENV" -Prompt "Deployment environment" -Default "dev" -Required
    $ecrRepositoryName = Get-ConfigValue -Name "ECR_REPOSITORY" -Prompt "ECR repository name" -Default $projectName -Required
    $apiStage = Get-ConfigValue -Name "API_STAGE" -Prompt "API Gateway stage" -Default '$default' -Required
    $lambdaMemory = [int](Get-ConfigValue -Name "LAMBDA_MEMORY_SIZE" -Prompt "Lambda memory size" -Default "512" -Required)
    $lambdaTimeout = [int](Get-ConfigValue -Name "LAMBDA_TIMEOUT" -Prompt "Lambda timeout seconds" -Default "30" -Required)
    $logRetentionDays = [int](Get-ConfigValue -Name "LOG_RETENTION_DAYS" -Prompt "CloudWatch log retention days" -Default "14" -Required)
    $dockerfilePath = Get-ConfigValue -Name "DOCKERFILE_PATH" -Prompt "Dockerfile path" -Default "infra/bootstrap-image/Dockerfile" -Required
    $dockerContext = Get-ConfigValue -Name "DOCKER_BUILD_CONTEXT" -Prompt "Docker build context" -Default "infra/bootstrap-image" -Required
    Clear-LegacyDockerContextVariable -BuildContext $dockerContext

    $awsAccessKeyId = Get-ConfigValue -Name "AWS_ACCESS_KEY_ID" -Prompt "AWS access key ID" -Required
    $awsSecretAccessKey = Get-ConfigValue -Name "AWS_SECRET_ACCESS_KEY" -Prompt "AWS secret access key" -Required -Secret
    $awsSessionToken = [Environment]::GetEnvironmentVariable("AWS_SESSION_TOKEN", "Process")
    Initialize-AwsEnvironment -Region $awsRegion -AccessKeyId $awsAccessKeyId -SecretAccessKey $awsSecretAccessKey -SessionToken $awsSessionToken

    $accountId = Get-AwsAccountId
    $registry = "$accountId.dkr.ecr.$awsRegion.amazonaws.com"
    $imageTag = [Environment]::GetEnvironmentVariable("IMAGE_TAG", "Process")
    if (-not $imageTag) {
        $imageTag = "bootstrap-$script:RunId"
    }
    $imageUri = "$registry/$ecrRepositoryName`:$imageTag"

    $lambdaEnv = @{}
    $lambdaEnvJson = [Environment]::GetEnvironmentVariable("LAMBDA_ENV_JSON", "Process")
    if ($lambdaEnvJson) {
        $lambdaEnv = ConvertTo-PlainHashtable -InputObject ($lambdaEnvJson | ConvertFrom-Json)
    }

    $config = @{
        aws_region                   = $awsRegion
        project_name                 = $projectName
        deploy_env                   = $deployEnv
        ecr_repository_name          = $ecrRepositoryName
        api_stage                    = $apiStage
        image_uri                    = $imageUri
        lambda_memory_size           = $lambdaMemory
        lambda_timeout               = $lambdaTimeout
        log_retention_days           = $logRetentionDays
        lambda_environment_variables = $lambdaEnv
    }

    $tfvarsPath = Write-TfVarsFile -Config $config

    Invoke-CheckedCommand -Name "terraform init" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "init")
    $terraformWorkspace = Initialize-TerraformWorkspace -ProjectName $projectName -DeployEnv $deployEnv -EcrRepositoryName $ecrRepositoryName
    $config.terraform_workspace = $terraformWorkspace

    if (-not (Test-TerraformStateHasResource -Address "aws_ecr_repository.app")) {
        if (Test-EcrRepositoryExists -RepositoryName $ecrRepositoryName -Region $awsRegion) {
            Invoke-CheckedCommand -Name "terraform import ecr" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "import", "-var-file=$tfvarsPath", "aws_ecr_repository.app", $ecrRepositoryName)
        } else {
            Invoke-CheckedCommand -Name "terraform apply ecr target" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "apply", "-target=aws_ecr_repository.app", "-var-file=$tfvarsPath", "-auto-approve")
        }
    }

    if ($SkipDockerBuild) {
        $script:Warnings.Add("Docker build was skipped; image URI must already exist: $imageUri")
    } else {
        Initialize-DockerConfig
        Write-EcrDockerAuthConfig -Region $awsRegion -Registry $registry
        Invoke-DockerBuildAndPush -ImageUri $imageUri -DockerfilePath $dockerfilePath -DockerContext $dockerContext
    }

    $planPath = Join-Path "generated" "$projectName-$deployEnv.tfplan"
    Invoke-CheckedCommand -Name "terraform plan" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "plan", "-var-file=$tfvarsPath", "-out=$planPath")

    if ($PlanOnly) {
        $status = "planned"
    } else {
        Invoke-CheckedCommand -Name "terraform apply" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "apply", $planPath)
        $status = "applied"
    }
} catch {
    $errorMessage = $_.Exception.Message
    throw
} finally {
    $outputs = Get-TerraformOutputs
    $reportPaths = Write-DeploymentReport -Config $config -Status $status -TerraformOutputs $outputs -ErrorMessage $errorMessage
    $slackNotification = Send-SlackNotification -Config $config -Status $status -TerraformOutputs $outputs -ErrorMessage $errorMessage -ReportPaths $reportPaths
    Write-DeploymentReport -Config $config -Status $status -TerraformOutputs $outputs -ErrorMessage $errorMessage -SlackNotification $slackNotification | Out-Null
}
