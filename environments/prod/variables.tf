########################
# REGIÓN Y PROYECTO
########################

variable "region" {
  type        = string
  description = "AWS region donde se desplegará la infraestructura"
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]{1}$", var.region))
    error_message = "La región debe tener formato válido de AWS (ej: us-east-1, us-west-2, eu-west-1)"
  }
}

variable "name" {
  type        = string
  description = "Nombre del proyecto/aplicación. Se usa como prefijo para todos los recursos (ej: yp-test-alb, yp-test-rds)"
  default     = "yp-test"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name)) && length(var.name) <= 32
    error_message = "El nombre debe contener solo letras minúsculas, números y guiones, máximo 32 caracteres"
  }
}

########################
# NETWORKING
########################

variable "vpc_cidr" {
  type        = string
  description = "CIDR block para la VPC. Debe ser /16 para tener suficientes subnets. Prod: 10.0.0.0/16, Staging: 10.1.0.0/16"
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "El VPC CIDR debe ser un bloque CIDR válido (ej: 10.0.0.0/16)"
  }
}

variable "az_count" {
  type        = number
  description = "Número de Availability Zones a usar. Mínimo 2 para alta disponibilidad (Multi-AZ para RDS, Redis, ALB)"
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "El número de AZs debe ser entre 2 y 6. Se recomienda 2 para prod (balance costo/HA)"
  }
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Habilitar NAT Gateway para salida a internet desde subnets privadas. COSTO: ~$32/mes por NAT. False usa VPC Endpoints (sin costo)"
  default     = false # Deshabilitado por defecto, usa VPC Endpoints (ahorro de ~$64/mes con 2 AZs)
}

variable "use_private_subnets_for_ec2" {
  type        = bool
  description = "Colocar instancias EC2 en subnets privadas. Requiere NAT Gateway o VPC Endpoints para acceso a AWS APIs"
  default     = false # False = subnets públicas (para testing sin NAT Gateway)
}

########################
# ACCESO Y SEGURIDAD
########################

variable "allowed_cidr" {
  type        = string
  description = "[STAGING] CIDR permitido para acceso. Prod usa allowed_ips_alb. Ejemplo: '190.19.143.121/32' (tu IP pública)"
  default     = "190.19.143.121/32"

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "Debe ser un CIDR válido (ej: 190.19.143.121/32 para una IP, 10.0.0.0/8 para una red)"
  }
}

variable "allowed_ips_alb" {
  type        = list(string)
  description = "[PROD] Lista de CIDRs permitidos para acceder al ALB. ['0.0.0.0/0'] = público (Cloudflare Zero Trust controla acceso)"
  default = [
    "0.0.0.0/0", # Acceso público - Cloudflare Zero Trust maneja autenticación
  ]
}

########################
# BASE DE DATOS (RDS MySQL)
########################

variable "db_name" {
  type        = string
  description = "Nombre de la base de datos inicial en RDS. Solo letras minúsculas y guiones bajos"
  default     = "app"

  validation {
    condition     = can(regex("^[a-z_]+$", var.db_name)) && length(var.db_name) <= 64
    error_message = "El nombre de DB debe contener solo letras minúsculas y guiones bajos, máximo 64 caracteres"
  }
}

variable "db_username" {
  type        = string
  description = "Usuario master de RDS. La contraseña se genera automáticamente y se guarda en Secrets Manager"
  default     = "appuser"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.db_username)) && length(var.db_username) >= 3
    error_message = "El username debe empezar con letra, contener solo letras/números/guiones bajos, mínimo 3 caracteres"
  }
}

variable "db_instance_cls" {
  type        = string
  description = "Clase de instancia RDS. Prod: db.t4g.medium (2vCPU/4GB), Staging: db.t4g.small (2vCPU/2GB), Testing: db.t4g.micro (2vCPU/1GB)"
  default     = "db.t4g.medium"
  # Opciones comunes:
  # - db.t4g.micro   (1GB RAM)  - Solo testing/dev
  # - db.t4g.small   (2GB RAM)  - Staging con carga baja
  # - db.t4g.medium  (4GB RAM)  - Prod con carga normal
  # - db.r6g.large   (16GB RAM) - Prod con alta carga
}

variable "db_allocated" {
  type        = number
  description = "Storage inicial de RDS en GB. Autoscaling habilitado hasta 1000GB. Mínimo 20GB para gp3"
  default     = 50

  validation {
    condition     = var.db_allocated >= 20 && var.db_allocated <= 1000
    error_message = "El storage debe ser entre 20GB (mínimo para gp3) y 1000GB (límite de autoscaling)"
  }
}

variable "db_backup_days" {
  type        = number
  description = "Días de retención de backups automáticos de RDS. 7-35 días recomendado para prod, 1-7 para staging"
  default     = 7

  validation {
    condition     = var.db_backup_days >= 1 && var.db_backup_days <= 35
    error_message = "El período de backup debe ser entre 1 y 35 días"
  }
}

########################
# DOMINIOS Y DNS
########################

variable "frontend_domain_name" {
  type        = string
  description = "Dominio para CloudFront (frontend React). Debe existir en Cloudflare/GoDaddy. Ejemplo: yieldpro.massnexus.com"
  default     = "uat.yieldpro.io"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-\\.]*\\.[a-z]{2,}$", var.frontend_domain_name))
    error_message = "Debe ser un dominio válido (ej: app.example.com)"
  }
}

variable "backend_domain_name" {
  type        = string
  description = "Dominio para ALB (backend Laravel). Debe existir en Cloudflare/GoDaddy. Ejemplo: api.massnexus.com"
  default     = "dev.yieldpro.io"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-\\.]*\\.[a-z]{2,}$", var.backend_domain_name))
    error_message = "Debe ser un dominio válido (ej: api.example.com)"
  }
}

variable "backend_domain_zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID para backend_domain_name (opcional). Dejar vacío si usas Cloudflare o registrador externo"
  default     = ""
  # Si usas Route53: obtener con `aws route53 list-hosted-zones`
  # Si usas Cloudflare/GoDaddy: dejar vacío y crear registros DNS manualmente usando el output
}

########################
# GITHUB CI/CD
########################

variable "github_repo_front" {
  type        = string
  description = "Repositorio GitHub del frontend en formato 'owner/repo'. Se usa para OIDC en GitHub Actions"
  default     = "beatsmedia/yieldpro_front_tmp"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+/[a-zA-Z0-9_-]+$", var.github_repo_front))
    error_message = "Debe tener formato 'owner/repo' (ej: myorg/frontend-app)"
  }
}

variable "github_repo_back" {
  type        = string
  description = "Repositorio GitHub del backend en formato 'owner/repo'. Se usa para OIDC en GitHub Actions"
  default     = "beatsmedia/yieldpro_back_tmp"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+/[a-zA-Z0-9_-]+$", var.github_repo_back))
    error_message = "Debe tener formato 'owner/repo' (ej: myorg/backend-api)"
  }
}

########################
# ALERTAS Y MONITOREO
########################

variable "alert_email" {
  type        = string
  description = "Email para alertas de CloudWatch (RDS CPU, Redis memoria, ALB errores, etc). Recibirás notificaciones de todos los servicios"
  default     = "nico@massnexus.com"

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.alert_email))
    error_message = "Debe ser un email válido (ej: ops@company.com)"
  }
}

variable "security_alert_email" {
  type        = string
  description = "Email para alertas de seguridad (GuardDuty amenazas, CloudTrail eventos críticos). Debe ser monitoreado 24/7"
  default     = "nico@massnexus.com"

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.security_alert_email))
    error_message = "Debe ser un email válido (ej: security@company.com)"
  }
}

########################
# NOTAS IMPORTANTES
########################

# COSTOS ESTIMADOS (us-east-1, 730 horas/mes):
# ================================================
# VPC + Networking:
#   - VPC Endpoints (Interface): ~$7/mes por endpoint × 5 = ~$35/mes
#   - NAT Gateway (opcional): ~$32/mes por AZ × 2 = ~$64/mes (DESHABILITADO por defecto)
#
# Compute:
#   - EC2 c6i.large: ~$62/mes × 2 instancias = ~$124/mes
#   - ALB: ~$16/mes + data transfer
#
# Base de Datos:
#   - RDS db.t4g.medium Multi-AZ: ~$100/mes
#   - Redis cache.t4g.small × 3 (HA): ~$27/mes
#
# Storage:
#   - RDS Storage 50GB gp3: ~$6/mes
#   - S3 buckets (logs, frontend, artifacts): ~$5/mes
#
# Seguridad:
#   - WAF (CloudFront + ALB): ~$10/mes
#   - GuardDuty: ~$5/mes
#   - CloudTrail: ~$2/mes
#
# Otros:
#   - CloudWatch Logs: ~$3/mes
#   - SNS notificaciones: ~$1/mes
#   - KMS keys: ~$1/mes
#
# TOTAL ESTIMADO: ~$334/mes (sin NAT Gateway)
# TOTAL CON NAT: ~$398/mes
#
# ================================================
#
# VALIDACIONES PREVIAS AL DEPLOY:
# ================================
# 1. Cambiar nombres de buckets si ya existen:
#    - ${var.name}-logs
#    - ${var.name}-frontend
#    - ${var.name}-backend-artifacts
#
# 2. Actualizar emails:
#    - alert_email (CloudWatch)
#    - security_alert_email (GuardDuty)
#
# 3. Actualizar repos GitHub:
#    - github_repo_front
#    - github_repo_back
#
# 4. Dominios listos en Cloudflare/GoDaddy:
#    - frontend_domain_name
#    - backend_domain_name
#
# 5. Después del apply:
#    - Copiar outputs de validación DNS
#    - Crear registros CNAME en Cloudflare/GoDaddy
#    - Esperar validación de certificados (~5-30 min)
