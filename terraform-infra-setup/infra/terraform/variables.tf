variable "aws_region" {
  description = "AWS region where the MVP infrastructure is created."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short project name used for default resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{1,62}$", var.project_name))
    error_message = "project_name must be 2-63 characters and contain only letters, numbers, underscores, or hyphens."
  }
}

variable "deploy_env" {
  description = "Deployment environment name, such as dev, staging, or prod."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{1,31}$", var.deploy_env))
    error_message = "deploy_env must be 2-32 characters and contain only letters, numbers, underscores, or hyphens."
  }
}

variable "ecr_repository_name" {
  description = "ECR repository name. Defaults to project_name when empty."
  type        = string
  default     = ""
}

variable "image_uri" {
  description = "Full ECR image URI used by the Lambda function."
  type        = string
}

variable "api_stage" {
  description = "HTTP API stage name. Use $default for the default stage."
  type        = string
  default     = "$default"
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 512

  validation {
    condition     = var.lambda_memory_size >= 128 && var.lambda_memory_size <= 10240
    error_message = "lambda_memory_size must be between 128 and 10240."
  }
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 30

  validation {
    condition     = var.lambda_timeout >= 1 && var.lambda_timeout <= 900
    error_message = "lambda_timeout must be between 1 and 900."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

variable "lambda_environment_variables" {
  description = "Additional Lambda environment variables. Avoid secrets unless Terraform state is secured."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "tags" {
  description = "Additional tags applied to supported AWS resources."
  type        = map(string)
  default     = {}
}
