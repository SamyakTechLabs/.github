# Terraform AWS Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable Terraform and PowerShell deployment scaffold that provisions the MJU backend AWS stack, bootstraps the first Lambda container image, supports any GitHub repository including private repos, and writes a report for every run.

**Architecture:** A local PowerShell runner handles prompts, environment loading, AWS credential validation, ECR bootstrap/import, Docker build/push, Terraform orchestration, and report generation. Terraform owns long-lived AWS resources: ECR, Lambda, API Gateway, ACM, Lightsail DNS entries, and the GitHub Actions OIDC IAM role. GitHub authentication is AWS-side OIDC trust only; no GitHub token or FastAPI backend is required in the first version.

**Tech Stack:** Terraform, AWS provider, PowerShell 5+, AWS CLI, Docker CLI, GitHub Actions OIDC.

## Global Constraints

- Read `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from environment variables first.
- Prompt interactively for missing values, using project-generator style defaults.
- Build and push the first Lambda container image automatically before the full Terraform apply.
- Manage Lightsail DNS records automatically for ACM validation and API Gateway custom domain routing.
- Support `GITHUB_REPOSITORY` in `owner/repo` format for public or private GitHub repositories.
- Do not require a GitHub personal access token or GitHub OAuth connection in the first version.
- Generate both Markdown and JSON reports under `reports/` for every run.
- Redact AWS secrets, application secrets, database URLs, private keys, and sensitive Terraform values from reports.
- Avoid destructive cleanup automation; infrastructure destroy remains an explicit user-run Terraform command.

---

## File Structure

- `.gitignore`: Ignore generated Terraform state, generated tfvars, Docker/Terraform logs, and deployment reports while preserving `reports/.gitkeep`.
- `README.md`: Explain prerequisites, environment variables, interactive usage, non-interactive usage, generated reports, and GitHub OIDC behavior.
- `env.example`: Show supported environment variables without real secrets.
- `reports/.gitkeep`: Keep the reports directory in source control.
- `infra/terraform/.gitignore`: Ignore Terraform runtime files in the Terraform directory.
- `infra/terraform/versions.tf`: Declare Terraform and provider requirements.
- `infra/terraform/variables.tf`: Define all Terraform inputs used by the runner.
- `infra/terraform/main.tf`: Define AWS resources.
- `infra/terraform/outputs.tf`: Export ARNs, URLs, repository details, DNS targets, and workflow values for reports.
- `infra/terraform/README.md`: Explain direct Terraform usage and the bootstrap behavior.
- `scripts/deploy.ps1`: Interactive/non-interactive orchestration runner.
- `.github/workflows/deploy-lambda.yml.example`: Example GitHub Actions workflow using OIDC and the generated role.

---

### Task 1: Repository Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `env.example`
- Create: `reports/.gitkeep`
- Create: `infra/terraform/.gitignore`

**Interfaces:**
- Consumes: Design spec at `docs/superpowers/specs/2026-07-14-terraform-aws-deployment-design.md`.
- Produces: Stable paths used by later tasks: `infra/terraform`, `scripts`, and `reports`.

- [ ] **Step 1: Create generated-artifact ignore rules**

Create `.gitignore` with:

```gitignore
# Local environment files
.env
.env.*
!.env.example

# Terraform runtime state and plans
**/.terraform/
**/.terraform.lock.hcl
**/terraform.tfstate
**/terraform.tfstate.*
**/*.tfplan
**/*.auto.tfvars
**/*.auto.tfvars.json
infra/terraform/generated/

# Deployment reports are generated per run
reports/*
!reports/.gitkeep

# Logs and local tooling output
*.log
*.tmp
.DS_Store
Thumbs.db
```

- [ ] **Step 2: Create root usage documentation**

Create `README.md` with sections for:

```markdown
# AWS Lambda Container Deployment Scaffold

This repository contains a Terraform and PowerShell scaffold for deploying a backend as an AWS Lambda container image behind API Gateway with an ACM custom domain, Lightsail DNS, ECR, and GitHub Actions OIDC.

## Prerequisites

- AWS administrator credentials exported as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- AWS CLI
- Docker
- Terraform
- PowerShell 5 or newer
- A Lambda-compatible container `Dockerfile`

## Quick Start

```powershell
$env:AWS_ACCESS_KEY_ID = "..."
$env:AWS_SECRET_ACCESS_KEY = "..."
.\scripts\deploy.ps1
```

The script prompts for missing values, builds and pushes the first image, runs Terraform, and writes a Markdown plus JSON report under `reports/`.

## GitHub Repositories

Set `GITHUB_REPOSITORY` to any public or private repository in `owner/repo` format. The scaffold creates AWS IAM trust for GitHub Actions OIDC. It does not need GitHub OAuth or a GitHub personal access token unless you later add automatic GitHub API operations.

## Reports

Each run writes:

- `reports/deploy-YYYYMMDD-HHMMSS.md`
- `reports/deploy-YYYYMMDD-HHMMSS.json`

Reports include resource names, ARNs, URLs, DNS records, image details, and command status. Secrets are redacted.
```

- [ ] **Step 3: Create environment example**

Create `env.example` with:

```dotenv
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=ap-south-1

PROJECT_NAME=mju-be
DEPLOY_ENV=dev
API_DOMAIN=api.dev.myjainuniverse.com
DNS_ZONE=myjainuniverse.com

GITHUB_REPOSITORY=SamyakTechLabs/mju-be
GITHUB_ENVIRONMENT=dev

LAMBDA_MEMORY_SIZE=512
LAMBDA_TIMEOUT=30
DOCKERFILE_PATH=Dockerfile
DOCKER_CONTEXT=.

# Optional JSON map merged into Lambda environment variables.
# Do not put long-lived secrets here unless you accept that Terraform state can store them.
LAMBDA_ENV_JSON={"LOG_LEVEL":"INFO"}
```

- [ ] **Step 4: Keep reports directory**

Create an empty `reports/.gitkeep`.

- [ ] **Step 5: Ignore Terraform runtime files locally**

Create `infra/terraform/.gitignore` with:

```gitignore
.terraform/
.terraform.lock.hcl
terraform.tfstate
terraform.tfstate.*
*.tfplan
*.auto.tfvars
*.auto.tfvars.json
generated/
```

- [ ] **Step 6: Verify scaffolding files**

Run: `Get-ChildItem -Force`

Expected: root contains `.gitignore`, `README.md`, `env.example`, `docs`, `infra`, and `reports`.

- [ ] **Step 7: Commit scaffolding**

Run:

```powershell
git add .gitignore README.md env.example reports/.gitkeep infra/terraform/.gitignore
git commit -m "Add deployment scaffold docs"
```

Expected: commit succeeds.

---

### Task 2: Terraform Infrastructure

**Files:**
- Create: `infra/terraform/versions.tf`
- Create: `infra/terraform/variables.tf`
- Create: `infra/terraform/main.tf`
- Create: `infra/terraform/outputs.tf`
- Create: `infra/terraform/README.md`

**Interfaces:**
- Consumes: Generated tfvars file from `scripts/deploy.ps1`.
- Produces: Terraform outputs consumed by `scripts/deploy.ps1`: `aws_account_id`, `ecr_repository_uri`, `image_uri`, `lambda_function_name`, `lambda_function_arn`, `api_id`, `api_stage`, `api_invoke_url`, `api_custom_domain_url`, `api_gateway_target_domain_name`, `acm_certificate_arn`, `github_deploy_role_arn`, and `github_oidc_subject`.

- [ ] **Step 1: Add Terraform provider requirements**

Create `infra/terraform/versions.tf` with:

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
```

- [ ] **Step 2: Add Terraform variables**

Create `infra/terraform/variables.tf` with variables for:

```hcl
variable "aws_region" { type = string }
variable "project_name" { type = string }
variable "deploy_env" { type = string }
variable "api_domain" { type = string }
variable "dns_zone" { type = string }
variable "api_stage" { type = string, default = "" }
variable "image_uri" { type = string }
variable "lambda_memory_size" { type = number, default = 512 }
variable "lambda_timeout" { type = number, default = 30 }
variable "lambda_environment_variables" { type = map(string), default = {}, sensitive = true }
variable "github_repository" { type = string }
variable "github_environment" { type = string }
variable "github_oidc_provider_arn" { type = string, default = "" }
variable "create_lightsail_domain" { type = bool, default = false }
variable "tags" { type = map(string), default = {} }
```

Add validation blocks so `github_repository` must contain one `/`, memory is between `128` and `10240`, timeout is between `1` and `900`, and `api_domain` must not equal `dns_zone`.

- [ ] **Step 3: Add AWS resources**

Create `infra/terraform/main.tf` with these resource groups:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(local.common_tags, var.tags)
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix        = replace(lower("${var.project_name}-${var.deploy_env}"), "_", "-")
  repository_name    = var.project_name
  lambda_name        = local.name_prefix
  api_name           = "${local.name_prefix}-api"
  api_stage_name     = var.api_stage != "" ? var.api_stage : var.deploy_env
  api_subdomain_name = trimsuffix(var.api_domain, ".${var.dns_zone}")
  github_subject     = "repo:${var.github_repository}:environment:${var.github_environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.deploy_env
    ManagedBy   = "terraform"
  }

  lambda_environment = merge(
    {
      ENVIRONMENT = var.deploy_env
      LOG_LEVEL   = "INFO"
    },
    var.lambda_environment_variables
  )

  acm_validation_records = {
    for option in aws_acm_certificate.api.domain_validation_options : option.domain_name => {
      fqdn          = trimsuffix(option.resource_record_name, ".")
      relative_name = trimsuffix(trimsuffix(option.resource_record_name, "."), ".${var.dns_zone}")
      type          = option.resource_record_type
      target        = trimsuffix(option.resource_record_value, ".")
    }
  }
}
```

Then add:

- `aws_ecr_repository.app` with image scanning and AES256 encryption.
- `aws_iam_role.lambda_execution`.
- `aws_iam_role_policy_attachment.lambda_basic_logs` using `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`.
- `aws_cloudwatch_log_group.lambda` with `/aws/lambda/${local.lambda_name}` and 14-day retention.
- `aws_lambda_function.app` using `package_type = "Image"` and `image_uri = var.image_uri`.
- `aws_apigatewayv2_api.http` with `protocol_type = "HTTP"`.
- `aws_apigatewayv2_integration.lambda` using AWS proxy integration and payload format `2.0`.
- `aws_apigatewayv2_route.root` for `ANY /`.
- `aws_apigatewayv2_route.proxy` for `ANY /{proxy+}`.
- `aws_apigatewayv2_stage.api` with `auto_deploy = true`.
- `aws_lambda_permission.api_gateway`.
- `aws_acm_certificate.api` with DNS validation and `create_before_destroy`.
- Optional `aws_lightsail_domain.zone` controlled by `create_lightsail_domain`.
- `aws_lightsail_domain_entry.acm_validation` for each ACM validation record.
- `aws_acm_certificate_validation.api` depending on the Lightsail validation entries.
- `aws_apigatewayv2_domain_name.api` with `REGIONAL` and `TLS_1_2`.
- `aws_apigatewayv2_api_mapping.api`.
- `aws_lightsail_domain_entry.api_cname` pointing the API subdomain to the API Gateway target domain.
- Optional `aws_iam_openid_connect_provider.github` when `github_oidc_provider_arn` is empty.
- `aws_iam_role.github_deploy`.
- `aws_iam_role_policy.github_deploy` for ECR push and Lambda image updates.

- [ ] **Step 4: Add Terraform outputs**

Create `infra/terraform/outputs.tf` with outputs:

```hcl
output "aws_account_id" { value = data.aws_caller_identity.current.account_id }
output "aws_region" { value = var.aws_region }
output "project_name" { value = var.project_name }
output "deploy_env" { value = var.deploy_env }
output "ecr_repository_name" { value = aws_ecr_repository.app.name }
output "ecr_repository_uri" { value = aws_ecr_repository.app.repository_url }
output "image_uri" { value = var.image_uri }
output "lambda_function_name" { value = aws_lambda_function.app.function_name }
output "lambda_function_arn" { value = aws_lambda_function.app.arn }
output "api_id" { value = aws_apigatewayv2_api.http.id }
output "api_stage" { value = aws_apigatewayv2_stage.api.name }
output "api_invoke_url" { value = aws_apigatewayv2_stage.api.invoke_url }
output "api_custom_domain_url" { value = "https://${var.api_domain}" }
output "api_gateway_target_domain_name" { value = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name }
output "acm_certificate_arn" { value = aws_acm_certificate.api.arn }
output "dns_zone" { value = var.dns_zone }
output "api_dns_record_name" { value = local.api_subdomain_name }
output "github_deploy_role_arn" { value = aws_iam_role.github_deploy.arn }
output "github_oidc_subject" { value = local.github_subject }
```

- [ ] **Step 5: Add Terraform usage notes**

Create `infra/terraform/README.md` explaining:

- Prefer `scripts/deploy.ps1` for first-time setup.
- Direct Terraform use requires `image_uri`.
- ECR may be imported by the script when it already exists.
- Lightsail DNS zone must either already exist or be created by `create_lightsail_domain`.
- Lambda environment variables can be stored in Terraform state; avoid putting secrets there unless this is acceptable.

- [ ] **Step 6: Format and validate Terraform**

Run:

```powershell
terraform -chdir=infra/terraform fmt
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate
```

Expected: `terraform validate` reports success. If Terraform is not installed, record that verification is blocked.

- [ ] **Step 7: Commit Terraform files**

Run:

```powershell
git add infra/terraform
git commit -m "Add Terraform AWS deployment infrastructure"
```

Expected: commit succeeds.

---

### Task 3: PowerShell Deployment Runner

**Files:**
- Create: `scripts/deploy.ps1`

**Interfaces:**
- Consumes: `.env`, process environment variables, Terraform files from Task 2, local Docker context.
- Produces: `infra/terraform/generated/<project>-<env>.auto.tfvars.json`, Docker image in ECR, Terraform-managed AWS resources, `reports/deploy-*.md`, and `reports/deploy-*.json`.

- [ ] **Step 1: Create script parameters and constants**

Create `scripts/deploy.ps1` with:

```powershell
[CmdletBinding()]
param(
    [string]$EnvFile = ".env",
    [switch]$NonInteractive,
    [switch]$PlanOnly,
    [switch]$SkipDockerBuild
)

$ErrorActionPreference = "Stop"
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:TerraformDir = Join-Path $script:RepoRoot "infra\terraform"
$script:GeneratedDir = Join-Path $script:TerraformDir "generated"
$script:ReportsDir = Join-Path $script:RepoRoot "reports"
$script:RunStartedAt = Get-Date
$script:RunId = $script:RunStartedAt.ToString("yyyyMMdd-HHmmss")
$script:CommandResults = New-Object System.Collections.Generic.List[object]
$script:Warnings = New-Object System.Collections.Generic.List[string]
```

- [ ] **Step 2: Add environment loading and prompting helpers**

Add functions:

```powershell
function Import-DotEnvFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) { return }
        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        if (-not [Environment]::GetEnvironmentVariable($name, "Process")) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
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
    if ($value) { return $value }
    if ($Default) { $display = "$Prompt [$Default]" } else { $display = $Prompt }

    if ($NonInteractive -and $Required -and -not $Default) {
        throw "Missing required environment variable $Name"
    }

    if ($NonInteractive) { return $Default }

    if ($Secret) {
        $secure = Read-Host $display -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } else {
        $value = Read-Host $display
    }

    if (-not $value) { $value = $Default }
    if ($Required -and -not $value) { throw "Missing required value for $Name" }
    [Environment]::SetEnvironmentVariable($Name, $value, "Process")
    return $value
}
```

- [ ] **Step 3: Add command execution and redaction helpers**

Add functions:

```powershell
function Redact-Value {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $secretPatterns = @(
        [Environment]::GetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", "Process"),
        [Environment]::GetEnvironmentVariable("AWS_ACCESS_KEY_ID", "Process")
    ) | Where-Object { $_ }
    foreach ($secret in $secretPatterns) {
        $text = $text.Replace($secret, "[REDACTED]")
    }
    $text = $text -replace '(?i)(database_url|private_key|secret|password|token)["'']?\s*[:=]\s*["'']?[^,"''\r\n]+', '$1=[REDACTED]'
    return $text
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
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $record = [ordered]@{
        name = $Name
        command = "$FilePath $($Arguments -join ' ')"
        exit_code = $exitCode
        output = Redact-Value (($output | Out-String).Trim())
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
```

- [ ] **Step 4: Add AWS and Terraform bootstrap helpers**

Add functions:

```powershell
function Get-AwsAccountId {
    $json = Invoke-CheckedCommand -Name "aws sts get-caller-identity" -FilePath "aws" -Arguments @("sts", "get-caller-identity", "--output", "json")
    return (($json | Out-String) | ConvertFrom-Json).Account
}

function Get-GithubOidcProviderArn {
    param([string]$AccountId)
    $providersJson = Invoke-CheckedCommand -Name "aws iam list-open-id-connect-providers" -FilePath "aws" -Arguments @("iam", "list-open-id-connect-providers", "--output", "json") -AllowFailure
    if ($LASTEXITCODE -ne 0) { return "" }
    $providers = (($providersJson | Out-String) | ConvertFrom-Json).OpenIDConnectProviderList
    $match = $providers | Where-Object { $_.Arn -eq "arn:aws:iam::$AccountId:oidc-provider/token.actions.githubusercontent.com" } | Select-Object -First 1
    if ($match) { return $match.Arn }
    return ""
}

function Test-EcrRepositoryExists {
    param([string]$RepositoryName, [string]$Region)
    Invoke-CheckedCommand -Name "aws ecr describe-repositories" -FilePath "aws" -Arguments @("ecr", "describe-repositories", "--repository-names", $RepositoryName, "--region", $Region, "--output", "json") -AllowFailure | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-TerraformStateHasResource {
    param([string]$Address)
    $state = Invoke-CheckedCommand -Name "terraform state list" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "state", "list") -AllowFailure
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($state | Out-String) -split "`r?`n") -contains $Address
}

function Write-TfVarsFile {
    param([hashtable]$Config)
    New-Item -ItemType Directory -Force -Path $script:GeneratedDir | Out-Null
    $path = Join-Path $script:GeneratedDir "$($Config.project_name)-$($Config.deploy_env).auto.tfvars.json"
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
```

- [ ] **Step 5: Add Docker build and push helpers**

Add functions:

```powershell
function Invoke-EcrLogin {
    param([string]$Region, [string]$Registry)
    $password = & aws ecr get-login-password --region $Region
    if ($LASTEXITCODE -ne 0) { throw "aws ecr get-login-password failed" }
    $password | docker login --username AWS --password-stdin $Registry | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker login failed" }
    $script:CommandResults.Add([pscustomobject]@{
        name = "docker login"
        command = "aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $Registry"
        exit_code = 0
        output = ""
    })
}

function Invoke-DockerBuildAndPush {
    param(
        [string]$ImageUri,
        [string]$DockerfilePath,
        [string]$DockerContext
    )
    Invoke-CheckedCommand -Name "docker build" -FilePath "docker" -Arguments @("build", "-f", $DockerfilePath, "-t", $ImageUri, $DockerContext)
    Invoke-CheckedCommand -Name "docker push" -FilePath "docker" -Arguments @("push", $ImageUri)
}
```

- [ ] **Step 6: Add report generation**

Add functions:

```powershell
function Get-TerraformOutputs {
    $json = Invoke-CheckedCommand -Name "terraform output" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "output", "-json") -AllowFailure
    if ($LASTEXITCODE -ne 0) { return @{} }
    return (($json | Out-String) | ConvertFrom-Json)
}

function Write-DeploymentReport {
    param(
        [hashtable]$Config,
        [string]$Status,
        [object]$TerraformOutputs,
        [string]$ErrorMessage = ""
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
        run_id = $script:RunId
        started_at = $script:RunStartedAt.ToString("o")
        finished_at = (Get-Date).ToString("o")
        status = $Status
        config = $safeConfig
        terraform_outputs = $TerraformOutputs
        commands = $script:CommandResults
        warnings = $script:Warnings
        error = (Redact-Value $ErrorMessage)
    }

    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = @(
        "# Deployment Report $script:RunId",
        "",
        "- Status: $Status",
        "- Project: $($safeConfig.project_name)",
        "- Environment: $($safeConfig.deploy_env)",
        "- Region: $($safeConfig.aws_region)",
        "- API domain: $($safeConfig.api_domain)",
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
        foreach ($warning in $script:Warnings) { $lines += "- $warning" }
    }
    if ($ErrorMessage) {
        $lines += ""
        $lines += "## Error"
        $lines += Redact-Value $ErrorMessage
    }
    $lines | Set-Content -LiteralPath $mdPath -Encoding UTF8
}
```

- [ ] **Step 7: Add main execution flow**

At the bottom of `scripts/deploy.ps1`, implement:

```powershell
$status = "failed"
$errorMessage = ""
$config = @{}
try {
    Import-DotEnvFile -Path (Join-Path $script:RepoRoot $EnvFile)
    Assert-CommandExists "aws"
    Assert-CommandExists "docker"
    Assert-CommandExists "terraform"

    $awsRegion = Get-ConfigValue -Name "AWS_REGION" -Prompt "AWS region" -Default "ap-south-1" -Required
    $projectName = Get-ConfigValue -Name "PROJECT_NAME" -Prompt "Project name" -Default "mju-be" -Required
    $deployEnv = Get-ConfigValue -Name "DEPLOY_ENV" -Prompt "Deployment environment" -Default "dev" -Required
    $apiDomain = Get-ConfigValue -Name "API_DOMAIN" -Prompt "API domain" -Default "api.dev.myjainuniverse.com" -Required
    $dnsZone = Get-ConfigValue -Name "DNS_ZONE" -Prompt "Lightsail DNS zone" -Default "myjainuniverse.com" -Required
    $githubRepository = Get-ConfigValue -Name "GITHUB_REPOSITORY" -Prompt "GitHub repository owner/repo" -Default "SamyakTechLabs/mju-be" -Required
    $githubEnvironment = Get-ConfigValue -Name "GITHUB_ENVIRONMENT" -Prompt "GitHub environment" -Default $deployEnv -Required
    $lambdaMemory = [int](Get-ConfigValue -Name "LAMBDA_MEMORY_SIZE" -Prompt "Lambda memory size" -Default "512" -Required)
    $lambdaTimeout = [int](Get-ConfigValue -Name "LAMBDA_TIMEOUT" -Prompt "Lambda timeout seconds" -Default "30" -Required)
    $dockerfilePath = Get-ConfigValue -Name "DOCKERFILE_PATH" -Prompt "Dockerfile path" -Default "Dockerfile" -Required
    $dockerContext = Get-ConfigValue -Name "DOCKER_CONTEXT" -Prompt "Docker build context" -Default "." -Required

    Get-ConfigValue -Name "AWS_ACCESS_KEY_ID" -Prompt "AWS access key ID" -Required | Out-Null
    Get-ConfigValue -Name "AWS_SECRET_ACCESS_KEY" -Prompt "AWS secret access key" -Required -Secret | Out-Null

    if ($githubRepository -notmatch "^[^/]+/[^/]+$") { throw "GITHUB_REPOSITORY must use owner/repo format" }
    if ($apiDomain -eq $dnsZone) { throw "API_DOMAIN must be a subdomain of DNS_ZONE, not the zone apex" }

    $accountId = Get-AwsAccountId
    $registry = "$accountId.dkr.ecr.$awsRegion.amazonaws.com"
    $imageTag = "bootstrap-$script:RunId"
    $imageUri = "$registry/$projectName:$imageTag"
    $oidcArn = Get-GithubOidcProviderArn -AccountId $accountId

    $lambdaEnv = @{}
    $lambdaEnvJson = [Environment]::GetEnvironmentVariable("LAMBDA_ENV_JSON", "Process")
    if ($lambdaEnvJson) { $lambdaEnv = ConvertFrom-Json $lambdaEnvJson -AsHashtable }

    $config = @{
        aws_region = $awsRegion
        project_name = $projectName
        deploy_env = $deployEnv
        api_domain = $apiDomain
        dns_zone = $dnsZone
        image_uri = $imageUri
        lambda_memory_size = $lambdaMemory
        lambda_timeout = $lambdaTimeout
        lambda_environment_variables = $lambdaEnv
        github_repository = $githubRepository
        github_environment = $githubEnvironment
        github_oidc_provider_arn = $oidcArn
        create_lightsail_domain = $false
    }

    $tfvarsPath = Write-TfVarsFile -Config $config

    Invoke-CheckedCommand -Name "terraform init" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "init")

    if (-not (Test-TerraformStateHasResource -Address "aws_ecr_repository.app")) {
        if (Test-EcrRepositoryExists -RepositoryName $projectName -Region $awsRegion) {
            Invoke-CheckedCommand -Name "terraform import ecr" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "import", "-var-file=$tfvarsPath", "aws_ecr_repository.app", $projectName)
        } else {
            Invoke-CheckedCommand -Name "terraform apply ecr target" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "apply", "-target=aws_ecr_repository.app", "-var-file=$tfvarsPath", "-auto-approve")
        }
    }

    Invoke-EcrLogin -Region $awsRegion -Registry $registry
    if (-not $SkipDockerBuild) {
        Invoke-DockerBuildAndPush -ImageUri $imageUri -DockerfilePath $dockerfilePath -DockerContext $dockerContext
    } else {
        $script:Warnings.Add("Docker build was skipped; image URI must already exist: $imageUri")
    }

    Invoke-CheckedCommand -Name "terraform plan" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "plan", "-var-file=$tfvarsPath", "-out=generated\$projectName-$deployEnv.tfplan")
    if (-not $PlanOnly) {
        Invoke-CheckedCommand -Name "terraform apply" -FilePath "terraform" -Arguments @("-chdir=$script:TerraformDir", "apply", "generated\$projectName-$deployEnv.tfplan")
    }

    $status = if ($PlanOnly) { "planned" } else { "applied" }
} catch {
    $errorMessage = $_.Exception.Message
    throw
} finally {
    $outputs = Get-TerraformOutputs
    Write-DeploymentReport -Config $config -Status $status -TerraformOutputs $outputs -ErrorMessage $errorMessage
}
```

- [ ] **Step 8: Validate PowerShell syntax**

Run:

```powershell
$errors = $null
[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw scripts\deploy.ps1), [ref]$errors) | Out-Null
if ($errors) { $errors | Format-List; exit 1 }
```

Expected: no parser errors.

- [ ] **Step 9: Commit deployment runner**

Run:

```powershell
git add scripts/deploy.ps1
git commit -m "Add automated deployment runner"
```

Expected: commit succeeds.

---

### Task 4: GitHub Actions Example

**Files:**
- Create: `.github/workflows/deploy-lambda.yml.example`
- Modify: `README.md`

**Interfaces:**
- Consumes: Terraform output `github_deploy_role_arn`, ECR repository URI, region, project name, and Lambda function name.
- Produces: A copy-pasteable workflow example for any public or private GitHub repository.

- [ ] **Step 1: Add workflow example**

Create `.github/workflows/deploy-lambda.yml.example` with:

```yaml
name: Deploy Lambda Container

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1
  ECR_REPOSITORY: mju-be
  LAMBDA_FUNCTION_NAME: mju-be-dev

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: arn:aws:iam::123456789012:role/mju-be-dev-github-deploy-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v3

      - name: Build and push image
        env:
          REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t "$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" .
          docker push "$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
          echo "IMAGE_URI=$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> "$GITHUB_ENV"

      - name: Update Lambda image
        run: |
          aws lambda update-function-code \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --image-uri "$IMAGE_URI"

      - name: Wait for Lambda update
        run: |
          aws lambda wait function-updated \
            --function-name "$LAMBDA_FUNCTION_NAME"
```

- [ ] **Step 2: Document workflow customization**

Add to `README.md`:

```markdown
## GitHub Actions Deployment

After the first local setup, copy `.github/workflows/deploy-lambda.yml.example` to `.github/workflows/deploy-lambda.yml` in your target repository.

Replace:

- `environment`
- `AWS_REGION`
- `ECR_REPOSITORY`
- `LAMBDA_FUNCTION_NAME`
- `role-to-assume`

Use the latest generated report for the exact values.
```

- [ ] **Step 3: Commit workflow example**

Run:

```powershell
git add .github/workflows/deploy-lambda.yml.example README.md
git commit -m "Add GitHub Actions deployment example"
```

Expected: commit succeeds.

---

### Task 5: Final Verification

**Files:**
- Modify only if verification finds a concrete defect.

**Interfaces:**
- Consumes: All files from Tasks 1-4.
- Produces: Verified deployment scaffold ready for a real AWS run.

- [ ] **Step 1: Check repository status**

Run:

```powershell
git status --short --branch
```

Expected: clean working tree on `master` or the active feature branch.

- [ ] **Step 2: Run file search sanity check**

Run:

```powershell
$patterns = @("TO" + "DO", "TB" + "D", "FIX" + "ME", "AWS_SECRET_ACCESS_KEY=.*[^ ]", "123456789012")
rg -n ($patterns -join "|") .
```

Expected: only the intentional placeholder account ID in `.github/workflows/deploy-lambda.yml.example`, if present. No real secrets.

- [ ] **Step 3: Run Terraform formatting and validation**

Run:

```powershell
terraform -chdir=infra/terraform fmt -check
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate
```

Expected: Terraform format check and validate pass. If Terraform is not installed, state that verification is blocked by missing Terraform.

- [ ] **Step 4: Run PowerShell parser validation**

Run:

```powershell
$errors = $null
[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw scripts\deploy.ps1), [ref]$errors) | Out-Null
if ($errors) { $errors | Format-List; exit 1 }
```

Expected: no parser errors.

- [ ] **Step 5: Review generated reports behavior**

Read `scripts/deploy.ps1` and confirm every normal or failed run enters the `finally` block and calls `Write-DeploymentReport`.

- [ ] **Step 6: Commit final verification fixes**

If any corrections were needed, run:

```powershell
git add .
git commit -m "Fix deployment scaffold verification issues"
```

Expected: commit succeeds if changes were made; otherwise no commit is needed.
