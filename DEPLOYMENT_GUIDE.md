# 🚀 Guía Completa de Deployment - Infraestructura AWS con Terraform

Esta guía te llevará paso a paso desde cero hasta tener tu infraestructura completamente funcional en AWS.

**Tiempo total estimado:** 1-2 horas (dependiendo de validación de certificados)

---

## 📋 Índice

1. [Pre-requisitos](#1-pre-requisitos)
2. [Bootstrap: Remote State](#2-bootstrap-remote-state)
3. [Configuración de Variables](#3-configuración-de-variables)
4. [Deploy de Producción](#4-deploy-de-producción)
5. [Configuración DNS en Cloudflare](#5-configuración-dns-en-cloudflare)
6. [Configuración DNS en GoDaddy](#6-configuración-dns-en-godaddy-alternativa)
7. [Validación de Certificados](#7-validación-de-certificados)
8. [Configuración de GitHub Actions](#8-configuración-de-github-actions)
9. [Verificación Post-Deploy](#9-verificación-post-deploy)
10. [Troubleshooting](#10-troubleshooting)
11. [Rollback](#11-rollback-plan)
12. [Comandos de Referencia](#12-comandos-de-referencia-rápida)

---
 
## 1. Pre-requisitos

**⏱️ Tiempo:** 5 minutos

### 1.1 Herramientas Requeridas

Verifica que tengas instaladas:

```bash
# Terraform (versión >= 1.5)
terraform version

# AWS CLI (versión >= 2.x)
aws --version

# Git
git --version

# jq (opcional, útil para parsing)
jq --version
```

### 1.2 Credenciales AWS

```bash
# Configurar credenciales AWS
aws configure

# Verificar acceso
aws sts get-caller-identity
```

**Deberías ver:**
```json
{
    "UserId": "AIDAXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/tu-usuario"
}
```

### 1.3 Permisos Necesarios

Tu usuario/rol AWS necesita permisos para crear:
- ✅ VPC, Subnets, Security Groups
- ✅ EC2, ALB, Auto Scaling
- ✅ RDS, ElastiCache
- ✅ S3, CloudFront
- ✅ IAM Roles y Policies
- ✅ ACM Certificates
- ✅ WAF, GuardDuty, CloudTrail
- ✅ SSM Parameters, Secrets Manager
- ✅ CloudWatch Logs, SNS

**Recomendación:** Usar `AdministratorAccess` para el setup inicial.

### 1.4 Acceso a DNS

Necesitas acceso a:
- 🟦 **Cloudflare Dashboard** (si usas Cloudflare), O
- 🟧 **GoDaddy Domain Manager** (si usas GoDaddy)

Con permisos para crear/modificar registros DNS.

---

## 2. Bootstrap: Remote State

**⏱️ Tiempo:** 10 minutos

El remote state permite que múltiples desarrolladores trabajen en la misma infraestructura sin conflictos.

### 2.1 Crear Infraestructura de State

```bash
cd 0-bootstrap/remote-state

# Inicializar Terraform
terraform init

# Ver qué se va a crear
terraform plan

# Crear bucket S3 y tabla DynamoDB
terraform apply
```

**Qué se crea:**
- 📦 Bucket S3: `yp-test-tf-state` (para guardar el state)
- 🔒 Tabla DynamoDB: `tf-locks-yp-test` (para locks)
- 🔐 Cifrado: AES256 habilitado
- 🗑️ Versionado: Habilitado (para rollback)

### 2.2 Verificar Creación

```bash
# Verificar bucket
aws s3 ls s3://yp-test-tf-state/

# Verificar tabla DynamoDB
aws dynamodb describe-table --table-name tf-locks-yp-test
```

### 2.3 Guardar Outputs

```bash
# Copiar estos valores, los necesitarás
terraform output
```

---

## 3. Configuración de Variables

**⏱️ Tiempo:** 15 minutos

### 3.1 Revisar Variables Actuales

```bash
cd ../../environments/prod
cat variables.tf
```

### 3.2 Variables que DEBES Modificar

Edita `environments/prod/variables.tf`:

#### 🔴 **CRÍTICO - Nombres de Buckets**

Los nombres de buckets S3 son globalmente únicos. Si ya existen, el deploy fallará.

```hcl
variable "name" {
  default = "yp-prod"  # ⚠️ CAMBIAR si "yp-test" ya existe
}
```

Esto generará buckets:
- `yp-prod-logs`
- `yp-prod-frontend`
- `yp-prod-backend-artifacts`

**Verificar disponibilidad:**
```bash
aws s3 ls s3://yp-prod-logs 2>&1 | grep -q "NoSuchBucket" && echo "✅ Disponible" || echo "❌ Ya existe"
```

#### 🟡 **IMPORTANTE - Emails**

```hcl
variable "alert_email" {
  default = "ops@tu-empresa.com"  # ⚠️ TU EMAIL REAL
}

variable "security_alert_email" {
  default = "security@tu-empresa.com"  # ⚠️ TU EMAIL REAL
}
```

#### 🟡 **IMPORTANTE - Dominios**

```hcl
variable "frontend_domain_name" {
  default = "app.tu-dominio.com"  # ⚠️ Tu dominio en Cloudflare/GoDaddy
}

variable "backend_domain_name" {
  default = "api.tu-dominio.com"  # ⚠️ Tu dominio en Cloudflare/GoDaddy
}
```

**Nota:** Estos dominios DEBEN existir en tu registrador.

#### 🟢 **OPCIONAL - Repositorios GitHub**

```hcl
variable "github_repo_front" {
  default = "tu-org/frontend-repo"  # ⚠️ Tu repo real
}

variable "github_repo_back" {
  default = "tu-org/backend-repo"  # ⚠️ Tu repo real
}
```

### 3.3 Tabla de Referencia Completa

| Variable | Valor Actual | ¿Cambiar? | Nuevo Valor |
|----------|--------------|-----------|-------------|
| `name` | `yp-test` | ⚠️ Si existe | `yp-prod` |
| `region` | `us-east-1` | ✅ OK | - |
| `vpc_cidr` | `10.0.0.0/16` | ✅ OK | - |
| `alert_email` | `ops@massnexus.com` | 🔴 SÍ | Tu email |
| `security_alert_email` | `security@massnexus.com` | 🔴 SÍ | Tu email |
| `frontend_domain_name` | `uat.yieldpro.io` | 🔴 SÍ | Tu dominio |
| `backend_domain_name` | `dev.yieldpro.io` | 🔴 SÍ | Tu dominio |
| `github_repo_front` | `beatsmedia/...` | 🟡 Recomendado | Tu repo |
| `github_repo_back` | `beatsmedia/...` | 🟡 Recomendado | Tu repo |

---

## 4. Deploy de Producción

**⏱️ Tiempo:** 30-40 minutos

### 4.1 Inicializar Terraform

```bash
cd environments/prod

# Inicializar (descarga providers y configura backend)
terraform init
```

**Deberías ver:**
```
Initializing the backend...
Successfully configured the backend "s3"!
```

### 4.2 Validar Configuración

```bash
# Formatear código (opcional pero recomendado)
terraform fmt -recursive

# Validar sintaxis
terraform validate
```

**Salida esperada:**
```
Success! The configuration is valid.
```

### 4.3 Revisar Plan de Deployment

```bash
# Ver QUÉ se va a crear (SIN crear nada aún)
terraform plan -out=tfplan
```

**Qué revisar en el plan:**

✅ **Recursos a crear:** ~120-150 recursos
- VPC, subnets, route tables
- Security groups
- ALB + target group
- Auto Scaling Group
- RDS MySQL (Multi-AZ)
- ElastiCache Redis (Multi-AZ)
- S3 buckets
- CloudFront distribution
- ACM certificates
- IAM roles y policies
- WAF rules
- CloudWatch alarms
- Y más...

⚠️ **IMPORTANTE:** Revisa que los nombres sean correctos:
```
  # aws_s3_bucket.backend_artifacts will be created
  + resource "aws_s3_bucket" "backend_artifacts" {
      + bucket                      = "yp-prod-backend-artifacts"  # ← Verifica este nombre
```

### 4.4 Aplicar Cambios

```bash
# Crear la infraestructura (confirmará antes de ejecutar)
terraform apply tfplan
```

O si no guardaste el plan:

```bash
terraform apply
```

**Proceso de creación:** (~30-40 minutos)

```
⏱️ 0-5 min:    VPC, Subnets, Security Groups
⏱️ 5-10 min:   S3 Buckets, KMS Keys
⏱️ 10-15 min:  ALB, Target Groups
⏱️ 15-25 min:  RDS MySQL (Multi-AZ) ← MÁS LENTO
⏱️ 25-35 min:  ElastiCache Redis
⏱️ 35-40 min:  EC2 Instances, Auto Scaling
⏱️ 40+ min:    CloudFront Distribution ← MÁS LENTO
```

### 4.5 Guardar Outputs Importantes

Una vez completado:

```bash
# Ver todos los outputs
terraform output

# Guardar outputs específicos
terraform output -json > outputs.json
```

**Outputs críticos que necesitarás:**

```bash
# ARN del rol de GitHub (frontend)
terraform output gh_front_role_arn

# ARN del rol de GitHub (backend)
terraform output gh_backend_role_arn

# ID de CloudFront
terraform output cloudfront_distribution_id

# DNS del ALB
terraform output alb_dns_name

# Registros DNS para validar certificados
terraform output frontend_cert_validation_records
terraform output backend_cert_validation_records
```

---

## 5. Configuración DNS en Cloudflare

**⏱️ Tiempo:** 10-15 minutos

### 5.1 Obtener Registros de Validación

```bash
# Ver registros que necesitas crear
terraform output frontend_cert_validation_records
terraform output backend_cert_validation_records
```

**Salida ejemplo:**
```json
[
  {
    "name": "_abc123def456.app.tudominio.com",
    "type": "CNAME",
    "value": "_xyz789.acm-validations.aws."
  }
]
```

### 5.2 Crear Registros en Cloudflare - Frontend

**Paso 1:** Login en [Cloudflare Dashboard](https://dash.cloudflare.com)

**Paso 2:** Selecciona tu dominio (ej: `tudominio.com`)

**Paso 3:** Ve a **DNS** → **Records**

**Paso 4:** Click en **+ Add record**

**Paso 5:** Configura el registro de validación:

```
Type:          CNAME
Name:          _abc123def456.app        ← Copiar del output (sin el dominio base)
Target:        _xyz789.acm-validations.aws.   ← Copiar del output
TTL:           Auto
Proxy status:  🔘 DNS only (GRIS) ← IMPORTANTE: NO proxy (naranja)
```

**Paso 6:** Click **Save**

### 5.3 Crear Registro A/CNAME para Frontend

Una vez validado el certificado (ver sección 7):

```
Type:    CNAME
Name:    app                           ← Tu subdomain
Target:  d1234abc.cloudfront.net       ← Copiar de terraform output cloudfront_domain
TTL:     Auto
Proxy:   🟠 Proxied (NARANJA) ← CloudFlare proxy habilitado
```

### 5.4 Crear Registros en Cloudflare - Backend

**Repetir proceso para el backend:**

**Registro de validación:**
```
Type:    CNAME
Name:    _def456ghi789.api
Target:  _abc123.acm-validations.aws.
TTL:     Auto
Proxy:   🔘 DNS only (GRIS)
```

**Registro A para ALB:**
```bash
# Obtener DNS del ALB
terraform output alb_dns_name
# Ejemplo: yp-prod-alb-1234567890.us-east-1.elb.amazonaws.com
```

```
Type:    CNAME
Name:    api
Target:  yp-prod-alb-1234567890.us-east-1.elb.amazonaws.com
TTL:     Auto
Proxy:   🟠 Proxied (NARANJA) ← CloudFlare protection
```

### 5.5 Verificar Propagación DNS

```bash
# Verificar registro de validación (frontend)
dig _abc123def456.app.tudominio.com CNAME +short

# Verificar registro de aplicación (frontend)
dig app.tudominio.com CNAME +short

# Verificar backend
dig api.tudominio.com CNAME +short
```

**Tiempo de propagación:** 2-5 minutos (Cloudflare es rápido)

---

## 6. Configuración DNS en GoDaddy (Alternativa)

**⏱️ Tiempo:** 15-20 minutos

Si usas GoDaddy en lugar de Cloudflare:

### 6.1 Login en GoDaddy

1. Ve a [godaddy.com](https://www.godaddy.com)
2. Login → **My Products**
3. Click en **DNS** junto a tu dominio

### 6.2 Crear Registro de Validación (Frontend)

```bash
# Obtener del output
terraform output frontend_cert_validation_records
```

**En GoDaddy:**

1. Click **Add New Record**
2. Selecciona **Type:** `CNAME`
3. **Host/Name:** `_abc123def456.app` (sin el dominio base)
4. **Points to:** `_xyz789.acm-validations.aws.`
5. **TTL:** `1 Hour` (o menor)
6. Click **Save**

### 6.3 Crear Registro CNAME para Frontend

Una vez validado el certificado:

```
Type:       CNAME
Host:       app
Points to:  d1234abc.cloudfront.net.  ← Agregar punto al final
TTL:        1 Hour
```

### 6.4 Crear Registros para Backend

**Validación:**
```
Type:       CNAME
Host:       _def456ghi789.api
Points to:  _abc123.acm-validations.aws.
TTL:        1 Hour
```

**ALB:**
```
Type:       CNAME
Host:       api
Points to:  yp-prod-alb-1234567890.us-east-1.elb.amazonaws.com.
TTL:        1 Hour
```

### 6.5 Verificar Propagación

```bash
# GoDaddy puede tardar más
dig _abc123def456.app.tudominio.com CNAME +short

# Esperar 10-15 minutos si no aparece
```

**Tiempo de propagación en GoDaddy:** 10-30 minutos

---

## 7. Validación de Certificados

**⏱️ Tiempo:** 5-30 minutos (espera pasiva)

### 7.1 Verificar Estado en AWS Console

1. Login en [AWS Console](https://console.aws.amazon.com)
2. Ve a **Certificate Manager** (ACM)
3. **Región:** 
   - `us-east-1` para certificado de CloudFront
   - Tu región (ej: `us-east-1`) para certificado de ALB

**Estados posibles:**
- 🟡 **Pending validation** - Esperando DNS
- 🟢 **Issued** - Certificado válido
- 🔴 **Failed** - Error (ver troubleshooting)

### 7.2 Verificar con AWS CLI

```bash
# Obtener ARN del certificado (frontend)
terraform output -json frontend_cert_validation_records | jq -r '.[0].arn'

# Ver estado
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:123456789:certificate/abc-123 \
  --region us-east-1
```

**Buscar en el output:**
```json
{
  "Certificate": {
    "Status": "ISSUED",  ← Debe decir "ISSUED"
    "DomainValidationOptions": [
      {
        "ValidationStatus": "SUCCESS"  ← Debe decir "SUCCESS"
      }
    ]
  }
}
```

### 7.3 Tiempos Esperados

| Proveedor DNS | Tiempo Típico | Tiempo Máximo |
|---------------|---------------|---------------|
| Cloudflare | 5-10 minutos | 20 minutos |
| GoDaddy | 10-20 minutos | 30-45 minutos |
| Route53 | 2-5 minutos | 10 minutos |

### 7.4 ¿Qué hacer mientras esperas?

✅ Continuar con la configuración de GitHub Actions (sección 8)
✅ Revisar CloudWatch Logs
✅ Verificar que las instancias EC2 estén healthy

---

## 8. Configuración de GitHub Actions

**⏱️ Tiempo:** 10 minutos

### 8.1 Secrets para Frontend

En tu repositorio de frontend:

**1.** Ve a **Settings** → **Secrets and variables** → **Actions**

**2.** Click **New repository secret**

**3.** Crear estos secrets:

```bash
# Obtener valores
terraform output gh_front_role_arn
terraform output cloudfront_distribution_id
terraform output frontend_bucket
terraform output region
```

**Secrets a crear:**

| Secret Name | Valor | Obtener con |
|-------------|-------|-------------|
| `AWS_REGION` | `us-east-1` | Fijo |
| `AWS_ROLE_ARN` | `arn:aws:iam::123...` | `terraform output gh_front_role_arn` |
| `S3_BUCKET` | `yp-prod-frontend` | `terraform output frontend_bucket` |
| `CLOUDFRONT_DISTRIBUTION_ID` | `E1ABC234DEF5` | `terraform output cloudfront_distribution_id` |

### 8.2 Secrets para Backend

En tu repositorio de backend:

**Secrets a crear:**

```bash
# Obtener valores
terraform output gh_backend_role_arn
terraform output backend_artifacts_bucket
terraform output codedeploy_app_name
terraform output codedeploy_deployment_group
```

| Secret Name | Valor | Obtener con |
|-------------|-------|-------------|
| `AWS_REGION` | `us-east-1` | Fijo |
| `AWS_ROLE_ARN` | `arn:aws:iam::123...` | `terraform output gh_backend_role_arn` |
| `S3_BUCKET` | `yp-prod-backend-artifacts` | `terraform output backend_artifacts_bucket` |
| `CODEDEPLOY_APP` | `yp-prod-backend` | `terraform output codedeploy_app_name` |
| `CODEDEPLOY_GROUP` | `yp-prod-backend-dg` | `terraform output codedeploy_deployment_group` |

### 8.3 Ejemplo de Workflow (Frontend)

Crea `.github/workflows/deploy-prod.yml`:

```yaml
name: Deploy to Production

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Build
        run: npm ci && npm run build

      - name: Deploy to S3
        run: aws s3 sync ./dist s3://${{ secrets.S3_BUCKET }} --delete

      - name: Invalidate CloudFront
        run: |
          aws cloudfront create-invalidation \
            --distribution-id ${{ secrets.CLOUDFRONT_DISTRIBUTION_ID }} \
            --paths "/*"
```

---

## 9. Verificación Post-Deploy

**⏱️ Tiempo:** 15 minutos

### 9.1 Verificar Health Checks

```bash
# Ver estado del Target Group
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw alb_target_group_arn)
```

**Salida esperada:**
```json
{
  "TargetHealthDescriptions": [
    {
      "TargetHealth": {
        "State": "healthy"  ← Debe ser "healthy"
      }
    }
  ]
}
```

### 9.2 Verificar Acceso al ALB

```bash
# Obtener DNS del ALB
ALB_DNS=$(terraform output -raw alb_dns_name)

# Probar health check
curl -I http://$ALB_DNS/health
```

**Respuesta esperada:**
```
HTTP/1.1 200 OK
Content-Type: text/plain
ok
```

### 9.3 Verificar CloudFront

```bash
# Obtener dominio de CloudFront
CF_DOMAIN=$(terraform output -raw cloudfront_domain)

# Probar acceso
curl -I https://$CF_DOMAIN
```

### 9.4 Verificar Dominios Personalizados

Una vez validados los certificados:

```bash
# Frontend
curl -I https://app.tudominio.com

# Backend
curl -I https://api.tudominio.com/health
```

### 9.5 Verificar SSM Session Manager

```bash
# Listar instancias
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=yp-prod-app" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table

# Conectar a una instancia
aws ssm start-session --target i-1234567890abcdef0
```

### 9.6 Verificar Logs en CloudWatch

```bash
# Ver log groups
aws logs describe-log-groups --log-group-name-prefix /vpc/yp-prod

# Ver logs recientes
aws logs tail /vpc/yp-prod/vpc-fl --follow
```

### 9.7 Checklist de Verificación

- [ ] ALB healthy targets >= 2
- [ ] RDS disponible y accesible
- [ ] Redis cluster activo
- [ ] CloudFront sirviendo contenido
- [ ] Certificados SSL validados
- [ ] Health check respondiendo 200
- [ ] SSM Session Manager funcionando
- [ ] CloudWatch Logs recibiendo datos
- [ ] SNS topics confirmados (check email)

---

## 10. Troubleshooting

### 10.1 Certificados No Validan

**Síntoma:** Certificado en estado "Pending validation" por más de 30 minutos

**Causas comunes:**

1. **Registro DNS mal configurado**
   ```bash
   # Verificar que el registro existe
   dig _abc123.app.tudominio.com CNAME +short
   
   # Debe devolver algo como: _xyz789.acm-validations.aws.
   ```

2. **Proxy de Cloudflare activado**
   - El registro de validación DEBE estar en DNS only (gris)
   - NO puede estar proxied (naranja)

3. **TTL muy alto en GoDaddy**
   - Reducir TTL a 600 (10 minutos)
   - Esperar tiempo de propagación

**Solución:**
```bash
# Eliminar certificado y recrear
terraform destroy -target=aws_acm_certificate.frontend
terraform apply -target=aws_acm_certificate.frontend

# Volver a crear registros DNS
```

### 10.2 Bucket Name Already Exists

**Síntoma:** Error: `BucketAlreadyExists` o `BucketAlreadyOwnedByYou`

**Solución:**

```bash
# Opción 1: Usar nombre diferente
# Editar variables.tf
variable "name" {
  default = "yp-prod-2"  # ← Cambiar
}

# Opción 2: Eliminar bucket existente (si es tuyo)
aws s3 rb s3://yp-prod-logs --force
```

### 10.3 ALB Targets Unhealthy

**Síntoma:** Targets en estado "unhealthy"

**Diagnóstico:**

```bash
# Ver razón del unhealthy
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw alb_target_group_arn) \
  | jq '.TargetHealthDescriptions[].TargetHealth'
```

**Causas comunes:**

1. **Health check path incorrecto**
   - Verificar que `/health` existe y responde 200

2. **Security group bloqueando tráfico**
   ```bash
   # Verificar SGs
   terraform output -json | jq '.alb_sg_id.value'
   ```

3. **Instancia no tiene Nginx corriendo**
   ```bash
   # Conectar via SSM
   aws ssm start-session --target i-xxxxx
   
   # Verificar Nginx
   sudo systemctl status nginx
   
   # Ver logs de user-data
   sudo cat /var/log/user-data.log
   ```

### 10.4 CloudFront 403 Forbidden

**Síntoma:** CloudFront devuelve 403 al acceder

**Causas:**

1. **Bucket policy incorrecta**
   ```bash
   # Verificar policy
   aws s3api get-bucket-policy --bucket yp-prod-frontend
   ```

2. **OAC mal configurado**
   ```bash
   # Re-aplicar bucket policy
   terraform apply -target=aws_s3_bucket_policy.frontend_oac
   ```

3. **Bucket vacío**
   ```bash
   # Verificar contenido
   aws s3 ls s3://yp-prod-frontend/
   
   # Debe tener archivos, si no, hacer deploy del frontend
   ```

### 10.5 RDS Connection Timeout

**Síntoma:** Laravel no puede conectar a RDS

**Diagnóstico:**

```bash
# Verificar security group
terraform output -json | jq '.db_sg_id.value'

# Verificar que app SG puede acceder a DB SG en puerto 3306
```

**Solución:**

```bash
# Desde instancia EC2 (via SSM)
mysql -h $(aws ssm get-parameter --name /yp-prod/laravel/DB_HOST --query 'Parameter.Value' --output text) \
      -u appuser \
      -p
```

### 10.6 Costos Inesperados

**Síntoma:** Costos más altos de lo esperado

**Revisar:**

```bash
# NAT Gateway (más caro)
terraform show | grep nat_gateway

# Verificar si está habilitado
# Si enable_nat_gateway = true, cuesta ~$32/mes por AZ

# Instancias grandes
terraform show | grep instance_type

# RDS Multi-AZ
terraform show | grep multi_az
```

**Optimizaciones:**

```bash
# Deshabilitar NAT (usa VPC Endpoints)
# En variables.tf
variable "enable_nat_gateway" {
  default = false  # Ahorra ~$64/mes
}

# Usar instancias más pequeñas en staging
variable "db_instance_cls" {
  default = "db.t4g.small"  # En lugar de medium
}
```

---

## 11. Rollback Plan

### 11.1 Backup de State Antes de Cambios

```bash
# Backup manual
aws s3 cp s3://yp-test-tf-state/prod/terraform.tfstate \
          ./backup-$(date +%Y%m%d-%H%M%S).tfstate

# Ver versiones en S3
aws s3api list-object-versions \
  --bucket yp-test-tf-state \
  --prefix prod/terraform.tfstate
```

### 11.2 Rollback a Versión Anterior

```bash
# Opción 1: Usar versionado de S3
aws s3api get-object \
  --bucket yp-test-tf-state \
  --key prod/terraform.tfstate \
  --version-id <VERSION_ID> \
  terraform.tfstate.backup

# Restaurar
aws s3 cp terraform.tfstate.backup \
          s3://yp-test-tf-state/prod/terraform.tfstate
```

### 11.3 Destruir Recursos Problemáticos

```bash
# Destruir recurso específico
terraform destroy -target=aws_instance.problematic

# Re-crear
terraform apply -target=aws_instance.problematic
```

### 11.4 ⚠️ NO HACER Nunca

- ❌ NO ejecutes `terraform destroy` sin backup
- ❌ NO modifiques el state manualmente sin saber qué haces
- ❌ NO borres el bucket de state sin migrar primero
- ❌ NO apliques cambios sin revisar `terraform plan` primero

---

## 12. Comandos de Referencia Rápida

### 12.1 Terraform Básico

```bash
# Inicializar proyecto
terraform init

# Ver plan sin aplicar
terraform plan

# Aplicar cambios
terraform apply

# Aplicar sin confirmación (CI/CD)
terraform apply -auto-approve

# Destruir todo (PELIGROSO)
terraform destroy

# Formatear código
terraform fmt -recursive

# Validar sintaxis
terraform validate

# Ver state actual
terraform show

# Listar recursos
terraform state list

# Ver outputs
terraform output
terraform output -json
terraform output nombre_output
```

### 12.2 Terraform Avanzado

```bash
# Trabajar con recursos específicos
terraform apply -target=aws_instance.app
terraform destroy -target=aws_s3_bucket.logs

# Refrescar state sin aplicar cambios
terraform refresh

# Importar recurso existente
terraform import aws_instance.example i-1234567890abcdef0

# Remover recurso del state (no lo destruye)
terraform state rm aws_instance.example

# Mover recurso en el state
terraform state mv aws_instance.old aws_instance.new

# Ver dependencias
terraform graph | dot -Tsvg > graph.svg

# Upgrade de providers
terraform init -upgrade
```

### 12.3 AWS CLI - EC2 e Instancias

```bash
# Listar instancias
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=yp-prod-app" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PrivateIpAddress]' \
  --output table

# Conectar via SSM
aws ssm start-session --target i-1234567890abcdef0

# Ver user-data log (dentro de la instancia via SSM)
sudo tail -f /var/log/user-data.log

# Reiniciar Nginx
sudo systemctl restart nginx

# Ver logs de Nginx
sudo tail -f /var/log/nginx/error.log

# Ver logs de PHP-FPM
sudo tail -f /var/log/php8.3-fpm.log
```

### 12.4 AWS CLI - ALB y Target Groups

```bash
# Listar ALBs
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[*].[LoadBalancerName,DNSName,State.Code]' \
  --output table

# Ver target health
aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:...

# Registrar target manualmente
aws elbv2 register-targets \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --targets Id=i-1234567890abcdef0

# Deregistrar target
aws elbv2 deregister-targets \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --targets Id=i-1234567890abcdef0
```

### 12.5 AWS CLI - RDS

```bash
# Ver estado de RDS
aws rds describe-db-instances \
  --db-instance-identifier yp-prod-mysql \
  --query 'DBInstances[*].[DBInstanceStatus,Endpoint.Address,MultiAZ]' \
  --output table

# Ver snapshots
aws rds describe-db-snapshots \
  --db-instance-identifier yp-prod-mysql

# Crear snapshot manual
aws rds create-db-snapshot \
  --db-snapshot-identifier yp-prod-manual-$(date +%Y%m%d-%H%M%S) \
  --db-instance-identifier yp-prod-mysql

# Modificar RDS (cambiar instance class)
aws rds modify-db-instance \
  --db-instance-identifier yp-prod-mysql \
  --db-instance-class db.t4g.large \
  --apply-immediately
```

### 12.6 AWS CLI - ElastiCache Redis

```bash
# Ver estado de Redis
aws elasticache describe-replication-groups \
  --replication-group-id yp-prod-redis

# Ver nodos
aws elasticache describe-cache-clusters \
  --show-cache-node-info

# Conectar a Redis (desde instancia EC2)
redis-cli -h $(aws ssm get-parameter --name /yp-prod/laravel/REDIS_HOST --query 'Parameter.Value' --output text) \
          -a $(aws ssm get-parameter --name /yp-prod/laravel/REDIS_PASSWORD --with-decryption --query 'Parameter.Value' --output text)

# Verificar conexión
redis-cli -h <host> -a <password> ping
# Respuesta: PONG
```

### 12.7 AWS CLI - S3

```bash
# Listar buckets
aws s3 ls

# Ver contenido de bucket
aws s3 ls s3://yp-prod-frontend/ --recursive

# Sincronizar directorio local a S3
aws s3 sync ./dist s3://yp-prod-frontend/ --delete

# Copiar archivo
aws s3 cp index.html s3://yp-prod-frontend/

# Ver tamaño de bucket
aws s3 ls s3://yp-prod-frontend/ --recursive --summarize --human-readable

# Eliminar bucket (PELIGROSO)
aws s3 rb s3://yp-prod-frontend --force
```

### 12.8 AWS CLI - CloudFront

```bash
# Listar distribuciones
aws cloudfront list-distributions \
  --query 'DistributionList.Items[*].[Id,DomainName,Status]' \
  --output table

# Crear invalidación (limpiar caché)
aws cloudfront create-invalidation \
  --distribution-id E1ABC234DEF5 \
  --paths "/*"

# Ver invalidaciones
aws cloudfront list-invalidations \
  --distribution-id E1ABC234DEF5

# Ver configuración
aws cloudfront get-distribution \
  --id E1ABC234DEF5
```

### 12.9 AWS CLI - ACM Certificates

```bash
# Listar certificados
aws acm list-certificates

# Ver detalles de certificado
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:123456789:certificate/abc-123

# Ver estado de validación
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:123456789:certificate/abc-123 \
  --query 'Certificate.DomainValidationOptions[*].[DomainName,ValidationStatus]' \
  --output table
```

### 12.10 AWS CLI - SSM Parameters

```bash
# Listar parámetros
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/yp-prod/"

# Obtener parámetro
aws ssm get-parameter \
  --name /yp-prod/laravel/APP_KEY \
  --with-decryption

# Crear/actualizar parámetro
aws ssm put-parameter \
  --name /yp-prod/laravel/NEW_VAR \
  --value "value" \
  --type SecureString

# Eliminar parámetro
aws ssm delete-parameter \
  --name /yp-prod/laravel/OLD_VAR
```

### 12.11 AWS CLI - CloudWatch Logs

```bash
# Listar log groups
aws logs describe-log-groups \
  --log-group-name-prefix /vpc/yp-prod

# Ver streams en un group
aws logs describe-log-streams \
  --log-group-name /vpc/yp-prod/vpc-fl

# Tail logs en tiempo real
aws logs tail /vpc/yp-prod/vpc-fl --follow

# Ver logs con filtro
aws logs filter-log-events \
  --log-group-name /vpc/yp-prod/vpc-fl \
  --filter-pattern "ERROR"

# Ver logs de un período específico
aws logs filter-log-events \
  --log-group-name /vpc/yp-prod/vpc-fl \
  --start-time $(date -d '1 hour ago' +%s)000
```

### 12.12 AWS CLI - Auto Scaling

```bash
# Ver estado del ASG
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names yp-prod-asg

# Ver actividad reciente
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name yp-prod-asg \
  --max-records 10

# Cambiar capacidad manualmente
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name yp-prod-asg \
  --desired-capacity 3

# Suspender procesos (para maintenance)
aws autoscaling suspend-processes \
  --auto-scaling-group-name yp-prod-asg

# Resumir procesos
aws autoscaling resume-processes \
  --auto-scaling-group-name yp-prod-asg
```

### 12.13 Debugging y Troubleshooting

```bash
# Ver últimos eventos de CloudTrail
aws cloudtrail lookup-events \
  --max-results 10 \
  --output table

# Ver alarmas activas en CloudWatch
aws cloudwatch describe-alarms \
  --state-value ALARM

# Verificar conectividad desde EC2
# (ejecutar dentro de la instancia via SSM)
curl -v https://api.tudominio.com/health
ping -c 4 google.com
nc -zv rds-endpoint.us-east-1.rds.amazonaws.com 3306

# Ver uso de disco
df -h

# Ver memoria
free -h

# Ver procesos
top
htop

# Ver logs del sistema
sudo journalctl -xe
```

---

## 📊 Anexo: Estimación de Costos Detallada

### Costos Mensuales por Componente (us-east-1)

| Servicio | Recurso | Especificación | Costo/mes |
|----------|---------|----------------|-----------|
| **Networking** | | | |
| | VPC | Gratis | $0 |
| | VPC Endpoints (Interface) | 5 endpoints × $7 | $35 |
| | NAT Gateway | 2 AZs × $32 (DESHABILITADO) | $0 |
| | Data Transfer | ~100 GB | $9 |
| **Compute** | | | |
| | EC2 - c6i.large | 2 instancias × $62 | $124 |
| | ALB | Horas + LCU | $16 |
| | EBS - gp3 | 2 × 50GB | $10 |
| **Database** | | | |
| | RDS MySQL | db.t4g.medium Multi-AZ | $100 |
| | RDS Storage | 50GB gp3 | $6 |
| | Redis | cache.t4g.small × 3 nodes | $27 |
| **Storage** | | | |
| | S3 - Logs | ~10GB + requests | $2 |
| | S3 - Frontend | ~5GB + requests | $1 |
| | S3 - Artifacts | ~5GB + requests | $1 |
| **CDN** | | | |
| | CloudFront | ~100GB transfer | $8 |
| **Security** | | | |
| | WAF | 2 Web ACLs + rules | $10 |
| | GuardDuty | Continuous monitoring | $5 |
| | CloudTrail | 1 trail | $2 |
| **Monitoring** | | | |
| | CloudWatch Logs | ~5GB ingestion | $3 |
| | CloudWatch Alarms | ~20 alarms | $2 |
| | SNS | Notifications | $1 |
| **Encryption** | | | |
| | KMS | 1 key | $1 |
| **TOTAL** | | | **~$334/mes** |

### Optimizaciones Posibles

| Optimización | Ahorro/mes | Impacto |
|--------------|------------|---------|
| Usar t3 en lugar de c6i | $40 | Menor performance |
| RDS t4g.small en staging | $50 | Solo para staging |
| Deshabilitar GuardDuty en dev | $5 | Menor seguridad |
| Reducir retención de logs | $2 | Menos historia |
| Redis t4g.micro (1 nodo) staging | $18 | Solo para staging |

---

## 🎓 Mejores Prácticas

### Seguridad

✅ **DO:**
- Rotar credenciales regularmente
- Usar SSM Session Manager (no SSH keys)
- Habilitar MFA en cuenta AWS
- Revisar CloudTrail logs semanalmente
- Mantener security groups restrictivos
- Actualizar AMIs mensualmente

❌ **DON'T:**
- Commitear credenciales en Git
- Exponer RDS públicamente
- Usar usuario root de AWS
- Ignorar alertas de GuardDuty
- Deshabilitar cifrado

### Costos

✅ **DO:**
- Usar Cost Explorer mensualmente
- Configurar AWS Budgets
- Apagar recursos de dev/staging fuera de horario
- Usar Reserved Instances para prod (ahorro 30-40%)
- Revisar recursos no utilizados

❌ **DON'T:**
- Dejar NAT Gateway si no es necesario
- Sobre-provisionar instancias
- Mantener snapshots infinitamente
- Ignorar alarmas de facturación

### Deployment

✅ **DO:**
- Hacer `terraform plan` antes de `apply`
- Backup de state antes de cambios grandes
- Usar workspaces para ambientes
- Documentar cambios en Git commits
- Testing en staging primero

❌ **DON'T:**
- Aplicar cambios directamente en prod
- Modificar recursos manualmente (clickops)
- Ignorar errores de Terraform
- Skip validación de certificados

---

## 📞 Soporte y Recursos

### Documentación Oficial

- 📘 [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- 📘 [AWS Documentation](https://docs.aws.amazon.com/)
- 📘 [Terraform Best Practices](https://www.terraform-best-practices.com/)

### Herramientas Útiles

- 🔧 [tfenv](https://github.com/tfutils/tfenv) - Terraform version manager
- 🔧 [tflint](https://github.com/terraform-linters/tflint) - Terraform linter
- 🔧 [terragrunt](https://terragrunt.gruntwork.io/) - Terraform wrapper para DRY
- 🔧 [infracost](https://www.infracost.io/) - Estimación de costos

### Comandos de Ayuda

```bash
# Help de Terraform
terraform -help
terraform plan -help

# Help de AWS CLI
aws help
aws ec2 help
aws rds help

# Versiones instaladas
terraform version
aws --version
```

---

## ✅ Checklist Final

Antes de considerar el deployment completo:

### Pre-Deploy
- [ ] Credenciales AWS configuradas
- [ ] Terraform >= 1.5 instalado
- [ ] Variables actualizadas (emails, dominios, nombres)
- [ ] Buckets S3 únicos verificados
- [ ] Acceso a DNS (Cloudflare/GoDaddy)

### Durante Deploy
- [ ] Bootstrap (remote state) completado
- [ ] `terraform init` exitoso
- [ ] `terraform plan` revisado
- [ ] `terraform apply` completado (~40 min)
- [ ] Outputs guardados

### Post-Deploy
- [ ] Registros DNS creados
- [ ] Certificados SSL validados (5-30 min)
- [ ] ALB targets healthy
- [ ] RDS accesible desde app
- [ ] Redis funcionando
- [ ] CloudFront sirviendo contenido
- [ ] SSM Session Manager operativo
- [ ] Logs en CloudWatch
- [ ] SNS emails confirmados

### GitHub Actions
- [ ] Secrets configurados (frontend)
- [ ] Secrets configurados (backend)
- [ ] Workflows probados
- [ ] Deploys automáticos funcionando

### Verificación Final
- [ ] Frontend accesible via dominio
- [ ] Backend accesible via dominio
- [ ] Certificados válidos (sin warnings)
- [ ] Health checks pasando
- [ ] Alertas funcionando

---

## 🎉 ¡Deployment Completado!

Si llegaste hasta aquí y todos los checks están ✅, **¡felicitaciones!**

Tu infraestructura está:
- ✅ Desplegada en AWS
- ✅ Altamente disponible (Multi-AZ)
- ✅ Segura (WAF, GuardDuty, cifrado)
- ✅ Monitoreada (CloudWatch)
- ✅ Escalable (Auto Scaling)
- ✅ Lista para producción

### Próximos Pasos

1. **Deploy de aplicaciones:** Usar GitHub Actions para deployar frontend y backend
2. **Configurar dominio custom:** Apuntar dominios finales
3. **Testing de carga:** Probar autoscaling
4. **Documentar runbooks:** Para incidentes comunes
5. **Planificar backups:** Política de snapshots
6. **Revisar costos:** Después del primer mes

---

**¿Preguntas o problemas?** 
- Revisa la sección de [Troubleshooting](#10-troubleshooting)
- Verifica los logs en CloudWatch
- Usa SSM para conectarte a las instancias
- Revisa el state: `terraform show`

**Última actualización:** 2025-01-19
**Versión:** 1.0.0
