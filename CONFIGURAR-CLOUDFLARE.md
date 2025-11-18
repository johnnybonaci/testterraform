# 🌐 Configurar DNS en Cloudflare para yieldpro.io

## 📌 Resumen

Configurar los siguientes dominios:
- **Frontend**: `uat.yieldpro.io` → CloudFront
- **Backend**: `dev.yieldpro.io` → Application Load Balancer (ALB)

---

## ✅ PASO 1: Registros CNAME Principales

### Frontend (React app)

En tu panel de Cloudflare → DNS → Records:

```
Type:    CNAME
Name:    uat
Target:  dwtt8ee6z8sy3.cloudfront.net
TTL:     Auto
Proxy:   DNS only (nube gris ☁️)
```

**IMPORTANTE:**
- ⚠️ **Desactiva el proxy de Cloudflare** (nube gris, NO naranja)
- CloudFront ya tiene su propio CDN y WAF
- Si dejas el proxy activo, tendrás doble CDN y problemas

### Backend (Laravel API)

```
Type:    CNAME
Name:    dev
Target:  massnexus-prd-alb-1228840083.us-east-1.elb.amazonaws.com
TTL:     Auto
Proxy:   DNS only (nube gris ☁️)
```

**IMPORTANTE:**
- ⚠️ También en modo DNS only (nube gris)
- Si activas proxy, el WAF de CloudFront no funcionará correctamente

---

## ✅ PASO 2: Validación de Certificados SSL (ACM)

Una vez que Terraform termine de aplicar los cambios, ejecuta:

```bash
cd /Users/johnnybonaci/Herd/terraform/environments/prod
terraform output frontend_cert_validation_records
terraform output backend_cert_validation_records
```

Esto te dará los registros CNAME que necesitas agregar en Cloudflare.

**Ejemplo de output:**

```json
[
  {
    "name"  = "_abc123456.uat.yieldpro.io.",
    "type"  = "CNAME",
    "value" = "_xyz789.xlfgrmvvlj.acm-validations.aws."
  }
]
```

Agrega estos registros en Cloudflare:

```
Type:    CNAME
Name:    _abc123456.uat   (copia el name del output, sin el dominio)
Target:  _xyz789.xlfgrmvvlj.acm-validations.aws.  (el value completo)
TTL:     Auto
Proxy:   DNS only (nube gris)
```

Repite lo mismo para `dev.yieldpro.io`.

---

## ⏱️ PASO 3: Esperar Validación

### Tiempo estimado: 5-30 minutos

AWS validará que los registros DNS están correctos. Puedes verificar el progreso:

```bash
# Ver estado del certificado frontend
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw frontend_cert_arn) \
  --region us-east-1 \
  --query 'Certificate.Status'

# Ver estado del certificado backend
aws acm describe-certificate \
  --certificate-arn $(terraform output -raw backend_cert_arn) \
  --region us-east-1 \
  --query 'Certificate.Status'
```

**Estados posibles:**
- `PENDING_VALIDATION`: Aún esperando
- `ISSUED`: ✅ Listo para usar

---

## ✅ PASO 4: Verificar que Funciona

### Test Frontend

```bash
# DNS debe resolver a CloudFront
dig uat.yieldpro.io

# Debe responder con HTTPS
curl -I https://uat.yieldpro.io
```

**Debe retornar:**
```
HTTP/2 200
content-type: text/html
x-cache: Miss from cloudfront  (o Hit from cloudfront)
```

### Test Backend

```bash
# DNS debe resolver al ALB
dig dev.yieldpro.io

# Debe responder con HTTPS
curl -I https://dev.yieldpro.io
```

**Debe retornar:**
```
HTTP/1.1 200 OK
server: nginx/1.26.2 (o similar)
```

---

## 🔧 Troubleshooting

### Error: "This site can't provide a secure connection"

**Problema:** El certificado SSL aún no está validado o configurado.

**Solución:**
1. Verificar que agregaste los registros CNAME de validación
2. Esperar 5-30 minutos
3. Verificar estado con `aws acm describe-certificate`

### Error: "ERR_TOO_MANY_REDIRECTS"

**Problema:** El proxy de Cloudflare está activo (nube naranja).

**Solución:**
1. Ir a Cloudflare DNS
2. Hacer click en el registro CNAME
3. Cambiar "Proxy status" a "DNS only" (nube gris)

### Error: "Name or service not known"

**Problema:** El registro DNS aún no se propagó.

**Solución:**
1. Esperar 1-5 minutos
2. Verificar que el registro CNAME está correctamente configurado en Cloudflare
3. Probar con `dig uat.yieldpro.io` o `nslookup uat.yieldpro.io`

### Certificado no valida después de 30 minutos

**Problema:** El registro CNAME de validación no está correctamente configurado.

**Solución:**
1. Verificar el output de Terraform:
   ```bash
   terraform output frontend_cert_validation_records
   ```
2. Comparar con los registros en Cloudflare
3. Asegurarse de que el `name` y `value` son exactamente iguales
4. Eliminar y re-crear el registro si es necesario

---

## 📊 Checklist de Configuración

- [ ] Registro CNAME para `uat.yieldpro.io` creado
- [ ] Registro CNAME para `dev.yieldpro.io` creado
- [ ] Ambos registros en modo "DNS only" (nube gris)
- [ ] Registros de validación ACM agregados (2 registros)
- [ ] Esperado 5-30 minutos para validación
- [ ] Certificados en estado `ISSUED`
- [ ] `curl https://uat.yieldpro.io` retorna 200 OK
- [ ] `curl https://dev.yieldpro.io` retorna 200 OK

---

## 🎯 URLs Finales

Una vez configurado todo:

- **Frontend (React)**: https://uat.yieldpro.io
- **Backend (Laravel API)**: https://dev.yieldpro.io

**Actualizar en tus aplicaciones:**

Frontend (`.env` o config):
```env
VITE_API_URL=https://dev.yieldpro.io/api
VITE_APP_URL=https://uat.yieldpro.io
```

Backend (`.env` Laravel):
```env
APP_URL=https://dev.yieldpro.io
FRONTEND_URL=https://uat.yieldpro.io
SESSION_DOMAIN=.yieldpro.io
SANCTUM_STATEFUL_DOMAINS=uat.yieldpro.io
```

---

## ⚠️ IMPORTANTE: Cloudflare SSL/TLS Mode

En Cloudflare → SSL/TLS → Overview:

**Configuración recomendada:**
```
SSL/TLS encryption mode: Full (strict)
```

**NO usar:**
- ❌ Off
- ❌ Flexible (causará loops de redirección)

---

## 🔗 Recursos Adicionales

- [AWS ACM Validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html)
- [Cloudflare DNS Records](https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/)
- [CloudFront Custom Domains](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/CNAMEs.html)

---

**¿Necesitas ayuda?** Verifica los logs:

```bash
# CloudFront logs
aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items[?contains(@, 'uat.yieldpro.io')]].Id"

# ALB access logs (si están configurados)
aws s3 ls s3://massnexus-prd-logs/alb/
```
