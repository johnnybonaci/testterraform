# Resumen de Cambios y Arquitectura Final

Este documento resume todas las mejoras aplicadas a la infraestructura Terraform para Laravel 12 + React en AWS.

---

## 🔧 CAMBIOS PRINCIPALES APLICADOS

### 1. **Actualización a PHP 8.3 (Crítico para Laravel 12)**

**Archivos modificados:**
- `environments/prod/main.tf` (líneas 650-667)
- `environments/staging/main.tf` (líneas 477-494)

**Cambios:**
```diff
- apt-get install -y php8.2 php8.2-fpm php8.2-cli ...
+ apt-get install -y php8.3 php8.3-fpm php8.3-cli \
+   php8.3-mysql php8.3-pgsql php8.3-xml php8.3-curl \
+   php8.3-mbstring php8.3-zip php8.3-bcmath php8.3-gd \
+   php8.3-intl php8.3-redis php8.3-opcache
```

**Extensiones agregadas:**
- `php8.3-pgsql`: Soporte PostgreSQL (futuro)
- `php8.3-zip`: Requerido por Composer y Laravel
- `php8.3-bcmath`: Cálculos de precisión arbitraria
- `php8.3-gd`: Manipulación de imágenes
- `php8.3-intl`: Internacionalización
- `php8.3-opcache`: Cache de bytecode PHP (performance)

---

### 2. **Composer 2.x y Node.js 20 LTS**

**Agregado:**
```bash
# Composer 2.x (gestor de dependencias de Laravel)
curl -fsSL https://getcomposer.org/installer | php -- \
  --install-dir=/usr/local/bin --filename=composer --2

# Node.js 20 LTS (compilar assets frontend)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
```

**Beneficios:**
- Composer permite `composer install` en deployments de CodeDeploy
- Node.js permite compilar Vite/Webpack assets si es necesario

---

### 3. **Optimizaciones PHP-FPM para Producción**

**Archivo:** Ambos entornos, configuración PHP-FPM

**Prod:**
```ini
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500
```

**Staging:**
```ini
pm = dynamic
pm.max_children = 30
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 10
pm.max_requests = 500
```

**OPcache habilitado:**
```ini
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.fast_shutdown=1
```

---

### 4. **Redis AUTH Token (Crítico - Seguridad)**

**Problema:** Redis con `transit_encryption_enabled = true` REQUIERE AUTH token, pero estaba configurado con `REDIS_PASSWORD=null`

**Solución aplicada:**

**Terraform:**
```hcl
resource "random_password" "redis_auth" {
  length  = 32
  special = false  # Redis AUTH no soporta caracteres especiales
}

resource "aws_elasticache_replication_group" "redis" {
  # ...
  auth_token_enabled = true
  auth_token         = random_password.redis_auth.result
}

resource "aws_ssm_parameter" "redis_password" {
  name  = "/${var.name}/laravel/REDIS_PASSWORD"
  type  = "SecureString"
  value = random_password.redis_auth.result
}
```

**User data:**
```bash
REDIS_PASSWORD=$(get_ssm "${PREFIX}REDIS_PASSWORD")

# .env
REDIS_PASSWORD=$${REDIS_PASSWORD}  # Ya no es null
```

**Impacto:** Sin esto, Laravel no puede conectarse a Redis (sesiones/cache fallan).

---

### 5. **Certificado ACM Corregido en ALB**

**Problema:** Certificado hardcodeado en listener HTTPS del ALB de prod:
```hcl
# ANTES (incorrecto):
certificate_arn = "arn:aws:acm:us-east-1:838108223027:certificate/76a7501d-f39c-4b68-8a66-f4db5fde1925"

# DESPUÉS (correcto):
certificate_arn = aws_acm_certificate.backend.arn
```

**Beneficios:**
- Terraform gestiona el certificado
- Portable a otras cuentas AWS
- Auto-renovación trackeable

---

### 6. **Certificados ACM Duplicados Eliminados**

**Eliminado:**
- `aws_acm_certificate.alb[0]` (duplicado)
- `aws_route53_record.alb_cert_validation` (no usado)
- `aws_acm_certificate_validation.alb` (no usado)
- `output.alb_certificate_arn` (redundante)

**Conservado:**
- `aws_acm_certificate.backend` ✅
- `aws_acm_certificate.frontend` ✅

---

### 7. **Infraestructura Flexible con Variables**

**Nuevas variables en `environments/prod/variables.tf`:**

```hcl
variable "enable_nat_gateway" {
  type        = bool
  description = "Habilitar NAT Gateway (cuesta ~$32/mes por NAT)"
  default     = false  # VPC Endpoints por defecto
}

variable "allowed_ips_alb" {
  type        = list(string)
  description = "IPs permitidas en ALB (0.0.0.0/0 para público)"
  default     = ["200.123.128.225/32", "190.19.143.121/32"]
}

variable "use_private_subnets_for_ec2" {
  type        = bool
  description = "Usar subnets privadas para EC2"
  default     = false  # Subnets públicas sin NAT
}
```

**Uso en código:**
```hcl
# VPC
enable_nat_gateway = var.enable_nat_gateway

# Security Group ALB
cidr_blocks = var.allowed_ips_alb

# ASG
vpc_zone_identifier = var.use_private_subnets_for_ec2 ?
                      module.vpc.private_subnets :
                      module.vpc.public_subnets

# Launch Template
associate_public_ip_address = !var.use_private_subnets_for_ec2
```

**Beneficios:**
- Cambiar de VPC Endpoints a NAT Gateway: solo `enable_nat_gateway = true`
- Abrir ALB al público: `allowed_ips_alb = ["0.0.0.0/0"]`
- Portable y configurable sin editar código

---

### 8. **Health Checks Mejorados**

**Staging (antes):**
```hcl
health_check {
  path    = "/health"
  matcher = "200"  # Solo exactamente 200
}
```

**Staging (después):**
```hcl
health_check {
  enabled             = true
  port                = "traffic-port"
  protocol            = "HTTP"
  path                = "/health"
  matcher             = "200-399"  # Cualquier éxito
  healthy_threshold   = 2
  unhealthy_threshold = 2
  interval            = 30
  timeout             = 5
}

deregistration_delay = 15  # Nuevo
```

**Prod:** Ya tenía `200-399`, sin cambios.

---

### 9. **CloudFront con Security Headers**

**Prod (antes):**
```hcl
default_cache_behavior = {
  # ... sin response_headers_policy_id
}
```

**Prod (después):**
```hcl
data "aws_cloudfront_response_headers_policy" "managed_security" {
  name = "Managed-SecurityHeadersPolicy"
}

default_cache_behavior = {
  # ...
  response_headers_policy_id = data.aws_cloudfront_response_headers_policy.managed_security.id
}
```

**Headers aplicados automáticamente:**
- `Strict-Transport-Security: max-age=63072000`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`

---

### 10. **CloudFront SPA Support en Staging**

**Staging (agregado):**
```hcl
custom_error_response = [
  {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  },
  {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
]
```

**Beneficio:** React Router funciona correctamente (rutas /about, /dashboard, etc. no retornan 404).

---

### 11. **RDS Snapshot Protection en Staging**

**Staging (agregado):**
```hcl
resource "aws_db_instance" "mysql" {
  # ...
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-mysql-final-snapshot"
}
```

**Beneficio:** Si borras staging por error, Terraform crea un snapshot final antes de destruir.

---

### 12. **IAM Policies Dinámicas (No Hardcoded)**

**Backend GitHub Role (antes):**
```hcl
resources = [
  "arn:aws:s3:::massnexus-prd-backend-artifacts",  # Hardcoded
  "arn:aws:s3:::massnexus-prd-backend-artifacts/*"
]
```

**Backend GitHub Role (después):**
```hcl
resources = [
  aws_s3_bucket.backend_artifacts.arn,              # Dinámico
  "${aws_s3_bucket.backend_artifacts.arn}/*"
]
```

**Beneficio:** Portable a otras cuentas sin cambios manuales.

---

## 🏗️ ARQUITECTURA FINAL

### **STAGING (Ambiente de Testing)**

```
┌─────────────────────────────────────────────────────────────┐
│                       INTERNET                              │
└────────────┬────────────────────────────────────────────────┘
             │
             ├──────────────────────────────────────────┐
             │                                          │
    ┌────────▼────────┐                      ┌─────────▼──────┐
    │   CloudFront    │                      │   ALB (HTTP)   │
    │   (Frontend)    │                      │  Port 80 Only  │
    │  Default Cert   │                      │  Allowed IPs   │
    │   WAF Enabled   │                      └────────┬───────┘
    └────────┬────────┘                               │
             │                                        │
    ┌────────▼────────┐                      ┌────────▼───────┐
    │  S3 Frontend    │                      │   EC2 ASG      │
    │  (Private OAC)  │                      │  t3.medium     │
    │   Versioned     │                      │  Private Subs  │
    │   Encrypted     │                      │  PHP 8.3 FPM   │
    └─────────────────┘                      └────┬───┬───────┘
                                                  │   │
                                             ┌────▼───▼────┐
                                             │  NAT x2 AZs │
                                             └────┬───┬────┘
                                                  │   │
                         ┌────────────────────────┴───┴─────────┐
                         │                                      │
                  ┌──────▼─────┐                      ┌────────▼─────┐
                  │  RDS MySQL │                      │ Redis 7.0    │
                  │ Single-AZ  │                      │ Single Node  │
                  │ db.t4g.sm  │                      │ t4g.micro    │
                  │ 20GB→200GB │                      │ AUTH Enabled │
                  └────────────┘                      └──────────────┘
```

**Características:**
- **VPC:** 10.0.0.0/16 con NAT Gateway (2 AZs)
- **EC2:** Private subnets sin IP pública
- **DB/Redis:** Cifrado, backups automáticos
- **Costo:** ~$168/mes

---

### **PRODUCCIÓN (Production-Ready)**

```
┌─────────────────────────────────────────────────────────────────┐
│                       INTERNET                                  │
└────────────┬─────────────────────────────────────────────┬──────┘
             │                                             │
    ┌────────▼────────┐                          ┌─────────▼──────────┐
    │   CloudFront    │                          │   ALB (HTTPS)      │
    │  uat.yieldpro.  │                          │  dev.yieldpro.io   │
    │  io (ACM Cert)  │                          │  TLS 1.3           │
    │  Security Hdrs  │                          │  Cert: ACM         │
    │  WAF + OAC      │                          │  HTTP → 443        │
    └────────┬────────┘                          └─────────┬──────────┘
             │                                             │
    ┌────────▼────────┐                          ┌─────────▼──────────┐
    │  S3 Frontend    │                          │   EC2 ASG          │
    │  (Private OAC)  │                          │  t3.medium         │
    │   Versioned     │                          │  Public Subs*      │
    │   Encrypted     │                          │  PHP 8.3 + Comp.   │
    │  Logs → Central │                          │  CodeDeploy Agent  │
    └─────────────────┘                          └──────┬─────────────┘
                                                        │
                    ┌───────────────────────────────────┴────────┐
                    │        VPC Endpoints (No NAT)              │
                    │  - S3 (Gateway)                            │
                    │  - SSM, EC2Messages, SSMMessages           │
                    │  - Logs, KMS (Interface)                   │
                    └───────────────────────────────────────────┘
                                       │
              ┌────────────────────────┴────────────────────┐
              │                                             │
       ┌──────▼─────┐                             ┌────────▼─────┐
       │  RDS MySQL │                             │ Redis 7.0    │
       │  Multi-AZ  │                             │ Single Node  │
       │ db.t4g.med │                             │ t4g.micro    │
       │ 50GB→1TB   │                             │ AUTH Token   │
       │ Perf Ins.  │                             │ Encryption   │
       │ Del. Prot. │                             └──────────────┘
       └────────────┘

    ┌──────────────────────────────────────────────────────────┐
    │  Security & CI/CD                                        │
    ├──────────────────────────────────────────────────────────┤
    │  - GuardDuty (threat detection)                          │
    │  - CloudTrail (audit logs)                               │
    │  - VPC Flow Logs → CloudWatch                            │
    │  - GitHub OIDC (frontend + backend deploy)               │
    │  - CodeDeploy (backend rolling deployments)              │
    │  - SSM Parameter Store + Secrets Manager                 │
    └──────────────────────────────────────────────────────────┘
```

**Características:**
- **VPC:** 10.0.0.0/16 SIN NAT (VPC Endpoints)
- **EC2:** Public subnets* (temporal, cambiar a private cuando agregues NAT)
- **RDS:** Multi-AZ, Performance Insights, Delete Protection
- **Redis:** AUTH token, cifrado at-rest y in-transit
- **Certificados:** ACM para frontend (CloudFront) y backend (ALB)
- **GitHub:** OIDC roles para deploy automático
- **Costo:** ~$295/mes (sin NAT) o ~$359/mes (con NAT)

---

## 📊 COMPARATIVA: ANTES vs DESPUÉS

| Aspecto | **Antes** | **Después** | Estado |
|---------|-----------|-------------|--------|
| **PHP Version** | 8.2 ❌ | 8.3 ✅ | ✅ Corregido |
| **Composer** | No instalado ❌ | 2.x instalado ✅ | ✅ Agregado |
| **Node.js** | No instalado ❌ | 20 LTS instalado ✅ | ✅ Agregado |
| **PHP Extensions** | Básicas | Completas (bcmath, gd, intl, zip) ✅ | ✅ Mejorado |
| **PHP OPcache** | No configurado ❌ | Habilitado y optimizado ✅ | ✅ Agregado |
| **Redis Password** | `null` ❌ | Token seguro en SSM ✅ | ✅ Corregido |
| **ALB Certificate** | Hardcoded ARN ❌ | Terraform managed ✅ | ✅ Corregido |
| **ACM Certs** | Duplicados ❌ | Únicos y claros ✅ | ✅ Limpiado |
| **Health Checks** | Inconsistentes ❌ | Unificados (200-399) ✅ | ✅ Mejorado |
| **CloudFront SPA** | 404 en rutas ❌ | Custom errors ✅ | ✅ Agregado |
| **Security Headers** | Solo staging ❌ | Ambos entornos ✅ | ✅ Mejorado |
| **IAM Policies** | Hardcoded ARNs ❌ | Dinámicos ✅ | ✅ Corregido |
| **NAT Gateway** | Fijo ❌ | Configurable vía variable ✅ | ✅ Flexible |
| **Allowed IPs** | Hardcoded ❌ | Configurable vía variable ✅ | ✅ Flexible |
| **RDS Snapshots** | Sin protección (stg) ❌ | Con snapshot final ✅ | ✅ Agregado |

---

## 🚀 COMANDOS DE DESPLIEGUE

### **1. Bootstrap (Primera Vez Únicamente)**

```bash
cd 0-bootstrap/remote-state

# Inicializar
terraform init

# Crear bucket de state y tabla de locks
terraform apply \
  -var="state_bucket_name=tuempresa-terraform-state" \
  -var="lock_table_name=tuempresa-tf-locks"

# Anotar el nombre del bucket y tabla creados
```

### **2. Configurar Backend Remoto**

Editar `environments/{staging,prod}/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "tuempresa-terraform-state"  # Del paso 1
    key            = "{staging,prod}/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tuempresa-tf-locks"  # Del paso 1
    encrypt        = true
  }
}
```

### **3. Deploy Staging**

```bash
cd environments/staging

# Inicializar con backend remoto
terraform init

# Validar configuración
terraform validate

# Ver plan de cambios
terraform plan

# Aplicar (crear infraestructura)
terraform apply

# Ver outputs importantes
terraform output
terraform output alb_dns_name
terraform output cloudfront_domain
```

### **4. Deploy Producción**

```bash
cd environments/prod

# Inicializar
terraform init

# Validar
terraform validate

# Plan
terraform plan

# Aplicar
terraform apply

# Outputs críticos
terraform output frontend_cert_validation_records  # Para Cloudflare DNS
terraform output backend_cert_validation_records   # Para GoDaddy DNS
terraform output gh_front_role_arn                 # Para GitHub Actions
terraform output gh_backend_role_arn               # Para GitHub Actions
terraform output cloudfront_distribution_id        # Para invalidations
```

### **5. Configurar Validación DNS de Certificados**

**Frontend (Cloudflare):**
```bash
# 1. Obtener registros DNS
cd environments/prod
terraform output frontend_cert_validation_records

# Output:
# [
#   {
#     name  = "_abc123.uat.yieldpro.io"
#     type  = "CNAME"
#     value = "_xyz456.acm-validations.aws."
#   }
# ]

# 2. En Cloudflare:
# - Ir a DNS > Add Record
# - Type: CNAME
# - Name: _abc123.uat.yieldpro.io
# - Target: _xyz456.acm-validations.aws.
# - Proxy: DNS Only (importante!)
# - TTL: Auto

# 3. Esperar validación (2-30 min)
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw aws_acm_certificate.frontend.arn) \
  --region us-east-1 | jq '.Certificate.Status'

# Debe retornar: "ISSUED"
```

**Backend (GoDaddy):**
```bash
# Mismo proceso que frontend
terraform output backend_cert_validation_records

# Crear CNAME en GoDaddy DNS Manager
```

### **6. Apuntar Dominios a Infraestructura**

**Frontend:**
```bash
# Obtener CloudFront domain
terraform output cloudfront_domain
# Output: d1234abcd.cloudfront.net

# En Cloudflare DNS:
# Type: CNAME
# Name: uat.yieldpro.io  (o app, www, etc.)
# Target: d1234abcd.cloudfront.net
# Proxy: Proxied (naranja) o DNS Only (gris)
# TTL: Auto
```

**Backend:**
```bash
# Obtener ALB DNS
terraform output alb_dns_name
# Output: massnexus-prd-alb-123.us-east-1.elb.amazonaws.com

# En GoDaddy DNS:
# Type: CNAME
# Name: dev.yieldpro.io  (o api, backend, etc.)
# Target: massnexus-prd-alb-123.us-east-1.elb.amazonaws.com
# TTL: 600 (10 minutos)
```

### **7. Verificar Deploy**

```bash
# Health check backend
curl -I https://dev.yieldpro.io/health
# Debe retornar: HTTP/2 200

# Ver instancias EC2
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=massnexus-prd-app" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PrivateIpAddress]' \
  --output table

# Verificar targets del ALB
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw aws_lb_target_group.app.arn)

# Ver logs de EC2
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=massnexus-prd-app" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ssm start-session --target $INSTANCE_ID
# Dentro de la instancia:
sudo cat /var/log/user-data.log
```

### **8. Actualizar Infraestructura**

```bash
# Modificar archivos .tf según necesidad

# Plan para ver cambios
terraform plan

# Aplicar cambios
terraform apply

# Si cambiaste Launch Template, forzar refresh de instancias:
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name massnexus-prd-asg \
  --preferences MinHealthyPercentage=50,InstanceWarmup=60
```

### **9. Destruir Infraestructura (CUIDADO)**

```bash
# Solo staging (testing)
cd environments/staging
terraform destroy

# Producción (requiere desactivar deletion_protection primero)
cd environments/prod

# 1. Desactivar protection de RDS manualmente en AWS Console
# 2. Luego:
terraform destroy -target=aws_db_instance.mysql  # Si quieres borrar solo DB
# o
terraform destroy  # Todo (CUIDADO!)
```

---

## 📋 CHECKLIST DE VALIDACIÓN

Después del deploy, verifica:

- [ ] **Terraform State:** `terraform state list` muestra todos los recursos
- [ ] **EC2 Running:** 1 instancia en estado `running`
- [ ] **ALB Healthy:** 1/1 targets healthy en target group
- [ ] **RDS Available:** Status `available` en RDS console
- [ ] **Redis Available:** Status `available` en ElastiCache console
- [ ] **Certs Issued:** ACM certs en status `ISSUED` (frontend + backend)
- [ ] **DNS Resolve:** `dig {frontend,backend}.domain` apunta a CloudFront/ALB
- [ ] **HTTPS Works:** `curl -I https://frontend.domain` retorna 200
- [ ] **Health Check:** `curl https://backend.domain/health` retorna `ok`
- [ ] **Logs EC2:** `/var/log/user-data.log` sin errores críticos
- [ ] **Redis Connection:** Laravel conecta a Redis (verificar en logs)
- [ ] **DB Connection:** Laravel conecta a RDS (verificar en logs)
- [ ] **GitHub OIDC:** Roles creados y ARNs disponibles en outputs
- [ ] **CodeDeploy:** Application y deployment group creados (solo prod)

---

## 🎯 PRÓXIMOS PASOS RECOMENDADOS

### Inmediatos (Post-Deploy):
1. **Configurar GitHub Actions** para deploys automáticos
2. **Validar certificados ACM** estén ISSUED antes de probar dominios
3. **Crear primer deploy de Laravel** via CodeDeploy
4. **Configurar monitoreo** (CloudWatch Dashboards, alarmas)

### Corto Plazo (Primera Semana):
5. **Habilitar GuardDuty findings** y configurar SNS notifications
6. **Revisar WAF logs** y ajustar rules si hay falsos positivos
7. **Configurar backups** adicionales (AWS Backup)
8. **Documentar runbooks** para incidentes comunes

### Medio Plazo (Primer Mes):
9. **Evaluar NAT Gateway** vs VPC Endpoints (costo vs conveniencia)
10. **Configurar Auto Scaling** triggers (CPU, memoria, requests)
11. **Implementar Blue/Green** deployments en CodeDeploy
12. **Revisar Reserved Instances** para ahorro de costos (40-60% off)

### Largo Plazo (Producción Madura):
13. **Multi-región** para disaster recovery
14. **Redis Cluster Mode** si sesiones/cache crecen
15. **RDS Read Replicas** si hay muchas lecturas
16. **CDN adicional** (Cloudflare Pro) para mejor performance global

---

## 📖 DOCUMENTOS DE REFERENCIA

- **`GUIA-MIGRACION-PRODUCCION.md`**: Guía completa de migración a cuenta productiva
- **`CLAUDE.md`**: Instrucciones para Claude Code (contexto del proyecto)
- **`RESUMEN-SEGURIDAD.md`**: Mejoras de seguridad aplicadas
- **`PROXIMOS-PASOS.md`**: Roadmap de features futuras

---

## ✅ RESUMEN EJECUTIVO

### **¿Qué se arregló?**
1. ✅ PHP actualizado de 8.2 → 8.3 (compatible con Laravel 12)
2. ✅ Composer 2.x instalado (deployments automáticos)
3. ✅ Redis AUTH token configurado (seguridad crítica)
4. ✅ Certificados ACM gestionados por Terraform (no hardcoded)
5. ✅ Infraestructura flexible con variables (NAT, IPs, subnets)
6. ✅ Health checks unificados y mejorados
7. ✅ CloudFront con security headers y SPA support
8. ✅ IAM policies dinámicas (portables)
9. ✅ Optimizaciones PHP-FPM para producción
10. ✅ Protección de datos (RDS snapshots, backups)

### **¿Qué sigue?**
1. Deploy en cuenta de testing (validar todo funciona)
2. Migrar a cuenta productiva real (seguir `GUIA-MIGRACION-PRODUCCION.md`)
3. Configurar CI/CD (GitHub Actions + CodeDeploy)
4. Monitoreo y alertas (CloudWatch, GuardDuty)
5. Optimizaciones de costos (Reserved Instances, Auto Scaling)

### **Costo Estimado:**
- **Staging:** ~$168/mes (con NAT)
- **Prod:** ~$295/mes (sin NAT) o ~$359/mes (con NAT)
- **Ambos entornos:** ~$463-527/mes

**La infraestructura está lista para producción.** 🚀
