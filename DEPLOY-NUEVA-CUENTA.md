# 🚀 Guía: Implementar en Nueva Cuenta AWS

## 📋 PREREQUISITOS

1. **Cuenta AWS nueva/diferente** con:
   - Acceso de administrador (o permisos IAM necesarios)
   - AWS CLI configurado con las credenciales nuevas
   - Región decidida (ej: us-east-1, us-west-2, eu-west-1)

2. **Terraform instalado** (v1.6.0+)

3. **Dominio** (opcional, puedes usar CloudFront default):
   - Para frontend: ej. `app.tudominio.com`
   - Para backend: ej. `api.tudominio.com`

---

## 🔧 PASO 1: Configurar Nueva Cuenta AWS

### 1.1 Crear Perfil AWS CLI

```bash
# Ver perfiles actuales
cat ~/.aws/credentials

# Agregar nuevo perfil
aws configure --profile nueva-cuenta

# Ingresar:
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: xxx...
# Default region: us-east-1
# Default output format: json

# Verificar que funciona
aws sts get-caller-identity --profile nueva-cuenta

# Debería mostrar:
# {
#   "UserId": "AIDA...",
#   "Account": "123456789012",  # ← Número de la nueva cuenta
#   "Arn": "arn:aws:iam::123456789012:user/tu-usuario"
# }
```

### 1.2 Configurar Variables de Entorno

```bash
# Para toda la sesión
export AWS_PROFILE=nueva-cuenta

# Verificar
aws sts get-caller-identity
echo $AWS_PROFILE
```

---

## 📁 PASO 2: Preparar Archivos Terraform

### 2.1 Copiar el Proyecto

```bash
# Opción A: Copiar carpeta completa
cp -r /Users/johnnybonaci/Herd/terraform /path/nueva-cuenta-terraform
cd /path/nueva-cuenta-terraform

# Opción B: Clonar si está en Git
git clone <tu-repo> nueva-cuenta-terraform
cd nueva-cuenta-terraform
```

### 2.2 Limpiar State Anterior (MUY IMPORTANTE)

```bash
# Eliminar toda referencia al state anterior
find . -name "terraform.tfstate*" -delete
find . -name ".terraform" -type d -exec rm -rf {} +
find . -name ".terraform.lock.hcl" -delete

# Verificar que se eliminó todo
ls -la environments/prod/
ls -la environments/staging/
```

---

## 🔐 PASO 3: Configurar Backend Remoto (State S3)

### 3.1 Crear Bucket S3 y DynamoDB para State

```bash
cd 0-bootstrap/remote-state

# Editar variables
vim variables.tf

# Cambiar nombres únicos para la nueva cuenta:
# state_bucket_name = "mi-nueva-empresa-tf-state"
# lock_table_name   = "mi-nueva-empresa-tf-locks"
```

### 3.2 Aplicar Bootstrap

```bash
# Inicializar (sin backend remoto aún)
terraform init

# Planificar
terraform plan \
  -var="state_bucket_name=mi-nueva-empresa-tf-state" \
  -var="lock_table_name=mi-nueva-empresa-tf-locks"

# Aplicar
terraform apply \
  -var="state_bucket_name=mi-nueva-empresa-tf-state" \
  -var="lock_table_name=mi-nueva-empresa-tf-locks"

# Guardar outputs
terraform output
```

---

## ⚙️ PASO 4: Configurar Variables de Producción

### 4.1 Editar Backend Configuration

```bash
cd ../../environments/prod
vim backend.tf
```

Cambiar:
```hcl
terraform {
  backend "s3" {
    bucket         = "mi-nueva-empresa-tf-state"  # ← CAMBIAR
    region         = "us-east-1"                   # ← Verificar región
    key            = "prod/terraform.tfstate"
    dynamodb_table = "mi-nueva-empresa-tf-locks"  # ← CAMBIAR
    encrypt        = true
  }
}
```

### 4.2 Editar Variables de Producción

```bash
vim variables.tf
```

**Variables OBLIGATORIAS a cambiar:**

```hcl
variable "name" {
  type    = string
  default = "mi-nueva-empresa-prd"  # ← CAMBIAR (debe ser único)
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"  # ← Cambiar si la otra cuenta usa 10.0.0.0/16
}

variable "allowed_cidr" {
  type    = string
  default = "TU_IP_OFICINA/32"  # ← IP pública de oficina/casa
}

variable "frontend_domain_name" {
  type    = string
  default = "app.tudominio.com"  # ← Tu dominio real o "" para usar CloudFront default
}

variable "backend_domain_name" {
  type    = string
  default = "api.tudominio.com"  # ← Tu dominio real o ""
}

variable "security_alert_email" {
  type    = string
  default = "seguridad@tuempresa.com"  # ← Email real para alertas
}

variable "github_repo_front" {
  type    = string
  default = "tu-org/tu-repo-frontend"  # ← Tu repo de GitHub
}

variable "github_repo_back" {
  type    = string
  default = "tu-org/tu-repo-backend"  # ← Tu repo de GitHub
}
```

**Variables opcionales** (puedes ajustar según necesidad):

```hcl
variable "db_instance_cls" {
  default = "db.t4g.small"  # Más barato para testing
}

variable "db_allocated" {
  default = 20  # GB - Menos storage inicial
}

variable "az_count" {
  default = 2  # Número de AZs (2 para HA)
}
```

---

## 🚀 PASO 5: Aplicar Infraestructura

### 5.1 Inicializar Terraform

```bash
cd environments/prod
terraform init

# Debe mostrar:
# Initializing the backend...
# Successfully configured the backend "s3"!
```

### 5.2 Planificar Cambios

```bash
terraform plan -out=tfplan

# Revisar que va a crear ~65-70 recursos:
# Plan: 65 to add, 0 to change, 0 to destroy.
```

### 5.3 Aplicar (PRIMERA VEZ)

```bash
# Aplicar todo
terraform apply tfplan

# Esto tomará ~15-20 minutos
# ☕ Buen momento para café
```

### 5.4 Guardar Outputs Importantes

```bash
terraform output > ../outputs-prod.txt

# Ver outputs importantes
terraform output cloudfront_domain
terraform output alb_dns_name
terraform output guardduty_detector_id
terraform output waf_cloudfront_id
```

---

## 📧 PASO 6: Confirmar Subscripción SNS

**CRÍTICO:** Revisa el email configurado en `security_alert_email`

1. Buscar email con asunto: **"AWS Notification - Subscription Confirmation"**
2. Hacer click en el link: **"Confirm subscription"**
3. Deberías ver: "Subscription confirmed!"

**Sin esto, NO recibirás alertas de GuardDuty.**

---

## 🌐 PASO 7: Configurar DNS (Si usas dominio propio)

### 7.1 Validar Certificados ACM

```bash
# Ver records de validación para frontend
terraform output frontend_cert_validation_records

# Ver records de validación para backend
terraform output backend_cert_validation_records
```

### 7.2 Crear Records en tu DNS Provider

**Frontend (CloudFront):**
```
Type: CNAME
Name: app.tudominio.com
Value: <cloudfront_domain de output>
TTL: 300

Type: CNAME (validación ACM)
Name: _abc123.app.tudominio.com  # Del output
Value: _xyz789.acm-validations.aws.  # Del output
```

**Backend (ALB):**
```
Type: CNAME
Name: api.tudominio.com
Value: <alb_dns_name de output>
TTL: 300

Type: CNAME (validación ACM)
Name: _abc123.api.tudominio.com
Value: _xyz789.acm-validations.aws.
```

### 7.3 Esperar Validación (5-30 minutos)

```bash
# Verificar estado del certificado
aws acm describe-certificate \
  --certificate-arn <arn-del-cert-frontend> \
  --region us-east-1 \
  --query 'Certificate.Status'

# Debe cambiar de "PENDING_VALIDATION" a "ISSUED"
```

---

## 🧪 PASO 8: Configurar Staging (Opcional)

Si quieres staging en la nueva cuenta:

```bash
cd ../staging

# 1. Editar backend.tf
vim backend.tf
# Cambiar bucket y lock table

# 2. Editar variables.tf
vim variables.tf
# Cambiar name = "mi-nueva-empresa-stg"
# Agregar IPs permitidas en allowed_ips_staging

# 3. Aplicar
terraform init
terraform plan -out=tfplan-stg
terraform apply tfplan-stg
```

---

## ✅ PASO 9: Verificar Todo Funciona

### 9.1 Verificar Servicios de Seguridad

```bash
# GuardDuty
aws guardduty list-detectors --region us-east-1
# Debe mostrar: "DetectorIds": ["abc123..."]

# WAF CloudFront
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1
# Debe mostrar: tu WAF

# WAF ALB
aws wafv2 list-web-acls --scope REGIONAL --region us-east-1
# Debe mostrar: tu WAF

# CloudTrail
aws cloudtrail describe-trails --region us-east-1
# Debe mostrar: tu trail
```

### 9.2 Test de Conectividad

```bash
# Test CloudFront (si ya configuraste DNS)
curl -I https://app.tudominio.com
# O usar el cloudfront_domain:
curl -I https://dxxx.cloudfront.net

# Test ALB
curl -I http://<alb_dns_name>

# Test WAF (debe bloquear SQLi)
curl "https://app.tudominio.com/?id=1' OR '1'='1"
# Debe retornar: 403 Forbidden
```

---

## 💰 PASO 10: Revisar Costos

```bash
# Ir a Cost Explorer en AWS Console
# https://console.aws.amazon.com/cost-management/home

# O usar CLI:
aws ce get-cost-and-usage \
  --time-period Start=2024-11-01,End=2024-11-17 \
  --granularity DAILY \
  --metrics BlendedCost \
  --region us-east-1

# Costos esperados (mensual):
# - Producción: $28-49/mes (seguridad) + $100-200/mes (infra base)
# - Staging: $12-15/mes (seguridad) + $50-100/mes (infra base)
```

---

## 🔄 DIFERENCIAS ENTRE CUENTAS

### ¿Qué se DEBE cambiar?

| Item | ¿Cambiar? | Razón |
|------|-----------|-------|
| **state_bucket_name** | ✅ SÍ | Debe ser único globalmente |
| **lock_table_name** | ✅ SÍ | Debe ser único en la cuenta |
| **name** variable | ✅ SÍ | Prefijo de todos los recursos |
| **vpc_cidr** | ⚠️ Opcional | Solo si hay VPC peering |
| **dominios** | ✅ SÍ | Usar tus dominios reales |
| **security_alert_email** | ✅ SÍ | Email válido para alertas |
| **github_repos** | ✅ SÍ | Tus repos de GitHub |
| **allowed_cidr** | ✅ SÍ | Tu IP pública real |

### ¿Qué NO se debe cambiar?

- ❌ Nombres de archivos `.tf`
- ❌ Estructura de carpetas
- ❌ Configuración de WAF rules (a menos que quieras personalizarlas)
- ❌ Configuración de GuardDuty
- ❌ Alarmas de CloudWatch

---

## 🛡️ SEGURIDAD: Separación de Cuentas

### Buenas Prácticas

```bash
# 1. Nunca compartir el mismo state bucket entre cuentas
# Cuenta A:
bucket = "empresa-cuenta-prod-tf-state"

# Cuenta B:
bucket = "empresa-cuenta-dev-tf-state"

# 2. Usar diferentes perfiles AWS
export AWS_PROFILE=cuenta-prod    # Para producción
export AWS_PROFILE=cuenta-dev     # Para desarrollo

# 3. Separar credenciales
~/.aws/credentials:
[cuenta-prod]
aws_access_key_id = AKIA...
aws_secret_access_key = xxx...

[cuenta-dev]
aws_access_key_id = AKIA...
aws_secret_access_key = yyy...

# 4. Tags para identificar cuenta
tags = {
  Environment = "production"
  Account     = "prod-account"
  ManagedBy   = "terraform"
  Owner       = "equipo-ops"
}
```

---

## 🚨 ERRORES COMUNES

### Error 1: Bucket ya existe

```
Error: creating S3 Bucket (mi-empresa-tf-state): BucketAlreadyExists
```

**Solución:**
```bash
# Cambiar nombre del bucket a algo único
state_bucket_name = "mi-empresa-tf-state-$(date +%s)"
# O agregar un sufijo único
state_bucket_name = "mi-empresa-tf-state-us-east-1-2024"
```

### Error 2: Sin permisos

```
Error: AccessDenied: User is not authorized to perform: cloudtrail:CreateTrail
```

**Solución:**
```bash
# Verificar permisos del usuario
aws iam get-user --profile nueva-cuenta

# Necesitas estos permisos mínimos:
# - AdministratorAccess (recomendado para primera vez)
# O políticas específicas:
# - AmazonVPCFullAccess
# - AmazonEC2FullAccess
# - AmazonS3FullAccess
# - CloudWatchFullAccess
# - IAMFullAccess
# - GuardDutyFullAccess
# - AWSWAFFullAccess
```

### Error 3: Límites de servicio

```
Error: LimitExceeded: You have reached the maximum number of VPCs
```

**Solución:**
```bash
# Solicitar aumento de límite en AWS Console
# Service Quotas → Amazon VPC → VPCs per Region

# O eliminar VPCs no usados
aws ec2 describe-vpcs --region us-east-1
aws ec2 delete-vpc --vpc-id vpc-xxx
```

---

## 📝 CHECKLIST POST-IMPLEMENTACIÓN

- [ ] Terraform apply exitoso (sin errores)
- [ ] Email SNS confirmado
- [ ] GuardDuty detector activo
- [ ] WAF CloudFront creado
- [ ] WAF ALB creado
- [ ] CloudTrail logging a S3
- [ ] Certificados ACM validados (si usas dominio)
- [ ] DNS configurado (si usas dominio)
- [ ] Test de conectividad exitoso
- [ ] Costos revisados en Cost Explorer
- [ ] Documentación actualizada con nuevos valores
- [ ] Credenciales AWS guardadas de forma segura
- [ ] State backend remoto funcionando

---

## 🔗 RECURSOS ADICIONALES

### Scripts de Ayuda

```bash
# Script para cambiar entre cuentas rápidamente
# ~/.bashrc o ~/.zshrc:

function aws-switch() {
  if [ -z "$1" ]; then
    echo "Perfil actual: $AWS_PROFILE"
    echo "Perfiles disponibles:"
    aws configure list-profiles
  else
    export AWS_PROFILE=$1
    echo "✅ Cambiado a perfil: $AWS_PROFILE"
    aws sts get-caller-identity
  fi
}

# Uso:
# aws-switch cuenta-prod
# aws-switch cuenta-dev
```

### Terraform Workspaces (Alternativa)

```bash
# Si prefieres usar workspaces en vez de carpetas separadas:
terraform workspace new cuenta-nueva-prod
terraform workspace select cuenta-nueva-prod
terraform plan -var-file="cuenta-nueva.tfvars"
```

---

## 💡 TIPS FINALES

1. **Primera vez:** Usa `terraform plan` varias veces antes de `apply`
2. **Backups:** El state está en S3 con versionado, puedes restaurar
3. **Costos:** Configura alertas en AWS Budgets para evitar sorpresas
4. **Testing:** Empieza con staging antes de tocar prod
5. **Documentación:** Guarda todos los outputs en un archivo seguro

---

**¿Necesitas ayuda con algún paso específico?**
