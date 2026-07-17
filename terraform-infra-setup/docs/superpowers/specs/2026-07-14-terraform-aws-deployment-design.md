# Terraform AWS Deployment Design

Date: 2026-07-14

## Goal

Create a reusable Terraform-based deployment scaffold for the MJU backend. The scaffold should provision the AWS infrastructure described in the deployment documentation and provide a guided setup experience similar to modern project generators.

The deployment must support full automatic setup:

- Read AWS administrator credentials from environment variables.
- Prompt for missing project values in an interactive terminal flow.
- Build and push the first Lambda container image automatically.
- Provision AWS resources with Terraform.
- Manage Lightsail DNS records automatically.
- Generate a Markdown and JSON report for every run.

## Inputs

The runner accepts values from environment variables first, then asks interactively for anything missing.

Required or prompted values:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`, default `ap-south-1`
- `PROJECT_NAME`, default `mju-be`
- `DEPLOY_ENV`, default `dev`
- `API_DOMAIN`, for example `api.dev.myjainuniverse.com`
- `DNS_ZONE`, default `myjainuniverse.com`
- `GITHUB_REPOSITORY`, default `SamyakTechLabs/mju-be`, using `owner/repo` format for any public or private GitHub repository
- `GITHUB_ENVIRONMENT`, default matching `DEPLOY_ENV`
- `LAMBDA_MEMORY_SIZE`, default `512`
- `LAMBDA_TIMEOUT`, default `30`
- `DOCKERFILE_PATH`, default `Dockerfile`
- `DOCKER_CONTEXT`, default repository root

Optional app environment variables are passed into the Lambda function through Terraform variables. Sensitive values should not be printed in reports.

The core deployment does not require a GitHub personal access token or GitHub OAuth connection. If future requirements include automatically creating GitHub repository environments, variables, or secrets, the tool can add an optional GitHub API integration with an explicit token or GitHub App flow.

## Architecture

Use a small orchestration script plus Terraform.

The orchestration script handles tasks that are awkward for Terraform alone:

- Validate local tools: AWS CLI, Docker, Terraform.
- Confirm AWS credentials with `sts get-caller-identity`.
- Create or discover the ECR repository before the first image push.
- Authenticate Docker to ECR.
- Build and push an initial container image tag.
- Generate Terraform variable files for the selected environment.
- Run `terraform init`, `terraform plan`, and `terraform apply`.
- Write per-run reports.

Terraform owns the long-lived cloud resources:

- ECR repository.
- Lambda execution role and permissions.
- Lambda container function using the pushed image.
- CloudWatch log group.
- API Gateway HTTP API.
- Lambda integration.
- Routes `ANY /` and `ANY /{proxy+}`.
- API Gateway stage.
- Lambda invoke permission for API Gateway.
- ACM certificate for the API domain.
- Lightsail DNS record for ACM validation.
- API Gateway custom domain.
- API Gateway API mapping.
- Lightsail DNS CNAME pointing the API subdomain to the API Gateway regional domain.
- GitHub Actions OIDC provider, deploy role, trust policy, and ECR/Lambda update permissions.

## GitHub Repository Support

The deployment supports any GitHub repository, including private repositories, by asking for `GITHUB_REPOSITORY` in `owner/repo` format. Terraform creates an AWS IAM role that trusts GitHub Actions OIDC tokens from that exact repository and environment.

This is AWS-side authorization for GitHub Actions deployments. It does not require the setup tool to log in to GitHub, read repository contents, or store GitHub credentials. The repository only needs a workflow configured to request an OIDC token and assume the generated AWS role.

The generated report should include the role ARN and the GitHub Actions environment values needed by the workflow. If a private repository needs automatic GitHub environment or secret creation, that should be treated as an optional extension because it requires separate GitHub API authorization.

Python or FastAPI is not required for the first version. A backend service would only be useful later for a hosted dashboard, GitHub OAuth repo picker, or multi-user deployment portal. The first version should stay as a local PowerShell orchestration script plus Terraform to reduce credentials, hosting, and maintenance risk.

## Flow

1. User runs `scripts/deploy.ps1`.
2. Script loads `.env` if present and reads process environment variables.
3. Script prompts for missing deployment values.
4. Script validates AWS credentials and resolves the AWS account ID.
5. Script creates or confirms the target ECR repository.
6. Script builds the Docker image from the configured Docker context.
7. Script pushes the image to ECR with a bootstrap tag.
8. Script writes a generated Terraform variable file for the run.
9. Script runs Terraform.
10. Terraform provisions or updates the AWS infrastructure.
11. Script captures Terraform outputs and writes run reports.

## Reporting

Each run creates two files under `reports/`:

- `deploy-YYYYMMDD-HHMMSS.md`
- `deploy-YYYYMMDD-HHMMSS.json`

Reports include:

- Timestamp.
- AWS account ID.
- Region.
- Project name.
- Environment.
- API domain.
- ECR repository URI.
- Image tag and image URI.
- Lambda function name and ARN.
- API Gateway ID, stage, invoke URL, and custom domain URL.
- ACM certificate ARN and validation status when available.
- Lightsail DNS zone and managed records.
- GitHub OIDC role ARN.
- Terraform command status.
- Warnings and manual follow-up items.

Reports must redact secrets and must not print `AWS_SECRET_ACCESS_KEY`, app secrets, private keys, database URLs, or Terraform sensitive outputs.

## Error Handling

The script stops early when required local tools are missing, credentials are invalid, Docker is unavailable, or the Docker build fails.

If ACM validation or API custom domain readiness is delayed, Terraform should create the validation DNS record and wait where practical. The report should still make the current status visible and list any follow-up checks.

Terraform resources should use names derived from `PROJECT_NAME` and `DEPLOY_ENV` to avoid accidental collisions across environments.

## Testing And Verification

Static verification:

- Run `terraform fmt`.
- Run `terraform validate`.
- Run PowerShell parser validation for the deployment script.

Runtime verification, when AWS credentials and Docker are available:

- Confirm ECR repository creation.
- Confirm image push.
- Confirm Terraform apply success.
- Confirm Lambda function package type is `Image`.
- Confirm API Gateway routes exist.
- Confirm custom domain outputs are present.

The first implementation should avoid destructive cleanup automation. Destroying infrastructure should remain an explicit Terraform operation by the user.
