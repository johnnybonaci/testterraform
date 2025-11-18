# ⚡ Quick Start - Deploy en 5 Pasos

## 🎯 Objetivo

Configurar deployment automático para:
- **Frontend**: `beatsmedia/yieldpro_front_tmp` → https://uat.yieldpro.io
- **Backend**: `beatsmedia/yieldpro_back_tmp` → https://dev.yieldpro.io

---

## 📦 FRONTEND (React/Vite)

### 1. Copiar workflow al repo

```bash
cd /ruta/a/yieldpro_front_tmp
mkdir -p .github/workflows
cp /Users/johnnybonaci/Herd/terraform/workflows/frontend-deploy.yml .github/workflows/deploy.yml
```

### 2. Ajustar variables de build (si es necesario)

Edita `.github/workflows/deploy.yml` línea 34-35:

```yaml
env:
  VITE_API_URL: https://dev.yieldpro.io/api    # URL de tu backend
  VITE_APP_URL: https://uat.yieldpro.io        # URL de tu frontend
```

### 3. Commit y push

```bash
git add .github/workflows/deploy.yml
git commit -m "Add deployment workflow"
git push origin main
```

✅ **Listo!** Cada push a `main` deployrá automáticamente.

---

## 🚀 BACKEND (Laravel 12)

### 1. Copiar workflow al repo

```bash
cd /ruta/a/yieldpro_back_tmp
mkdir -p .github/workflows
cp /Users/johnnybonaci/Herd/terraform/workflows/backend-deploy.yml .github/workflows/deploy.yml
```

### 2. Configurar variables de entorno Laravel

Tu `.env` en el servidor ya está configurado por Terraform con:
- `APP_KEY`
- `DB_*` (host, database, user, password)
- `REDIS_HOST`

Si necesitas **variables adicionales**, hay 2 opciones:

#### Opción A: Agregar al SSM Parameter Store (recomendado)

```bash
# Ejemplo: agregar PUSHER_APP_KEY
aws ssm put-parameter \
  --name "/massnexus-prd/laravel/PUSHER_APP_KEY" \
  --value "tu-key-aqui" \
  --type "SecureString" \
  --region us-east-1
```

Luego actualizar el user_data en Terraform para que las lea.

#### Opción B: Usar GitHub Secrets

En GitHub → Settings → Secrets → Add:

```
APP_KEY = base64:...
PUSHER_APP_KEY = ...
```

Y modificar el workflow para generar `.env` completo.

### 3. ¿Quieres migraciones automáticas?

Por defecto están **deshabilitadas**. Para habilitarlas, edita `.github/workflows/deploy.yml` línea ~175:

```bash
# CAMBIAR ESTO:
# php artisan migrate --force

# A ESTO:
php artisan migrate --force
```

### 4. Commit y push

```bash
git add .github/workflows/deploy.yml
git commit -m "Add CodeDeploy workflow"
git push origin main
```

✅ **Listo!** Deployment iniciará automáticamente.

---

## 🔍 VERIFICAR QUE TODO FUNCIONA

### Verificar Instance Refresh (backend PHP 8.3)

```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name massnexus-prd-asg \
  --region us-east-1 \
  --query 'InstanceRefreshes[0].{Status:Status,Percent:PercentageComplete}'
```

Esperar hasta que `Status = "Successful"` y `Percent = 100`

### Test Frontend

```bash
curl -I https://uat.yieldpro.io
# Debe retornar: HTTP/2 200
```

### Test Backend

```bash
curl -I https://dev.yieldpro.io
# Debe retornar: HTTP/2 200 (o 302 si hay redirect)
```

---

## 📊 MONITOREAR DEPLOYMENTS

### GitHub Actions

Ve a tu repo → **Actions** tab

Verás:
- ✅ Workflows exitosos (verde)
- ❌ Workflows fallidos (rojo)
- 🔵 Workflows en progreso (azul)

### AWS CodeDeploy (solo backend)

```bash
# Listar últimos deployments
aws deploy list-deployments \
  --application-name massnexus-prd-backend \
  --max-items 5 \
  --region us-east-1

# Ver detalles
aws deploy get-deployment \
  --deployment-id d-XXXXXXXXX \
  --region us-east-1
```

O ve al console:
https://console.aws.amazon.com/codesuite/codedeploy/applications/massnexus-prd-backend

---

## 🐛 TROUBLESHOOTING RÁPIDO

### Frontend no deploya

1. **Verificar workflow está activo**:
   - GitHub repo → Actions → Debe aparecer el workflow

2. **Error de permisos**:
   - Verificar que el role ARN es correcto en el workflow

3. **CloudFront no actualiza**:
   - Esperar 5-10 minutos para invalidación
   - O forzar: `Ctrl + Shift + R` en el navegador

### Backend falla en deployment

1. **Ver logs de GitHub Actions**:
   ```
   GitHub repo → Actions → Click en el workflow fallido
   ```

2. **Ver logs en la instancia EC2**:
   ```bash
   # Conectarse
   aws ssm start-session --target <instance-id> --region us-east-1

   # Logs de deployment
   sudo tail -100 /var/log/aws/codedeploy-agent/codedeploy-agent.log

   # Logs de Laravel
   sudo tail -100 /var/www/app/storage/logs/laravel.log
   ```

3. **Script falla**:
   Los scripts están en el workflow. Puedes ejecutarlos manualmente en la instancia para debug.

### Backend retorna 500

```bash
# Conectarse a la instancia
aws ssm start-session --target <instance-id> --region us-east-1

# Ver logs
sudo tail -f /var/www/app/storage/logs/laravel.log

# Verificar PHP
php -v
# Debe mostrar: PHP 8.3.x

# Verificar permisos
ls -la /var/www/app/storage
# Debe ser: www-data:www-data

# Verificar .env
cat /var/www/app/.env
# Debe tener todas las variables
```

---

## 📋 CHECKLIST POST-DEPLOYMENT

### Frontend ✅

- [ ] Workflow copiado y pusheado
- [ ] GitHub Actions ejecutó exitosamente
- [ ] `https://uat.yieldpro.io` carga
- [ ] Archivos en S3: `aws s3 ls s3://massnexus-prd-frontend/`
- [ ] CloudFront cache invalidado

### Backend ✅

- [ ] Workflow copiado y pusheado
- [ ] GitHub Actions completó build
- [ ] CodeDeploy deployment exitoso
- [ ] Instance refresh completado (PHP 8.3)
- [ ] Target group healthy
- [ ] `https://dev.yieldpro.io` retorna 200
- [ ] Logs de Laravel sin errores

---

## 🎓 NEXT STEPS

1. **Configurar staging/develop**:
   - Duplicar workflows
   - Cambiar branch de `main` a `develop`
   - Apuntar a diferentes dominios

2. **Add tests automáticos**:
   ```yaml
   - name: Run tests
     run: |
       php artisan test
       npm run test
   ```

3. **Add rollback automático**:
   ```yaml
   - name: Rollback on failure
     if: failure()
     run: |
       aws deploy stop-deployment --deployment-id ${{ env.DEPLOYMENT_ID }}
   ```

4. **Notificaciones**:
   - Slack
   - Email
   - Discord

---

## 🔗 ARCHIVOS CREADOS

Todos los archivos están en: `/Users/johnnybonaci/Herd/terraform/workflows/`

```
workflows/
├── frontend-deploy.yml        # Workflow para React
├── backend-deploy.yml         # Workflow para Laravel
├── INSTALLATION-GUIDE.md      # Guía detallada
└── QUICK-START.md            # Esta guía (inicio rápido)
```

---

## 💡 TIPS

1. **Deploy manual**: Ve a GitHub Actions → Workflow → "Run workflow"
2. **Ver archivos deployados**:
   - Frontend: `aws s3 ls s3://massnexus-prd-frontend/ --recursive`
   - Backend: Conéctate a EC2 y `ls -la /var/www/app`
3. **Rollback rápido**:
   - Frontend: Re-run workflow anterior
   - Backend: Redeploy desde CodeDeploy console

---

¿Listo para deployar? 🚀

```bash
git push origin main
```

Y observa la magia en GitHub Actions! ✨
