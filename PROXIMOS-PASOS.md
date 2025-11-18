# ⏭️ Próximos Pasos - Configuración de Dominios

## 📊 Estado Actual

Terraform está aplicando los cambios para migrar a los nuevos dominios:
- ✅ Frontend: `yieldpro.massnexus.com` → `uat.yieldpro.io`
- ✅ Backend: `ypback.massnexus.com` → `dev.yieldpro.io`

⏳ **Tiempo estimado**: 5-15 minutos (CloudFront tarda en propagar)

---

## 1️⃣ Configurar Cloudflare (AHORA)

### A. Registro CNAME para Frontend

```
Ir a: Cloudflare → yieldpro.io → DNS → Add record

Type:    CNAME
Name:    uat
Target:  dwtt8ee6z8sy3.cloudfront.net
TTL:     Auto
Proxy:   DNS only (⚠️ IMPORTANTE: Nube GRIS, NO naranja)
```

### B. Registro CNAME para Backend

```
Type:    CNAME
Name:    dev
Target:  massnexus-prd-alb-1228840083.us-east-1.elb.amazonaws.com
TTL:     Auto
Proxy:   DNS only (⚠️ IMPORTANTE: Nube GRIS, NO naranja)
```

---

## 2️⃣ Esperar que Terraform Termine

Una vez que termine, ejecuta:

```bash
cd /Users/johnnybonaci/Herd/terraform/environments/prod

# Ver outputs importantes
terraform output

# Ver registros de validación ACM
terraform output frontend_cert_validation_records
terraform output backend_cert_validation_records
```

---

## 3️⃣ Agregar Registros de Validación ACM

Los outputs te darán algo como:

```json
[
  {
    "name"  = "_abc123.uat.yieldpro.io.",
    "type"  = "CNAME",
    "value" = "_xyz789.acm-validations.aws."
  }
]
```

Agregar en Cloudflare:

```
Type:    CNAME
Name:    _abc123.uat   (el name sin el dominio)
Target:  _xyz789.acm-validations.aws.  (el value completo)
TTL:     Auto
Proxy:   DNS only
```

Hacer lo mismo para el backend (`dev.yieldpro.io`).

---

## 4️⃣ Esperar Validación de Certificados

⏳ **Tiempo**: 5-30 minutos

Verificar estado:

```bash
# Frontend
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw frontend_cert_arn) \
  --region us-east-1 \
  --query 'Certificate.Status'

# Backend
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw backend_cert_arn) \
  --region us-east-1 \
  --query 'Certificate.Status'
```

Cuando ambos muestren `"ISSUED"`, estás listo.

---

## 5️⃣ Probar que Funciona

### Test Frontend

```bash
# DNS
dig uat.yieldpro.io

# HTTPS
curl -I https://uat.yieldpro.io
```

**Esperado**: `HTTP/2 200` con headers de CloudFront

### Test Backend

```bash
# DNS
dig dev.yieldpro.io

# HTTPS
curl -I https://dev.yieldpro.io
```

**Esperado**: `HTTP/1.1 200 OK` con headers de nginx/Laravel

---

## 6️⃣ Actualizar Configuración de Aplicaciones

### Frontend (.env o config)

```env
VITE_API_URL=https://dev.yieldpro.io/api
VITE_APP_URL=https://uat.yieldpro.io
```

### Backend (.env Laravel)

```env
APP_URL=https://dev.yieldpro.io
FRONTEND_URL=https://uat.yieldpro.io

# CORS
SANCTUM_STATEFUL_DOMAINS=uat.yieldpro.io
SESSION_DOMAIN=.yieldpro.io

# Si usas subdomains
APP_DOMAIN=yieldpro.io
```

### Actualizar en SSM Parameter Store

```bash
# Actualizar parámetros en AWS
aws ssm put-parameter \
  --name "/massnexus-prd/laravel/APP_URL" \
  --value "https://dev.yieldpro.io" \
  --type "String" \
  --overwrite

aws ssm put-parameter \
  --name "/massnexus-prd/laravel/FRONTEND_URL" \
  --value "https://uat.yieldpro.io" \
  --type "String" \
  --overwrite
```

---

## 7️⃣ Re-deployar Aplicaciones

### Frontend (GitHub Actions)

```bash
# Push a main/master para trigger CI/CD
git add .
git commit -m "Update domain to uat.yieldpro.io"
git push origin main
```

### Backend (CodeDeploy)

```bash
# Si ya tiene CI/CD configurado:
git add .
git commit -m "Update domain to dev.yieldpro.io"
git push origin main

# O manual con AWS CLI:
aws deploy create-deployment \
  --application-name massnexus-prd-backend \
  --deployment-group-name massnexus-prd-backend-dg \
  --s3-location bucket=massnexus-prd-backend-artifacts,key=latest.zip,bundleType=zip
```

---

## ✅ Checklist Final

- [ ] Registros CNAME en Cloudflare creados (uat, dev)
- [ ] Ambos en modo "DNS only" (nube gris)
- [ ] Terraform apply terminado exitosamente
- [ ] Registros de validación ACM agregados
- [ ] Certificados en estado `ISSUED`
- [ ] `curl https://uat.yieldpro.io` retorna 200
- [ ] `curl https://dev.yieldpro.io` retorna 200
- [ ] Variables de entorno actualizadas
- [ ] SSM parameters actualizados
- [ ] Aplicaciones re-deployadas
- [ ] WAF funcionando correctamente
- [ ] CORS configurado para nuevo dominio

---

## 🚨 Si Algo Falla

### Certificado no valida

```bash
# Ver detalles del error
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw frontend_cert_arn) \
  --region us-east-1
```

Verificar que el CNAME de validación esté exactamente como lo indica el output.

### CloudFront no responde

```bash
# Ver estado de la distribución
aws cloudfront get-distribution \
  --id $(terraform output -raw cloudfront_distribution_id) \
  --query 'Distribution.Status'
```

Debe estar en estado `Deployed`.

### ALB no responde

```bash
# Verificar target group
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn)
```

Las instancias deben estar `healthy`.

---

## 📞 Comandos Útiles

```bash
# Ver todos los outputs de Terraform
terraform output

# Ver certificados ACM
aws acm list-certificates --region us-east-1

# Ver distribuciones CloudFront
aws cloudfront list-distributions

# Ver load balancers
aws elbv2 describe-load-balancers

# Logs de CloudWatch (errores backend)
aws logs tail /aws/ec2/massnexus-prd --follow

# Invalidar cache de CloudFront (si es necesario)
aws cloudfront create-invalidation \
  --distribution-id $(terraform output -raw cloudfront_distribution_id) \
  --paths "/*"
```

---

## 📄 Documentación Completa

Ver archivo: `CONFIGURAR-CLOUDFLARE.md`

---

**Última actualización**: Esperando que Terraform termine...
