# 🚧 Stage 1: Recursos Comentados Temporalmente

Este archivo documenta qué recursos están comentados en **Stage 1** y deben ser descomentados en **Stage 2** después de validar los certificados ACM.

## 📝 Recursos Comentados (5 bloques)

### 1. HTTPS Listener (main.tf ~línea 542)
```hcl
resource "aws_lb_listener" "https"
```
**Razón:** Requiere certificado backend validado

### 2. HTTP→HTTPS Redirect (main.tf ~línea 555)
```hcl
resource "aws_lb_listener_rule" "redirect_http_to_https"
```
**Razón:** Depende del HTTPS listener

### 3. CloudFront Distribution (main.tf ~línea 332)
```hcl
module "cloudfront"
```
**Razón:** Requiere certificado frontend validado (us-east-1)

### 4. CloudFront OAC (main.tf ~línea 319)
```hcl
resource "aws_cloudfront_origin_access_control" "frontend"
```
**Razón:** Solo usado por CloudFront

### 5. S3 Bucket Policy OAC (main.tf ~línea 877)
```hcl
resource "aws_s3_bucket_policy" "frontend_oac"
```
**Razón:** Referencia a CloudFront distribution ARN

---

## ✅ Recursos que SÍ se crean en Stage 1

- ✅ VPC, Subnets, Security Groups
- ✅ ALB con **HTTP listener (puerto 80)**
- ✅ EC2 Launch Template & Auto Scaling Group
- ✅ RDS MySQL (Multi-AZ)
- ✅ ElastiCache Redis (Multi-AZ)
- ✅ S3 Buckets (logs, frontend, artifacts)
- ✅ **Certificados ACM (pending validation)**
- ✅ WAF, GuardDuty, CloudTrail
- ✅ CloudWatch, SNS
- ✅ IAM roles, CodeDeploy
- ✅ SSM Parameters

---

## 📋 Checklist Stage 1 → Stage 2

### Después de Stage 1:
- [ ] Obtener registros DNS: `terraform output frontend_cert_validation_records`
- [ ] Obtener registros DNS: `terraform output backend_cert_validation_records`
- [ ] Crear CNAMEs en Cloudflare/GoDaddy
- [ ] Esperar validación (5-30 min)
- [ ] Verificar: `aws acm describe-certificate --certificate-arn <arn>`
- [ ] Confirmar: Status = "ISSUED"

### Para Stage 2:
- [ ] Descomentar los 5 bloques listados arriba
- [ ] `terraform plan` (verificar ~30 recursos nuevos)
- [ ] `terraform apply`
- [ ] Esperar CloudFront distribution (10-15 min)
- [ ] Crear CNAME: app.tudominio.com → CloudFront
- [ ] Verificar HTTPS funcionando

---

**Fecha creación:** 2025-11-19
**Stage actual:** 1 (Base Infrastructure)
