# AWS Lambda Container MVP Deployment

This repository contains a simple Terraform and PowerShell scaffold for creating the essential AWS infrastructure for a backend running as a Lambda container image.

The MVP creates:

- Amazon ECR repository
- Lambda execution role
- CloudWatch log group
- Lambda function using a container image
- API Gateway HTTP API
- `ANY /` and `ANY /{proxy+}` routes
- API Gateway permission to invoke Lambda
- Markdown and JSON deployment reports

GitHub repository integration, custom domains, ACM certificates, and Lightsail DNS are intentionally left out of the MVP path. They can be added later after the basic infrastructure flow is working.

## Prerequisites

- AWS administrator credentials exported as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- AWS CLI
- Docker
- Terraform
- Docker, used to build the built-in placeholder Lambda image
- Windows PowerShell 5.1+ on Windows, or PowerShell 7+ (`pwsh`) on macOS/Linux

## Quick Start

Windows PowerShell:

```powershell
$env:AWS_ACCESS_KEY_ID = "..."
$env:AWS_SECRET_ACCESS_KEY = "..."
.\scripts\deploy.ps1
```

macOS/Linux:

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
pwsh -File ./scripts/deploy.ps1
```

The script prompts for missing values, builds and pushes the built-in placeholder Lambda image, runs Terraform, and writes reports under `reports/`.

## Non-Interactive Mode

Set the values shown in `env.example`, then run:

Windows PowerShell:

```powershell
.\scripts\deploy.ps1 -NonInteractive
```

macOS/Linux:

```bash
pwsh -File ./scripts/deploy.ps1 -NonInteractive
```

Use `-PlanOnly` to stop after Terraform plan. Use `-SkipDockerBuild` only when the generated image URI already exists in ECR.

## Placeholder Lambda Image

This project is self-contained for first-time infrastructure creation. By default it builds `infra/bootstrap-image/Dockerfile`, pushes that temporary Lambda image to ECR, and creates the Lambda function from it. The placeholder API response confirms the infrastructure is ready; later, your application CI can push a real image to the same ECR repository and update the Lambda function.

Use `DOCKER_BUILD_CONTEXT` for the build folder. Do not use `DOCKER_CONTEXT` for this setting because Docker reserves that environment variable for Docker CLI contexts.

## Reports

Every run writes:

- `reports/deploy-YYYYMMDD-HHMMSS.md`
- `reports/deploy-YYYYMMDD-HHMMSS.json`

Reports include the selected config, ECR repository URI, image URI, Lambda name and ARN, API Gateway URL, command statuses, warnings, and errors. Secrets are redacted.

## Slack Notifications

Set `SLACK_WEBHOOK_URL` in your local `.env` file or shell to receive a Slack message after every run:

```powershell
$env:SLACK_WEBHOOK_URL = "<your Slack incoming webhook URL>"
```

Notifications are sent for successful applies, plan-only runs, and failures. They include the project, environment, region, image URI, Terraform change summary when available, API URL when available, and report file paths.

The webhook URL is treated as a secret and should not be committed. If a webhook is exposed in chat, rotate it in Slack and use the new value locally.

## Direct Terraform Use

Prefer `scripts/deploy.ps1` for first-time setup because Lambda container functions require an image that already exists in ECR. If using Terraform directly, provide a valid `image_uri` in a tfvars file.
