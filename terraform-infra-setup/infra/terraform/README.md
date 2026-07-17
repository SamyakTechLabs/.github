# MVP Terraform Infrastructure

This Terraform project creates the essential AWS resources for a Lambda container backend:

- ECR repository
- Lambda execution IAM role
- CloudWatch log group
- Lambda function using an existing ECR image URI
- API Gateway HTTP API
- `ANY /` and `ANY /{proxy+}` routes
- Lambda invoke permission for API Gateway

Use `../../scripts/deploy.ps1` for first-time setup. The script creates or imports ECR first, builds and pushes an initial image, then applies the full Terraform stack.

Direct Terraform usage requires a valid image URI:

```powershell
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform apply -var-file=generated/mju-be-dev.auto.tfvars.json
```

Avoid putting long-lived secrets in `lambda_environment_variables` unless your Terraform state is stored securely.
