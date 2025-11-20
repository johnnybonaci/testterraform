# Configuración de GitHub Secrets - Frontend

## 📍 Ubicación

Configurar en: https://github.com/beatsmedia/yieldpro_front_tmp/settings/secrets/actions

## 🔐 Secrets Requeridos

### AWS & Infraestructura (Obligatorios)

```bash
AWS_ROLE_ARN_FRONTEND = arn:aws:iam::838108223027:role/yp-test-gh-frontend-deploy
S3_BUCKET_FRONTEND = yp-test-frontend
CLOUDFRONT_DISTRIBUTION_ID = E3R8174SB6XCL7
FRONTEND_DOMAIN = uat.yieldpro.io
```

### Variables de Aplicación (Obligatorios)

```bash
VITE_API_URL = https://dev.yieldpro.io/api
VITE_APP_URL = https://uat.yieldpro.io
```

### Variables Adicionales (Opcionales - según tu aplicación)

```bash
VITE_OLD_SITE_URL = <tu_valor>
VITE_MS_AUTH_API_URL = <tu_valor>
VITE_APP_TIMEZONE = <tu_valor>
VITE_URL = <tu_valor>
VITE_API_TOKEN_YP = <tu_valor_secreto>
VITE_DATE_MANAGER_TEST = <tu_valor>
VITE_PROVIDER = <tu_valor>
VITE_XSRF_COOKIE_NAME = <tu_valor>
VITE_SESSION = <tu_valor>
VITE_MAINTENANCE_MODE1 = <tu_valor>
```

## 📝 Cómo Configurar

1. Ve a: https://github.com/beatsmedia/yieldpro_front_tmp/settings/secrets/actions
2. Click en **"New repository secret"**
3. Para cada secret:
   - Name: (nombre exacto de arriba)
   - Value: (tu valor)
   - Click **"Add secret"**

## ✅ Checklist

```
Infraestructura:
[ ] AWS_ROLE_ARN_FRONTEND
[ ] S3_BUCKET_FRONTEND
[ ] CLOUDFRONT_DISTRIBUTION_ID
[ ] FRONTEND_DOMAIN

URLs Principales:
[ ] VITE_API_URL
[ ] VITE_APP_URL

Variables Opcionales (agregar solo si tu app las usa):
[ ] VITE_OLD_SITE_URL
[ ] VITE_MS_AUTH_API_URL
[ ] VITE_APP_TIMEZONE
[ ] VITE_URL
[ ] VITE_API_TOKEN_YP
[ ] VITE_DATE_MANAGER_TEST
[ ] VITE_PROVIDER
[ ] VITE_XSRF_COOKIE_NAME
[ ] VITE_SESSION
[ ] VITE_MAINTENANCE_MODE1
```

## 🔍 Verificación

Una vez configurados todos los secrets, puedes verificarlos en:
https://github.com/beatsmedia/yieldpro_front_tmp/settings/secrets/actions

Deberías ver todos los secrets listados (sin poder ver sus valores por seguridad).

## 🚀 Probar el Workflow

Después de configurar los secrets:

1. **Método 1 - Push a main:**

   ```bash
   git push origin main
   ```

2. **Método 2 - Manual dispatch:**
   - Ve a: https://github.com/beatsmedia/yieldpro_front_tmp/actions
   - Selecciona "Deploy Frontend to Production"
   - Click "Run workflow"
   - Selecciona branch "main"
   - Click "Run workflow"

## ⚠️ Notas Importantes

- Los valores mostrados arriba son **ejemplos** basados en tu infraestructura actual
- Las variables `VITE_*` se inyectan **durante el build** (no en runtime)
- Si una variable VITE\_ no existe en los secrets, el build usará `undefined`
- Los secrets son **case-sensitive** (deben coincidir exactamente)
- Solo configura las variables VITE\_ que tu aplicación realmente usa

## 🆘 Troubleshooting

### Error: "Secret not found"

- Verifica que el nombre del secret sea **exacto** (case-sensitive)
- Asegúrate de estar en el repo correcto: `yieldpro_front_tmp`

### Error: "Unable to assume role"

- Verifica que `AWS_ROLE_ARN_FRONTEND` tenga el formato correcto
- Confirma que el role existe en tu cuenta AWS

### Build falla con variables undefined

- Verifica que todos los `VITE_*` necesarios estén configurados
- Revisa los logs del build para ver qué variable falta
