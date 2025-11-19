variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "massnexus-prd"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "db_username" {
  type    = string
  default = "appuser"
}


variable "db_backup_days" {
  type    = number
  default = 7
}

variable "db_name" {
  type    = string
  default = "app"
}


variable "db_allocated" {
  type    = number
  default = 50
}

variable "db_instance_cls" {
  type    = string
  default = "db.t4g.medium"
}

variable "backend_domain_zone_id" {
  type    = string
  default = "" # Route53 Hosted Zone ID (si usás Route53). Si no, lo dejás vacío.
}

variable "allowed_cidr" {
  type    = string
  default = "190.19.143.121/32"
}

variable "frontend_domain_name" {
  type    = string
  default = "uat.yieldpro.io"
}

variable "backend_domain_name" {
  type    = string
  default = "dev.yieldpro.io"
}

variable "github_repo_front" {
  type    = string
  default = "beatsmedia/yieldpro_front_tmp"
}

variable "github_repo_back" {
  type    = string
  default = "beatsmedia/yieldpro_back_tmp"
}

variable "alert_email" {
  type        = string
  description = "Email para recibir alertas de CloudWatch (RDS, Redis, EC2, ALB)"
  default     = "ops@massnexus.com" # CAMBIAR POR TU EMAIL REAL
}

variable "security_alert_email" {
  type        = string
  description = "Email para recibir alertas de seguridad (GuardDuty, CloudTrail)"
  default     = "security@massnexus.com" # CAMBIAR POR TU EMAIL REAL
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Habilitar NAT Gateway (recomendado para prod real, pero cuesta ~$32/mes por NAT)"
  default     = false # Deshabilitado por defecto, usa VPC Endpoints
}

variable "allowed_ips_alb" {
  type        = list(string)
  description = "IPs permitidas para acceder al ALB. Público con Cloudflare Zero Trust controlando acceso"
  default = [
    "0.0.0.0/0", # Acceso público - Cloudflare Zero Trust maneja autenticación
  ]
}

variable "use_private_subnets_for_ec2" {
  type        = bool
  description = "Usar subnets privadas para EC2 (requiere NAT Gateway o VPC Endpoints). False = subnets públicas"
  default     = false # False por defecto para testing sin NAT
}