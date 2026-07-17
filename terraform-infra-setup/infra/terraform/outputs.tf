output "aws_account_id" {
  description = "AWS account ID used by Terraform."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region."
  value       = var.aws_region
}

output "project_name" {
  description = "Project name."
  value       = var.project_name
}

output "deploy_env" {
  description = "Deployment environment."
  value       = var.deploy_env
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_uri" {
  description = "ECR repository URI."
  value       = aws_ecr_repository.app.repository_url
}

output "image_uri" {
  description = "Lambda container image URI."
  value       = var.image_uri
}

output "lambda_function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.app.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.app.arn
}

output "api_id" {
  description = "API Gateway HTTP API ID."
  value       = aws_apigatewayv2_api.http.id
}

output "api_stage" {
  description = "API Gateway stage name."
  value       = aws_apigatewayv2_stage.api.name
}

output "api_invoke_url" {
  description = "API Gateway invoke URL."
  value       = aws_apigatewayv2_stage.api.invoke_url
}
