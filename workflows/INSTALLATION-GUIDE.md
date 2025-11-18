# 🚀 Guía de Instalación - GitHub Actions Workflows

## 📋 Requisitos Previos

1. Repositorios creados:
   - Frontend: `https://github.com/beatsmedia/yieldpro_front_tmp`
   - Backend: `https://github.com/beatsmedia/yieldpro_back_tmp`

2. Infraestructura AWS deployada (ya está ✅)

---

## 1️⃣ FRONTEND: `beatsmedia/yieldpro_front_tmp`

### Paso 1: Crear estructura de directorios

En tu repositorio frontend:

```bash
mkdir -p .github/workflows
```

### Paso 2: Copiar workflow

Copiar el archivo `frontend-deploy.yml` a `.github/workflows/deploy.yml`:

```bash
cp /Users/johnnybonaci/Herd/terraform/workflows/frontend-deploy.yml .github/workflows/deploy.yml
```

### Paso 3: Configurar variables de entorno (opcional)

Si quieres usar variables de entorno en vez de hardcodear:

**Settings → Secrets and variables → Actions → Variables**

```
AWS_REGION = us-east-1
S3_BUCKET = massnexus-prd-frontend
CLOUDFRONT_DISTRIBUTION_ID = EY24XDWI68SLJ
```

### Paso 4: Commit y Push

```bash
git add .github/workflows/deploy.yml
git commit -m "Add GitHub Actions deployment workflow"
git push origin main
```

### Paso 5: Verificar

1. Ve a tu repo en GitHub
2. Click en **Actions**
3. Deberías ver el workflow corriendo automáticamente

---

## 2️⃣ BACKEND: `beatsmedia/yieldpro_back_tmp`

### Paso 1: Crear estructura de directorios

En tu repositorio backend Laravel:

```bash
mkdir -p .github/workflows
```

### Paso 2: Copiar workflow

```bash
cp /Users/johnnybonaci/Herd/terraform/workflows/backend-deploy.yml .github/workflows/deploy.yml
```

### Paso 3: Ajustar el workflow (IMPORTANTE)

Edita `.github/workflows/deploy.yml` y verifica/ajusta:

#### **Variables de entorno de Laravel**

En el step "Create deployment package", asegúrate de que el `.env` se genera correctamente. Por defecto, el workflow espera que el `.env` ya exista en el servidor (generado por el user_data de Terraform).

Si necesitas variables adicionales, agrégalas como **Secrets** en GitHub:

**Settings → Secrets and variables → Actions → Secrets**

```
# Ejemplo de secrets adicionales
APP_KEY = base64:...
PUSHER_APP_KEY = ...
AWS_ACCESS_KEY_ID = ... (si usas S3 para storage)
```

Y úsalas en el workflow:

```yaml
- name: Create .env file
  run: |
    cat > deploy/.env << EOF
    APP_ENV=production
    APP_DEBUG=false
    APP_KEY=${{ secrets.APP_KEY }}
    # ... más variables
    EOF
```

#### **Migraciones automáticas**

Por defecto, las migraciones están **comentadas**. Si quieres que se ejecuten automáticamente, descomenta esta línea en `scripts/after_install.sh`:

```bash
# Descomentar esta línea:
# php artisan migrate --force

# Para:
php artisan migrate --force
```

### Paso 4: Commit y Push

```bash
git add .github/workflows/deploy.yml
git commit -m "Add CodeDeploy workflow for Laravel"
git push origin main
```

### Paso 5: Verificar

1. Ve a tu repo en GitHub → **Actions**
2. El workflow debería iniciar automáticamente
3. Monitorea el deployment en AWS Console:
   - CodeDeploy: https://console.aws.amazon.com/codesuite/codedeploy/deployments

---

## 🔍 TROUBLESHOOTING

### Frontend no deploya

**Error común**: `AccessDenied` al subir a S3

**Solución**: Verifica que el role ARN es correcto:
```yaml
role-to-assume: arn:aws:iam::838108223027:role/massnexus-prd-gh-frontend-deploy
```

### Backend deployment falla

**Error**: `CodeDeploy agent not responding`

**Solución**: Verificar que el CodeDeploy agent está corriendo en la instancia EC2:

```bash
# Conectarse a la instancia
aws ssm start-session --target i-XXXXXXXX --region us-east-1

# Verificar CodeDeploy agent
sudo systemctl status codedeploy-agent
```

**Error**: `Scripts failed with error code 1`

**Solución**: Ver logs en la instancia:
```bash
sudo tail -f /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

### Scripts de deployment fallan

Los scripts están en `/opt/codedeploy-agent/deployment-root/[deployment-id]/deployment-archive/scripts/`

Puedes ejecutarlos manualmente para debug:
```bash
sudo bash /opt/codedeploy-agent/deployment-root/.../scripts/after_install.sh
```

---

## 📊 Verificar Deployments

### Frontend

```bash
# Verificar archivos en S3
aws s3 ls s3://massnexus-prd-frontend/ --recursive --region us-east-1

# Invalidación de CloudFront
aws cloudfront list-invalidations \
  --distribution-id EY24XDWI68SLJ \
  --region us-east-1

# Test URL
curl -I https://uat.yieldpro.io
```

### Backend

```bash
# Ver deployments
aws deploy list-deployments \
  --application-name massnexus-prd-backend \
  --region us-east-1

# Ver detalles de un deployment
aws deploy get-deployment \
  --deployment-id d-XXXXXXXXX \
  --region us-east-1

# Test URL
curl -I https://dev.yieldpro.io
```

---

## 🎯 OPTIMIZACIONES OPCIONALES

### 1. Deploy solo en Pull Request merge

```yaml
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

### 2. Deploy manual con inputs

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment to deploy'
        required: true
        default: 'production'
        type: choice
        options:
          - production
          - staging
```

### 3. Notificaciones de Slack

```yaml
- name: Notify Slack
  if: always()
  uses: slackapi/slack-github-action@v1
  with:
    webhook-url: ${{ secrets.SLACK_WEBHOOK }}
    payload: |
      {
        "text": "Deployment ${{ job.status }}: ${{ github.repository }}"
      }
```

---

## 📝 Checklist Final

### Frontend ✅

- [ ] Workflow copiado a `.github/workflows/deploy.yml`
- [ ] Variables configuradas (opcional)
- [ ] Push a `main` activa el deployment
- [ ] Deployment exitoso en Actions
- [ ] CloudFront invalidation ejecutada
- [ ] `https://uat.yieldpro.io` retorna 200

### Backend ✅

- [ ] Workflow copiado a `.github/workflows/deploy.yml`
- [ ] Scripts de deployment revisados
- [ ] Migraciones configuradas (comentadas/descomentadas)
- [ ] Push a `main` activa el deployment
- [ ] CodeDeploy deployment exitoso
- [ ] Instancia EC2 healthy en target group
- [ ] `https://dev.yieldpro.io` retorna 200 (no 500)

---

## 🆘 Soporte

Si tienes problemas:

1. **Ver logs de GitHub Actions**: Tab "Actions" en el repo
2. **Ver logs de CodeDeploy**: AWS Console → CodeDeploy → Deployments
3. **Ver logs en EC2**:
   ```bash
   # Conectarse
   aws ssm start-session --target <instance-id> --region us-east-1

   # Logs de CodeDeploy
   sudo tail -f /var/log/aws/codedeploy-agent/codedeploy-agent.log

   # Logs de aplicación
   sudo tail -f /var/www/app/storage/logs/laravel.log

   # Logs de Nginx
   sudo tail -f /var/log/nginx/error.log

   # Logs de PHP-FPM
   sudo journalctl -u php8.3-fpm -f
   ```

---

## 🔗 URLs Importantes

- **Frontend**: https://uat.yieldpro.io
- **Backend**: https://dev.yieldpro.io
- **CloudFront Console**: https://console.aws.amazon.com/cloudfront/v4/home?region=us-east-1#/distributions/EY24XDWI68SLJ
- **CodeDeploy Console**: https://console.aws.amazon.com/codesuite/codedeploy/applications/massnexus-prd-backend
- **S3 Frontend**: https://s3.console.aws.amazon.com/s3/buckets/massnexus-prd-frontend
- **S3 Backend**: https://s3.console.aws.amazon.com/s3/buckets/massnexus-prd-backend-artifacts
