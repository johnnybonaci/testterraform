# Configuración de GitHub Actions - Guía Completa

Esta guía explica cómo configurar GitHub Actions para deployments automáticos del frontend (React) y backend (Laravel) usando OIDC de AWS.

## 📋 Prerequisitos

1. ✅ Infraestructura de Terraform desplegada (incluyendo GitHub OIDC roles)
2. ✅ Repositorios de GitHub:
   - Frontend: `beatsmedia/yieldpro_front_tmp`
   - Backend: `beatsmedia/yieldpro_back_tmp`
3. ✅ Permisos de admin en los repositorios

---

## 🔑 Paso 1: Obtener ARNs y valores desde Terraform

Después de desplegar la infraestructura con `terraform apply`, ejecutar:

```bash
cd environments/prod

# Obtener todos los outputs necesarios
terraform output
```

Copiar estos valores (los necesitarás para GitHub Secrets):

```bash
# Frontend
terraform output gh_front_role_arn
# Ejemplo: arn:aws:iam::123456789012:role/yp-test-gh-frontend-deploy

terraform output frontend_bucket
# Ejemplo: yp-test-frontend

terraform output cloudfront_distribution_id
# Ejemplo: E1ABCDEFGHIJK

terraform output cloudfront_domain
# Ejemplo: d111111abcdef8.cloudfront.net

# Backend
terraform output gh_backend_role_arn
# Ejemplo: arn:aws:iam::123456789012:role/yp-test-gh-backend-deploy

terraform output backend_artifacts_bucket
# Ejemplo: yp-test-backend-artifacts

terraform output codedeploy_app_name
# Ejemplo: yp-test-backend

terraform output codedeploy_deployment_group
# Ejemplo: yp-test-backend-dg

# ALB
terraform output alb_dns_name
# Ejemplo: yp-test-alb-123456789.us-east-1.elb.amazonaws.com
```

---

## 🔐 Paso 2: Configurar GitHub Secrets

### **Para el repositorio FRONTEND** (`beatsmedia/yieldpro_front_tmp`):

1. Ir a: https://github.com/beatsmedia/yieldpro_front_tmp/settings/secrets/actions
2. Click en "New repository secret"
3. Agregar los siguientes secrets:

| Secret Name | Valor | Descripción |
|-------------|-------|-------------|
| `AWS_ROLE_ARN_FRONTEND` | `arn:aws:iam::...:role/yp-test-gh-frontend-deploy` | ARN del rol IAM para frontend |
| `S3_BUCKET_FRONTEND` | `yp-test-frontend` | Nombre del bucket S3 |
| `CLOUDFRONT_DISTRIBUTION_ID` | `E1ABCDEFGHIJK` | ID de distribución CloudFront |
| `FRONTEND_DOMAIN` | `yieldpro.massnexus.com` | Dominio del frontend (opcional) |

**Opcional (si necesitas env vars en el build)**:
| `VITE_API_URL` | `https://api.yieldpro.com` | URL de tu API backend |

### **Para el repositorio BACKEND** (`beatsmedia/yieldpro_back_tmp`):

1. Ir a: https://github.com/beatsmedia/yieldpro_back_tmp/settings/secrets/actions
2. Agregar los siguientes secrets:

| Secret Name | Valor | Descripción |
|-------------|-------|-------------|
| `AWS_ROLE_ARN_BACKEND` | `arn:aws:iam::...:role/yp-test-gh-backend-deploy` | ARN del rol IAM para backend |
| `S3_BUCKET_ARTIFACTS` | `yp-test-backend-artifacts` | Bucket para artefactos |
| `CODEDEPLOY_APPLICATION` | `yp-test-backend` | Nombre de app CodeDeploy |
| `CODEDEPLOY_DEPLOYMENT_GROUP` | `yp-test-backend-dg` | Nombre del deployment group |

---

## 📁 Paso 3: Copiar workflows a los repositorios

### **Frontend**:

```bash
# En tu repo de frontend (yieldpro_front_tmp)
mkdir -p .github/workflows
cp /path/to/terraform-repo/.github/workflows/deploy-frontend-prod.yml \
   .github/workflows/

git add .github/
git commit -m "feat: Agregar workflow de deployment automático"
git push origin main
```

### **Backend**:

```bash
# En tu repo de backend (yieldpro_back_tmp)
mkdir -p .github/workflows
cp /path/to/terraform-repo/.github/workflows/deploy-backend-prod.yml \
   .github/workflows/

git add .github/
git commit -m "feat: Agregar workflow de deployment automático con CodeDeploy"
git push origin main
```

---

## ✅ Paso 4: Verificar configuración

### **Frontend**:

1. Ir a: https://github.com/beatsmedia/yieldpro_front_tmp/actions
2. Deberías ver el workflow "Deploy Frontend to Production"
3. Hacer un push a `main` o click en "Run workflow"
4. Verificar que:
   - ✅ OIDC authentication funciona
   - ✅ Build se completa
   - ✅ Archivos se suben a S3
   - ✅ CloudFront se invalida

### **Backend**:

1. Ir a: https://github.com/beatsmedia/yieldpro_back_tmp/actions
2. Deberías ver el workflow "Deploy Backend to Production"
3. Hacer un push a `main`
4. Verificar que:
   - ✅ OIDC authentication funciona
   - ✅ Composer install se completa
   - ✅ Assets se compilan
   - ✅ Bundle se sube a S3
   - ✅ CodeDeploy deployment se crea
   - ✅ Deployment se completa exitosamente

---

## 🔍 Troubleshooting

### Error: "Not authorized to perform sts:AssumeRoleWithWebIdentity"

**Causa**: El repositorio en GitHub no coincide con el configurado en Terraform

**Solución**:
1. Verificar en `environments/prod/main.tf` líneas 1243 y 1400:
   ```hcl
   # Frontend
   values = ["repo:beatsmedia/yieldpro_front_tmp:ref:refs/heads/main"]

   # Backend
   values = ["repo:beatsmedia/yieldpro_back_tmp:*"]
   ```

2. Si cambiaste el nombre del repo, actualizar Terraform:
   ```bash
   cd environments/prod
   # Editar variables.tf o main.tf según necesidad
   terraform apply
   ```

### Error: "Access Denied" al subir a S3

**Causa**: El rol IAM no tiene permisos correctos

**Solución**:
```bash
# Verificar outputs de Terraform
cd environments/prod
terraform output gh_front_role_arn
terraform output gh_backend_role_arn

# Verificar que los ARNs coinciden con los secrets en GitHub
```

### Error: CodeDeploy deployment falla

**Causa**: Scripts de deployment tienen errores o permisos incorrectos

**Solución**:
1. Ver logs en CodeDeploy Console:
   ```
   https://console.aws.amazon.com/codesuite/codedeploy/deployments/<deployment-id>
   ```

2. Conectar a EC2 via SSM:
   ```bash
   aws ssm start-session --target <instance-id> --region us-east-1

   # Ver logs de CodeDeploy
   sudo tail -f /var/log/aws/codedeploy-agent/codedeploy-agent.log

   # Ver logs de scripts
   sudo tail -f /opt/codedeploy-agent/deployment-root/deployment-logs/codedeploy-agent-deployments.log
   ```

### Error: Health check falla en ValidateService

**Causa**: El endpoint `/health` no responde 200

**Solución**:
1. Verificar que Laravel tiene ruta `/health`:
   ```php
   // routes/web.php
   Route::get('/health', function () {
       return response('ok', 200);
   });
   ```

2. O cambiar el health check en `validate_service.sh`:
   ```bash
   HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ || echo "000")
   ```

### Frontend: CloudFront no muestra cambios

**Causa**: Cache de CloudFront no se invalidó

**Solución**:
1. Verificar que la invalidación se creó:
   ```bash
   aws cloudfront list-invalidations \
     --distribution-id <DISTRIBUTION_ID> \
     --region us-east-1
   ```

2. Invalidar manualmente:
   ```bash
   aws cloudfront create-invalidation \
     --distribution-id <DISTRIBUTION_ID> \
     --paths "/*" \
     --region us-east-1
   ```

---

## 🎯 Workflows Avanzados (Opcional)

### Deploy solo en pull request merge

```yaml
# En deploy-frontend-prod.yml
on:
  pull_request:
    types: [closed]
    branches:
      - main

jobs:
  deploy:
    if: github.event.pull_request.merged == true
    # ... resto del workflow
```

### Deploy con aprobación manual

```yaml
# Agregar job de aprobación
jobs:
  approve:
    runs-on: ubuntu-latest
    environment:
      name: production
      # Esto requiere configurar "Environment" en GitHub settings
    steps:
      - run: echo "Aprobado"

  deploy:
    needs: approve
    # ... resto del deployment
```

### Notificaciones a Slack

```yaml
- name: Notify Slack on success
  if: success()
  uses: slackapi/slack-github-action@v1
  with:
    payload: |
      {
        "text": "✅ Deploy exitoso: ${{ github.sha }}"
      }
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK }}
```

---

## 📊 Métricas de Deployment

**Ver en GitHub Actions**:
- Build time
- Deployment duration
- Success rate

**Ver en AWS**:
- CodeDeploy: Deployment history
- CloudWatch: Application logs durante deployment
- ALB: Traffic patterns durante rolling update

---

## 🔒 Seguridad

**Best Practices implementadas**:
- ✅ OIDC (no access keys)
- ✅ Least privilege IAM roles
- ✅ Secrets en GitHub Secrets (no en código)
- ✅ Artifact signing (S3 versioning)
- ✅ Rollback automático en CodeDeploy si falla

**NO hacer**:
- ❌ Hardcodear credenciales AWS
- ❌ Commitear `.env` con secrets
- ❌ Dar permisos `*:*` a roles IAM
- ❌ Deployar a prod desde branches de feature

---

## 📝 Checklist de Setup

Frontend:
- [ ] Secrets configurados en GitHub
- [ ] Workflow copiado al repo
- [ ] Push a `main` triggerea deployment
- [ ] Build se completa exitosamente
- [ ] S3 sync funciona
- [ ] CloudFront invalidation funciona
- [ ] URL del frontend muestra la app

Backend:
- [ ] Secrets configurados en GitHub
- [ ] Workflow copiado al repo
- [ ] Push triggerea deployment
- [ ] Bundle se crea correctamente
- [ ] CodeDeploy deployment se crea
- [ ] Scripts de deployment se ejecutan
- [ ] Health check pasa
- [ ] ALB muestra instancias healthy
- [ ] Workers reinician correctamente

---

## 🆘 Soporte

**Logs útiles**:
- GitHub Actions: `https://github.com/<owner>/<repo>/actions`
- CodeDeploy: Console → CodeDeploy → Deployments
- CloudWatch: `/aws/ec2/yp-test/app`
- EC2 via SSM: `aws ssm start-session --target <instance-id>`

**Comandos de debugging**:
```bash
# Ver último deployment
aws deploy list-deployments \
  --application-name yp-test-backend \
  --deployment-group-name yp-test-backend-dg \
  --max-items 1

# Ver detalles de deployment
aws deploy get-deployment --deployment-id <deployment-id>

# Ver logs en instancia
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

---

**Última actualización**: 2025-01-19
**Mantenido por**: DevOps Team
