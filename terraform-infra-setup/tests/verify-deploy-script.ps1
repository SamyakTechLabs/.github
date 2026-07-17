$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$deployScript = Get-Content -LiteralPath (Join-Path (Join-Path $repoRoot "scripts") "deploy.ps1") -Raw
$readme = Get-Content -LiteralPath (Join-Path $repoRoot "README.md") -Raw
$envExample = Get-Content -LiteralPath (Join-Path $repoRoot "env.example") -Raw
$bootstrapDockerfilePath = Join-Path (Join-Path (Join-Path $repoRoot "infra") "bootstrap-image") "Dockerfile"
$bootstrapHandlerPath = Join-Path (Join-Path (Join-Path $repoRoot "infra") "bootstrap-image") "index.mjs"

function Assert-Contains {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Pattern
    )

    if ($Content -notmatch [regex]::Escape($Pattern)) {
        throw "$Name does not contain expected text: $Pattern"
    }
}

function Assert-DoesNotContain {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Pattern
    )

    if ($Content -match [regex]::Escape($Pattern)) {
        throw "$Name contains forbidden text: $Pattern"
    }
}

Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern "SLACK_WEBHOOK_URL"
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '$script:TerraformDir = Join-Path (Join-Path $script:RepoRoot "infra") "terraform"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern "function Send-SlackNotification"
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern "Invoke-RestMethod"
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern "slack_notification"
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern "Slack notification failed"
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern 'if (-not [Environment]::GetEnvironmentVariable($name, "Process"))'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '$commandErrorActionPreference = $ErrorActionPreference'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '$ErrorActionPreference = "Continue"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'if ($_ -is [System.Management.Automation.ErrorRecord])'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '$_.Exception.Message'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '$ErrorActionPreference = $commandErrorActionPreference'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'Image: ``$($Config.image_uri)``'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'New-Object System.Text.UTF8Encoding($false)'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[System.IO.File]::WriteAllText($path, $tfvarsJson, $utf8NoBom)'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'Default "infra/bootstrap-image/Dockerfile"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'Default "infra/bootstrap-image"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'DOCKER_BUILD_CONTEXT'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[Environment]::SetEnvironmentVariable("DOCKER_CONTEXT", $null, "Process")'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern 'Get-ConfigValue -Name "DOCKER_CONTEXT"'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern '$password | docker login'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'function Write-EcrDockerAuthConfig'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("AWS:$password"))'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'Write-EcrDockerAuthConfig -Region $awsRegion -Registry $registry'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern 'Invoke-EcrLogin -Region $awsRegion -Registry $registry'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern 'docker login --username AWS --password-stdin'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '"--platform", "linux/amd64"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '"--provenance=false"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'function Initialize-AwsEnvironment'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[Environment]::SetEnvironmentVariable("AWS_PROFILE", $null, "Process")'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[Environment]::SetEnvironmentVariable("AWS_DEFAULT_PROFILE", $null, "Process")'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[Environment]::SetEnvironmentVariable("AWS_EC2_METADATA_DISABLED", "true", "Process")'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'Initialize-AwsEnvironment -Region $awsRegion -AccessKeyId $awsAccessKeyId -SecretAccessKey $awsSecretAccessKey -SessionToken $awsSessionToken'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'function Initialize-DockerConfig'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '"docker-config-$script:RunId"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[System.IO.File]::WriteAllText((Join-Path $dockerConfigDir "config.json"), ''{"auths":{}}'', $utf8NoBom)'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '[Environment]::SetEnvironmentVariable("DOCKER_CONFIG", $dockerConfigDir, "Process")'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern 'if ($existingDockerConfig)'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'function Get-TerraformWorkspaceName'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'function Get-TerraformStateEcrRepositoryName'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'function Initialize-TerraformWorkspace'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '"workspace", "show"'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '"workspace", "select", $WorkspaceName'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '"workspace", "new", $WorkspaceName'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'terraform_workspace'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern 'Initialize-TerraformWorkspace -ProjectName $projectName -DeployEnv $deployEnv -EcrRepositoryName $ecrRepositoryName'
Assert-Contains -Name "deploy.ps1" -Content $deployScript -Pattern '$planPath = Join-Path "generated" "$projectName-$deployEnv.tfplan"'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern '"infra\terraform"'
Assert-DoesNotContain -Name "deploy.ps1" -Content $deployScript -Pattern '"generated\$projectName-$deployEnv.tfplan"'
Assert-Contains -Name ".gitignore" -Content (Get-Content -LiteralPath (Join-Path $repoRoot ".gitignore") -Raw) -Pattern ".docker-temp/"
Assert-Contains -Name "README.md" -Content $readme -Pattern "SLACK_WEBHOOK_URL"
Assert-Contains -Name "README.md" -Content $readme -Pattern 'PowerShell 7+ (`pwsh`) on macOS/Linux'
Assert-Contains -Name "README.md" -Content $readme -Pattern 'pwsh -File ./scripts/deploy.ps1 -NonInteractive'
Assert-Contains -Name "README.md" -Content $readme -Pattern "built-in placeholder Lambda image"
Assert-Contains -Name "env.example" -Content $envExample -Pattern "SLACK_WEBHOOK_URL="
Assert-Contains -Name "env.example" -Content $envExample -Pattern "DOCKERFILE_PATH=infra/bootstrap-image/Dockerfile"
Assert-Contains -Name "env.example" -Content $envExample -Pattern "DOCKER_BUILD_CONTEXT=infra/bootstrap-image"
Assert-DoesNotContain -Name "env.example" -Content $envExample -Pattern "DOCKER_CONTEXT="

if (-not (Test-Path -LiteralPath $bootstrapDockerfilePath)) {
    throw "Bootstrap Dockerfile was not found at $bootstrapDockerfilePath"
}

if (-not (Test-Path -LiteralPath $bootstrapHandlerPath)) {
    throw "Bootstrap Lambda handler was not found at $bootstrapHandlerPath"
}

$bootstrapDockerfile = Get-Content -LiteralPath $bootstrapDockerfilePath -Raw
$bootstrapHandler = Get-Content -LiteralPath $bootstrapHandlerPath -Raw

Assert-Contains -Name "bootstrap Dockerfile" -Content $bootstrapDockerfile -Pattern "public.ecr.aws/lambda/nodejs:20"
Assert-Contains -Name "bootstrap Dockerfile" -Content $bootstrapDockerfile -Pattern 'CMD ["index.handler"]'
Assert-Contains -Name "bootstrap handler" -Content $bootstrapHandler -Pattern "Infrastructure is ready"

$forbiddenWebhookPrefix = "hooks.slack.com/" + "services/"
$excludedDirs = @(".git", ".terraform", "generated", "reports")

function Get-SourceFiles {
    param([string]$Path)

    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        if ($item.PSIsContainer) {
            if ($excludedDirs -contains $item.Name) {
                continue
            }

            Get-SourceFiles -Path $item.FullName
            continue
        }

        if ($item.Name -match '^\.env(\..*)?$') {
            continue
        }

        $item
    }
}

$files = Get-SourceFiles -Path $repoRoot

foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    Assert-DoesNotContain -Name $file.FullName -Content $content -Pattern $forbiddenWebhookPrefix
}

Write-Host "deploy script Slack notification checks passed"
