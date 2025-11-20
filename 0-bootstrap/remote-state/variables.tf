variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 para guardar el state de Terraform"
  default     = "yp-test-tf-state"
}

variable "lock_table_name" {
  type        = string
  description = "Nombre de la tabla DynamoDB para locks de Terraform"
  default     = "tf-locks-yp-test"
}