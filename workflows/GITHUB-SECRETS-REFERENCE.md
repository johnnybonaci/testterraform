# GitHub Secrets - Referencia Rápida

Esta guía de referencia rápida muestra EXACTAMENTE qué secrets necesitas configurar en cada repositorio.

## 📦 Repositorio Frontend: `beatsmedia/yieldpro_front_tmp`

**URL de configuración**: https://github.com/beatsmedia/yieldpro_front_tmp/settings/secrets/actions

### Secrets Requeridos

| Secret Name                  | ¿Dónde obtenerlo?                             | Ejemplo                                                     |
| ---------------------------- | --------------------------------------------- | ----------------------------------------------------------- |
| `AWS_ROLE_ARN_FRONTEND`      | `terraform output gh_front_role_arn`          | `arn:aws:iam::123456789012:role/yp-test-gh-frontend-deploy` |
| `S3_BUCKET_FRONTEND`         | `terraform output frontend_bucket`            | `yp-test-frontend`                                          |
| `CLOUDFRONT_DISTRIBUTION_ID` | `terraform output cloudfront_distribution_id` | `E1ABCDEFGHIJK`                                             |
| `FRONTEND_DOMAIN`            | Tu dominio custom (opcional)                  | `yieldpro.massnexus.com`                                    |

### Secrets Opcionales (Build-time ENV vars)

| Secret Name     | Propósito           | Ejemplo                    |
| --------------- | ------------------- | -------------------------- |
| `VITE_API_URL`  | URL del backend API | `https://api.yieldpro.com` |
| `VITE_APP_NAME` | Nombre de la app    | `YieldPro`                 |

---

## 🔧 Repositorio Backend: `beatsmedia/yieldpro_back_tmp`

**URL de configuración**: https://github.com/beatsmedia/yieldpro_back_tmp/settings/secrets/actions

### Secrets Requeridos

| Secret Name                   | ¿Dónde obtenerlo?                              | Ejemplo                                                    |
| ----------------------------- | ---------------------------------------------- | ---------------------------------------------------------- |
| `AWS_ROLE_ARN_BACKEND`        | `terraform output gh_backend_role_arn`         | `arn:aws:iam::123456789012:role/yp-test-gh-backend-deploy` |
| `S3_BUCKET_ARTIFACTS`         | `terraform output backend_artifacts_bucket`    | `yp-test-backend-artifacts`                                |
| `CODEDEPLOY_APPLICATION`      | `terraform output codedeploy_app_name`         | `yp-test-backend`                                          |
| `CODEDEPLOY_DEPLOYMENT_GROUP` | `terraform output codedeploy_deployment_group` | `yp-test-backend-dg`                                       |

---

## 📋 Comandos para Obtener Valores

Ejecutar desde `environments/prod/`:

```bash
cd environments/prod

# Ver TODOS los outputs de una vez
terraform output -json | jq

# O individualmente:
terraform output gh_front_role_arn
terraform output frontend_bucket
terraform output cloudfront_distribution_id
terraform output gh_backend_role_arn
terraform output backend_artifacts_bucket
terraform output codedeploy_app_name
terraform output codedeploy_deployment_group
```

---

## ✅ Checklist de Configuración

### Frontend (`yieldpro_front_tmp`)

```bash
# 1. Ir a Settings > Secrets and variables > Actions
# 2. Click "New repository secret"
# 3. Agregar cada secret:

[ ] AWS_ROLE_ARN_FRONTEND
[ ] S3_BUCKET_FRONTEND
[ ] CLOUDFRONT_DISTRIBUTION_ID
[ ] FRONTEND_DOMAIN (opcional)
[ ] VITE_API_URL (opcional)

# 4. Verificar que todos aparezcan en la lista
# 5. ✅ Frontend secrets configurados
```

### Backend (`yieldpro_back_tmp`)

```bash
# 1. Ir a Settings > Secrets and variables > Actions
# 2. Click "New repository secret"
# 3. Agregar cada secret:

[ ] AWS_ROLE_ARN_BACKEND
[ ] S3_BUCKET_ARTIFACTS
[ ] CODEDEPLOY_APPLICATION
[ ] CODEDEPLOY_DEPLOYMENT_GROUP

# 4. Verificar que todos aparezcan en la lista
# 5. ✅ Backend secrets configurados
```

---

## 🔐 Ejemplo de Configuración Completa

### Frontend

```
AWS_ROLE_ARN_FRONTEND = arn:aws:iam::838108223027:role/yp-test-gh-frontend-deploy
S3_BUCKET_FRONTEND = yp-test-frontend
CLOUDFRONT_DISTRIBUTION_ID = E2ABCDEF123456
FRONTEND_DOMAIN = yieldpro.massnexus.com
VITE_API_URL = https://ypback.massnexus.com
```

### Backend

```
AWS_ROLE_ARN_BACKEND = arn:aws:iam::838108223027:role/yp-test-gh-backend-deploy
S3_BUCKET_ARTIFACTS = yp-test-backend-artifacts
CODEDEPLOY_APPLICATION = yp-test-backend
CODEDEPLOY_DEPLOYMENT_GROUP = yp-test-backend-dg
```

---

## 🚨 Errores Comunes

### ❌ "Secret not found"

**Causa**: Secret no está configurado o tiene typo en el nombre

**Solución**:

1. Verificar que el nombre sea EXACTO (case-sensitive)
2. Verificar en: https://github.com/<owner>/<repo>/settings/secrets/actions

### ❌ "Invalid ARN format"

**Causa**: Copiaste el ARN incorrecto

**Solución**:

```bash
# El ARN debe tener este formato:
arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME

# Verificar con:
terraform output gh_front_role_arn
```

### ❌ Workflow no encuentra el secret

**Causa**: Secret configurado en el repo incorrecto

**Solución**:

- Frontend secrets → `yieldpro_front_tmp` repo
- Backend secrets → `yieldpro_back_tmp` repo
- NO en el repo de Terraform

---

## 📝 Template para Copiar/Pegar

### Frontend (copiar valores reales)

```bash
AWS_ROLE_ARN_FRONTEND=
S3_BUCKET_FRONTEND=
CLOUDFRONT_DISTRIBUTION_ID=
FRONTEND_DOMAIN=
```

### Backend (copiar valores reales)

```bash
AWS_ROLE_ARN_BACKEND=
S3_BUCKET_ARTIFACTS=
CODEDEPLOY_APPLICATION=
CODEDEPLOY_DEPLOYMENT_GROUP=
```

---

**Nota**: Estos secrets se usan en los workflows de GitHub Actions. Si cambias nombres en Terraform, debes actualizar los secrets en GitHub.
