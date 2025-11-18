# Guía de Migración a Producción Real

Esta guía te ayudará a migrar la infraestructura de testing a tu cuenta AWS productiva con dominios reales.

---

## 📋 CHECKLIST PRE-MIGRACIÓN

### 1. Preparación de la Cuenta AWS

- [ ] Crear cuenta AWS productiva (si no existe)
- [ ] Configurar MFA en cuenta root
- [ ] Crear usuario IAM con permisos de administrador
- [ ] Configurar AWS CLI con credenciales: `aws configure --profile production`
- [ ] Habilitar AWS Organizations (recomendado)
- [ ] Activar CloudTrail en todas las regiones
- [ ] Configurar AWS Budgets y alertas de costos

### 2. Dominios y DNS

**Frontend:**
- [ ] Registrar dominio principal (ej: `yieldpro.com`)
- [ ] Configurar registrador DNS (Cloudflare, Route53, GoDaddy)
- [ ] Decidir subdominio para frontend:
  - Opción 1: `app.yieldpro.com` (recomendado)
  - Opción 2: `www.yieldpro.com`
  - Opción 3: `yieldpro.com` (apex)

**Backend API:**
- [ ] Decidir subdominio para backend:
  - Opción 1: `api.yieldpro.com` (recomendado)
  - Opción 2: `backend.yieldpro.com`

### 3. Repositorios GitHub

- [ ] Crear/verificar repositorio frontend: `org/nombre-front`
- [ ] Crear/verificar repositorio backend: `org/nombre-back`
- [ ] Configurar protección de branch `main` (requiere PR + aprobación)
- [ ] Agregar secrets de GitHub Actions (se configurarán después del deploy)

### 4. Decisiones de Infraestructura

**Networking:**
- [ ] ¿Habilitar NAT Gateway en prod? (costo: ~$32/mes por NAT)
  - ✅ Sí: Mayor seguridad, EC2 en subnets privadas
  - ❌ No: Más barato, usa VPC Endpoints (actual)

**IPs Permitidas:**
- [ ] Decidir IPs permitidas para ALB de prod:
  - Opción 1: Lista específica de IPs de oficina/VPN
  - Opción 2: `0.0.0.0/0` si la app es pública (recomendado con WAF)

**Emails de Alertas:**
- [ ] Email para alertas de seguridad (GuardDuty, CloudTrail)
- [ ] Email para alertas de costos (AWS Budgets)

---

## 🔧 CONFIGURACIÓN PASO A PASO

### PASO 1: Preparar Variables de Producción

Edita `environments/prod/variables.tf` y actualiza:

```hcl
variable "name" {
  default = "tuempresa-prd"  # Cambiar nombre del proyecto
}

variable "frontend_domain_name" {
  default = "app.tudominio.com"  # Tu dominio real de frontend
}

variable "backend_domain_name" {
  default = "api.tudominio.com"  # Tu dominio real de backend
}

variable "github_repo_front" {
  default = "tuorg/tuapp-frontend"  # Tu repo real
}

variable "github_repo_back" {
  default = "tuorg/tuapp-backend"  # Tu repo real
}

variable "security_alert_email" {
  default = "security@tuempresa.com"  # Tu email real
}

variable "allowed_ips_alb" {
  default = [
    "0.0.0.0/0"  # Público, o lista de IPs específicas
  ]
}

variable "enable_nat_gateway" {
  default = false  # true si quieres NAT Gateway ($32/mes)
}

variable "use_private_subnets_for_ec2" {
  default = false  # true solo si enable_nat_gateway = true
}
```

### PASO 2: Preparar Remote State

```bash
# 1. Editar configuración del remote state
cd 0-bootstrap/remote-state

# 2. Cambiar nombre del bucket en el deploy (usa uno único)
terraform init
terraform plan -var="state_bucket_name=tuempresa-terraform-state" \
               -var="lock_table_name=tuempresa-tf-locks"

terraform apply -var="state_bucket_name=tuempresa-terraform-state" \
                -var="lock_table_name=tuempresa-tf-locks"

# 3. Anotar el nombre del bucket creado
```

### PASO 3: Configurar Backend de Staging

Edita `environments/staging/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "tuempresa-terraform-state"  # El bucket del paso 2
    key            = "staging/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tuempresa-tf-locks"  # La tabla del paso 2
    encrypt        = true
  }
}
```

### PASO 4: Configurar Backend de Producción

Edita `environments/prod/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "tuempresa-terraform-state"  # El bucket del paso 2
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tuempresa-tf-locks"  # La tabla del paso 2
    encrypt        = true
  }
}
```

### PASO 5: Deploy de Staging (Prueba)

```bash
cd environments/staging

# 1. Inicializar con el backend remoto
terraform init

# 2. Revisar el plan (verifica nombres de buckets S3)
terraform plan

# 3. Si hay conflictos de nombres de buckets S3, edita variables.tf:
#    - Cambia el nombre base de "massnexus-stg" a "tuempresa-stg"

# 4. Aplicar infraestructura
terraform apply

# 5. Anotar outputs importantes
terraform output
```

**Outputs importantes de staging:**
- `alb_dns_name`: DNS del ALB (para probar backend)
- `cloudfront_domain`: DNS de CloudFront (para probar frontend)
- `rds_endpoint`: Endpoint de la base de datos

### PASO 6: Deploy de Producción

```bash
cd environments/prod

# 1. Inicializar
terraform init

# 2. Revisar el plan
terraform plan

# 3. Si hay conflictos de nombres, edita variables.tf
#    (nombres de buckets S3 deben ser únicos globalmente)

# 4. Aplicar infraestructura
terraform apply

# 5. IMPORTANTE: Anotar los outputs para configurar DNS
terraform output frontend_cert_validation_records
terraform output backend_cert_validation_records
terraform output cloudfront_distribution_id
terraform output gh_front_role_arn
terraform output gh_backend_role_arn
```

### PASO 7: Configurar DNS para Certificados ACM

**Frontend (CloudFront):**

```bash
# 1. Obtener registros DNS para validación
terraform output frontend_cert_validation_records

# Output ejemplo:
# [
#   {
#     name  = "_abc123.app.tudominio.com"
#     type  = "CNAME"
#     value = "_xyz456.acm-validations.aws."
#   }
# ]

# 2. Crear el registro CNAME en tu registrador DNS (Cloudflare/GoDaddy/Route53)
#    Nombre: _abc123.app.tudominio.com
#    Tipo: CNAME
#    Valor: _xyz456.acm-validations.aws.

# 3. Esperar validación (2-30 minutos)
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw frontend_cert_arn) \
  --region us-east-1

# Status debe cambiar a: "Status": "ISSUED"
```

**Backend (ALB):**

```bash
# 1. Obtener registros DNS
terraform output backend_cert_validation_records

# 2. Crear CNAME en DNS (mismo proceso que frontend)

# 3. Verificar
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw backend_cert_arn) \
  --region us-east-1
```

### PASO 8: Apuntar Dominios a la Infraestructura

**Frontend (React SPA):**

```bash
# 1. Obtener el dominio de CloudFront
terraform output cloudfront_domain
# Output: d1234abcd5678.cloudfront.net

# 2. Crear registro en DNS:
#    - Tipo: CNAME (o ALIAS si usas Route53)
#    - Nombre: app.tudominio.com
#    - Valor: d1234abcd5678.cloudfront.net
#    - TTL: 300 (5 minutos)
```

**Backend (Laravel API):**

```bash
# 1. Obtener el DNS del ALB
terraform output alb_dns_name
# Output: tuempresa-prd-alb-1234567890.us-east-1.elb.amazonaws.com

# 2. Crear registro en DNS:
#    - Tipo: CNAME (o ALIAS si usas Route53)
#    - Nombre: api.tudominio.com
#    - Valor: tuempresa-prd-alb-1234567890.us-east-1.elb.amazonaws.com
#    - TTL: 300
```

### PASO 9: Configurar GitHub Actions

**Frontend Deploy:**

```bash
# 1. Obtener el ARN del rol
terraform output gh_front_role_arn

# 2. En GitHub, ir a Settings > Secrets and variables > Actions
# 3. Crear secrets:
#    - AWS_ROLE_ARN: (el ARN del paso 1)
#    - AWS_REGION: us-east-1
#    - S3_BUCKET: (terraform output frontend_bucket)
#    - CLOUDFRONT_DISTRIBUTION_ID: (terraform output cloudfront_distribution_id)
```

**Ejemplo de workflow frontend** (`.github/workflows/deploy.yml`):

```yaml
name: Deploy Frontend

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build
        env:
          REACT_APP_API_URL: https://api.tudominio.com

      - name: Deploy to S3
        run: |
          aws s3 sync build/ s3://${{ secrets.S3_BUCKET }}/ --delete

      - name: Invalidate CloudFront cache
        run: |
          aws cloudfront create-invalidation \
            --distribution-id ${{ secrets.CLOUDFRONT_DISTRIBUTION_ID }} \
            --paths "/*"
```

**Backend Deploy (con CodeDeploy):**

```bash
# 1. Obtener el ARN del rol
terraform output gh_backend_role_arn

# 2. Crear secrets en GitHub:
#    - AWS_ROLE_ARN: (el ARN del paso 1)
#    - AWS_REGION: us-east-1
#    - CODEDEPLOY_APP: (terraform output codedeploy_app_name)
#    - CODEDEPLOY_GROUP: (terraform output codedeploy_deployment_group)
#    - ARTIFACTS_BUCKET: (terraform output backend_artifacts_bucket)
```

**Ejemplo de workflow backend** (`.github/workflows/deploy.yml`):

```yaml
name: Deploy Backend

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Create deployment package
        run: |
          zip -r deployment.zip . \
            -x "*.git*" \
            -x "*node_modules*" \
            -x "*.env*" \
            -x "*tests*"

      - name: Upload to S3
        run: |
          aws s3 cp deployment.zip \
            s3://${{ secrets.ARTIFACTS_BUCKET }}/deployments/${{ github.sha }}.zip

      - name: Trigger CodeDeploy
        run: |
          aws deploy create-deployment \
            --application-name ${{ secrets.CODEDEPLOY_APP }} \
            --deployment-group-name ${{ secrets.CODEDEPLOY_GROUP }} \
            --s3-location bucket=${{ secrets.ARTIFACTS_BUCKET }},key=deployments/${{ github.sha }}.zip,bundleType=zip
```

### PASO 10: Configurar CodeDeploy en el Backend Laravel

Crea `appspec.yml` en la raíz de tu repo backend:

```yaml
version: 0.0
os: linux
files:
  - source: /
    destination: /var/www/app
    overwrite: true

permissions:
  - object: /var/www/app
    owner: www-data
    group: www-data
    mode: 755
    type:
      - directory
      - file
  - object: /var/www/app/storage
    owner: www-data
    group: www-data
    mode: 775
    type:
      - directory
  - object: /var/www/app/bootstrap/cache
    owner: www-data
    group: www-data
    mode: 775
    type:
      - directory

hooks:
  BeforeInstall:
    - location: scripts/before_install.sh
      timeout: 300
      runas: root

  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 600
      runas: root

  ApplicationStart:
    - location: scripts/start_application.sh
      timeout: 60
      runas: root

  ValidateService:
    - location: scripts/validate_service.sh
      timeout: 60
      runas: root
```

Crea `scripts/before_install.sh`:

```bash
#!/bin/bash
set -e

echo "Removing old application files..."
rm -rf /var/www/app/vendor
rm -rf /var/www/app/public/build
```

Crea `scripts/after_install.sh`:

```bash
#!/bin/bash
set -e

cd /var/www/app

echo "Installing Composer dependencies..."
composer install --no-dev --optimize-autoloader --no-interaction

echo "Setting permissions..."
chown -R www-data:www-data /var/www/app
chmod -R 755 /var/www/app
chmod -R 775 /var/www/app/storage
chmod -R 775 /var/www/app/bootstrap/cache

echo "Running migrations..."
php artisan migrate --force

echo "Clearing caches..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

echo "Optimizing..."
php artisan optimize
```

Crea `scripts/start_application.sh`:

```bash
#!/bin/bash
set -e

echo "Restarting PHP-FPM..."
systemctl restart php8.3-fpm

echo "Reloading Nginx..."
systemctl reload nginx
```

Crea `scripts/validate_service.sh`:

```bash
#!/bin/bash
set -e

echo "Validating application..."
curl -f http://localhost/health || exit 1
echo "Application is healthy!"
```

---

## ✅ VALIDACIONES POST-DEPLOY

### 1. Verificar Infraestructura

```bash
# Staging
cd environments/staging
terraform output

# Prod
cd environments/prod
terraform output

# Verificar recursos en AWS Console:
# - VPC y subnets
# - EC2 instances (debería haber 1 running)
# - RDS (status: available)
# - Redis (status: available)
# - ALB (status: active, targets: 1 healthy)
# - CloudFront (status: deployed)
```

### 2. Verificar Certificados ACM

```bash
# Frontend cert (debe estar ISSUED)
aws acm describe-certificate \
  --certificate-arn $(cd environments/prod && terraform output -raw frontend_cert_arn) \
  --region us-east-1 | jq '.Certificate.Status'

# Backend cert (debe estar ISSUED)
aws acm describe-certificate \
  --certificate-arn $(cd environments/prod && terraform output -raw backend_cert_arn) \
  --region us-east-1 | jq '.Certificate.Status'
```

### 3. Verificar DNS

```bash
# Frontend
dig app.tudominio.com
# Debe resolver a CloudFront (d1234abcd.cloudfront.net)

# Backend
dig api.tudominio.com
# Debe resolver a ALB (*.elb.amazonaws.com)
```

### 4. Probar Backend

```bash
# Health check (debe retornar 200 OK)
curl -I https://api.tudominio.com/health

# Debe retornar phpinfo() placeholder
curl https://api.tudominio.com/
```

### 5. Probar Frontend

```bash
# Visitar en navegador
open https://app.tudominio.com

# Debe cargar CloudFront (aunque sea placeholder de React)
```

### 6. Verificar Logs

```bash
# Ver logs de user-data en EC2
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=tuempresa-prd-app" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ssm start-session --target $INSTANCE_ID

# Dentro de la instancia:
sudo cat /var/log/user-data.log
sudo journalctl -u nginx -n 50
sudo journalctl -u php8.3-fpm -n 50
```

---

## 🚨 TROUBLESHOOTING COMÚN

### Problema: Certificado ACM no se valida

**Causa:** El registro CNAME no se creó correctamente en DNS
**Solución:**
```bash
# 1. Verificar que el CNAME existe
dig _abc123.app.tudominio.com CNAME

# 2. Si no aparece, recrear en el registrador DNS
# 3. Esperar 5-30 minutos (propagación DNS)
```

### Problema: Health check failing en ALB

**Causa:** EC2 no responde en `/health` o timeout
**Solución:**
```bash
# 1. Conectarse a la instancia
aws ssm start-session --target $INSTANCE_ID

# 2. Verificar Nginx
sudo systemctl status nginx
curl http://localhost/health

# 3. Ver logs
sudo cat /var/log/user-data.log
sudo journalctl -u nginx -f
```

### Problema: CloudFront retorna 403

**Causa:** Bucket policy de S3 no permite acceso de CloudFront
**Solución:**
```bash
# Verificar bucket policy
aws s3api get-bucket-policy --bucket tuempresa-prd-frontend | jq .

# Debe contener la policy con AWS:SourceArn del CloudFront
# Si no, hacer terraform apply de nuevo
```

### Problema: RDS connection timeout

**Causa:** Security group o subnets incorrectas
**Solución:**
```bash
# 1. Verificar security group DB permite tráfico desde App
aws ec2 describe-security-groups --group-ids sg-xxx

# 2. Probar desde EC2
aws ssm start-session --target $INSTANCE_ID

# Dentro de la instancia:
mysql -h <rds-endpoint> -u appuser -p
# (password está en /var/www/app/.env)
```

---

## 💰 ESTIMACIÓN DE COSTOS MENSUALES

### Staging (ambiente de prueba):

| Recurso | Costo Mensual (USD) |
|---------|---------------------|
| EC2 t3.medium (1x) | ~$30 |
| NAT Gateway (2x AZs) | ~$64 |
| RDS db.t4g.small (Single-AZ) | ~$25 |
| Redis cache.t4g.micro | ~$12 |
| ALB | ~$22 |
| CloudFront | ~$10 (depende del tráfico) |
| S3 | ~$5 |
| **TOTAL STAGING** | **~$168/mes** |

### Producción (sin NAT Gateway):

| Recurso | Costo Mensual (USD) |
|---------|---------------------|
| EC2 t3.medium (1x) | ~$30 |
| VPC Endpoints (5x) | ~$36 |
| RDS db.t4g.medium (Multi-AZ) | ~$100 |
| Redis cache.t4g.micro | ~$12 |
| ALB | ~$22 |
| CloudFront | ~$50 (depende del tráfico) |
| S3 | ~$15 |
| GuardDuty | ~$15 |
| CloudTrail | ~$5 |
| WAF | ~$10 |
| **TOTAL PROD** | **~$295/mes** |

### Producción (con NAT Gateway):

Si habilitas `enable_nat_gateway = true`:
- NAT Gateway (2x AZs): +$64/mes
- **TOTAL PROD CON NAT**: **~$359/mes**

---

## 📚 COMANDOS DE REFERENCIA RÁPIDA

### Terraform Básico

```bash
# Formato de código
terraform fmt -recursive

# Validar sintaxis
terraform validate

# Plan (ver cambios)
terraform plan

# Aplicar cambios
terraform apply

# Destruir todo (¡CUIDADO!)
terraform destroy

# Ver outputs
terraform output

# Refresh state desde AWS
terraform refresh
```

### Gestión de State

```bash
# Listar recursos en state
terraform state list

# Ver detalles de un recurso
terraform state show aws_lb.app

# Importar recurso existente
terraform import aws_lb.app <alb-arn>

# Mover recurso en state
terraform state mv aws_lb.app aws_lb.new_app
```

### AWS CLI Útiles

```bash
# Ver instancias EC2
aws ec2 describe-instances --filters "Name=tag:env,Values=prod"

# Ver logs de CloudWatch
aws logs tail /vpc/tuempresa-prd --follow

# Invalidar cache de CloudFront
aws cloudfront create-invalidation \
  --distribution-id E123456 \
  --paths "/*"

# Ver deployments de CodeDeploy
aws deploy list-deployments \
  --application-name tuempresa-prd-backend

# Conectarse a EC2 via SSM
aws ssm start-session --target i-1234567890abcdef0
```

---

## 🎯 PRÓXIMOS PASOS RECOMENDADOS

Después del deploy inicial:

1. **Monitoreo:**
   - Configurar CloudWatch Dashboards
   - Crear alarmas de CloudWatch (CPU, memoria, errores)
   - Revisar GuardDuty findings semanalmente

2. **Backups:**
   - Verificar que RDS snapshots automáticos funcionan
   - Considerar AWS Backup para centralizar backups

3. **Seguridad:**
   - Revisar Security Hub findings
   - Habilitar AWS Config para compliance
   - Configurar VPN o bastion host para acceso SSH (si se necesita)

4. **Optimización:**
   - Revisar CloudWatch Insights para optimizar queries
   - Considerar Reserved Instances para EC2/RDS (ahorro 40-60%)
   - Habilitar S3 Intelligent-Tiering para logs antiguos

5. **CI/CD:**
   - Agregar tests automatizados en GitHub Actions
   - Configurar despliegues Blue/Green en CodeDeploy
   - Implementar rollback automático si health checks fallan

6. **Escalabilidad:**
   - Configurar Auto Scaling triggers (CPU > 70% durante 5 min)
   - Considerar RDS read replicas si hay mucha lectura
   - Evaluar Redis cluster mode si sesiones crecen

---

## ✉️ SOPORTE

Si tienes problemas durante la migración:

1. Revisa logs de Terraform: `TF_LOG=DEBUG terraform apply`
2. Revisa logs de EC2: `/var/log/user-data.log`
3. Verifica Security Groups y NACLs en AWS Console
4. Contacta al equipo de DevOps para revisión

**Documentación oficial:**
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Laravel Deployment](https://laravel.com/docs/12.x/deployment)
- [AWS CodeDeploy](https://docs.aws.amazon.com/codedeploy/latest/userguide/welcome.html)
- [GitHub Actions AWS](https://github.com/aws-actions)
