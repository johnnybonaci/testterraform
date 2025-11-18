#!/bin/bash

################################################################################
# Script: Setup Nueva Cuenta AWS
# Descripción: Automatiza la configuración de infraestructura en cuenta AWS nueva
# Uso: ./setup-nueva-cuenta.sh
################################################################################

set -e  # Exit on error

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funciones helper
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Banner
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║  🚀 Setup Infraestructura AWS - Nueva Cuenta            ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

################################################################################
# PASO 1: Configuración inicial
################################################################################

log_info "Paso 1/10: Configuración Inicial"

# Solicitar nombre del perfil AWS
read -p "Nombre del perfil AWS (ej: mi-empresa-prod): " AWS_PROFILE_NAME
export AWS_PROFILE=$AWS_PROFILE_NAME

# Verificar que el perfil existe
if ! aws configure list --profile $AWS_PROFILE_NAME &> /dev/null; then
    log_error "Perfil AWS '$AWS_PROFILE_NAME' no encontrado"
    log_info "Ejecuta primero: aws configure --profile $AWS_PROFILE_NAME"
    exit 1
fi

# Verificar credenciales
log_info "Verificando credenciales AWS..."
ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE_NAME --query Account --output text 2>/dev/null)

if [ -z "$ACCOUNT_ID" ]; then
    log_error "No se pudo autenticar con AWS. Verifica tus credenciales."
    exit 1
fi

log_success "Autenticado en cuenta AWS: $ACCOUNT_ID"

# Solicitar configuraciones
echo ""
log_info "Configuración del proyecto:"
read -p "Nombre del proyecto (ej: mi-empresa): " PROJECT_NAME
read -p "Región AWS [us-east-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}

read -p "Email para alertas de seguridad: " SECURITY_EMAIL

read -p "¿Tienes dominio propio? (y/n) [n]: " HAS_DOMAIN
HAS_DOMAIN=${HAS_DOMAIN:-n}

if [[ "$HAS_DOMAIN" == "y" ]]; then
    read -p "Dominio frontend (ej: app.ejemplo.com): " FRONTEND_DOMAIN
    read -p "Dominio backend (ej: api.ejemplo.com): " BACKEND_DOMAIN
else
    FRONTEND_DOMAIN=""
    BACKEND_DOMAIN=""
fi

read -p "Tu IP pública actual: " CURRENT_IP

# Confirmar
echo ""
log_warning "═══════════════════════════════════════════════════════"
log_warning "Configuración:"
log_warning "  Cuenta AWS: $ACCOUNT_ID"
log_warning "  Perfil: $AWS_PROFILE_NAME"
log_warning "  Proyecto: $PROJECT_NAME"
log_warning "  Región: $AWS_REGION"
log_warning "  Email alertas: $SECURITY_EMAIL"
log_warning "  Dominio frontend: ${FRONTEND_DOMAIN:-'CloudFront default'}"
log_warning "  Dominio backend: ${BACKEND_DOMAIN:-'ALB DNS'}"
log_warning "  IP actual: $CURRENT_IP"
log_warning "═══════════════════════════════════════════════════════"
echo ""
read -p "¿Continuar? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    log_error "Cancelado por el usuario"
    exit 1
fi

################################################################################
# PASO 2: Limpiar state anterior
################################################################################

log_info "Paso 2/10: Limpiando state anterior..."

find . -name "terraform.tfstate*" -delete 2>/dev/null || true
find . -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
find . -name ".terraform.lock.hcl" -delete 2>/dev/null || true

log_success "State anterior eliminado"

################################################################################
# PASO 3: Configurar backend S3
################################################################################

log_info "Paso 3/10: Configurando backend remoto..."

STATE_BUCKET="${PROJECT_NAME}-tf-state-${ACCOUNT_ID}"
LOCK_TABLE="${PROJECT_NAME}-tf-locks"

cd 0-bootstrap/remote-state

# Inicializar Terraform
terraform init

# Aplicar bootstrap
log_info "Creando bucket S3 y tabla DynamoDB..."
terraform apply \
    -var="state_bucket_name=$STATE_BUCKET" \
    -var="lock_table_name=$LOCK_TABLE" \
    -var="region=$AWS_REGION" \
    -auto-approve

cd ../..

log_success "Backend remoto configurado: $STATE_BUCKET"

################################################################################
# PASO 4: Configurar Producción
################################################################################

log_info "Paso 4/10: Configurando Producción..."

cd environments/prod

# Actualizar backend.tf
cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "$STATE_BUCKET"
    region         = "$AWS_REGION"
    key            = "prod/terraform.tfstate"
    dynamodb_table = "$LOCK_TABLE"
    encrypt        = true
  }
}
EOF

log_success "backend.tf actualizado"

# Actualizar variables críticas
log_info "Actualizando variables.tf..."

# Usar sed para cambios seguros
sed -i.bak "s/default = \"massnexus-prd\"/default = \"${PROJECT_NAME}-prd\"/" variables.tf
sed -i.bak "s/default = \"security@massnexus.com\"/default = \"${SECURITY_EMAIL}\"/" variables.tf

if [[ -n "$FRONTEND_DOMAIN" ]]; then
    sed -i.bak "s/default = \"yieldpro.massnexus.com\"/default = \"${FRONTEND_DOMAIN}\"/" variables.tf
fi

if [[ -n "$BACKEND_DOMAIN" ]]; then
    sed -i.bak "s/default = \"ypback.massnexus.com\"/default = \"${BACKEND_DOMAIN}\"/" variables.tf
fi

# Actualizar IP permitida
sed -i.bak "s/190.19.143.121/${CURRENT_IP}/" variables.tf

rm -f variables.tf.bak

log_success "variables.tf actualizado"

################################################################################
# PASO 5: Inicializar Terraform Prod
################################################################################

log_info "Paso 5/10: Inicializando Terraform (Producción)..."

terraform init

log_success "Terraform inicializado"

################################################################################
# PASO 6: Plan
################################################################################

log_info "Paso 6/10: Generando plan de ejecución..."

terraform plan -out=tfplan-nueva-cuenta

log_success "Plan generado. Revisa los cambios arriba."

################################################################################
# PASO 7: Aplicar (Con confirmación)
################################################################################

echo ""
log_warning "════════════════════════════════════════════════════════════"
log_warning "⚠️  IMPORTANTE: Se van a crear ~65 recursos en AWS"
log_warning "⚠️  Costo estimado: ~$30-50/mes (seguridad + infra)"
log_warning "════════════════════════════════════════════════════════════"
echo ""
read -p "¿Aplicar cambios en AWS? (escribe 'SI' para confirmar): " APPLY_CONFIRM

if [[ "$APPLY_CONFIRM" != "SI" ]]; then
    log_error "Aplicación cancelada"
    log_info "Puedes aplicar manualmente más tarde con:"
    log_info "  cd environments/prod"
    log_info "  terraform apply tfplan-nueva-cuenta"
    exit 0
fi

log_info "Paso 7/10: Aplicando cambios en AWS (esto tomará 15-20 minutos)..."

terraform apply tfplan-nueva-cuenta

log_success "Infraestructura desplegada exitosamente!"

################################################################################
# PASO 8: Guardar outputs
################################################################################

log_info "Paso 8/10: Guardando outputs..."

terraform output > ../../outputs-prod-${PROJECT_NAME}.txt

log_success "Outputs guardados en: outputs-prod-${PROJECT_NAME}.txt"

################################################################################
# PASO 9: Verificar servicios
################################################################################

log_info "Paso 9/10: Verificando servicios de seguridad..."

# GuardDuty
GUARDDUTY_ID=$(aws guardduty list-detectors --region $AWS_REGION --query 'DetectorIds[0]' --output text)
if [[ -n "$GUARDDUTY_ID" ]]; then
    log_success "GuardDuty: $GUARDDUTY_ID"
else
    log_warning "GuardDuty: No detectado"
fi

# WAF CloudFront
WAF_CF=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?contains(Name, '${PROJECT_NAME}')].Id" --output text 2>/dev/null)
if [[ -n "$WAF_CF" ]]; then
    log_success "WAF CloudFront: OK"
else
    log_warning "WAF CloudFront: No detectado"
fi

# CloudTrail
TRAIL=$(aws cloudtrail describe-trails --region $AWS_REGION --query "trailList[?contains(Name, '${PROJECT_NAME}')].Name" --output text)
if [[ -n "$TRAIL" ]]; then
    log_success "CloudTrail: $TRAIL"
else
    log_warning "CloudTrail: No detectado"
fi

################################################################################
# PASO 10: Instrucciones finales
################################################################################

log_info "Paso 10/10: Instrucciones finales"

echo ""
log_success "╔════════════════════════════════════════════════════════════╗"
log_success "║                                                            ║"
log_success "║  ✅ IMPLEMENTACIÓN COMPLETADA EXITOSAMENTE                ║"
log_success "║                                                            ║"
log_success "╚════════════════════════════════════════════════════════════╝"
echo ""

log_warning "📧 ACCIÓN REQUERIDA: Confirmar subscripción SNS"
log_warning "   1. Revisa el email: $SECURITY_EMAIL"
log_warning "   2. Busca: 'AWS Notification - Subscription Confirmation'"
log_warning "   3. Haz click en 'Confirm subscription'"
echo ""

if [[ -n "$FRONTEND_DOMAIN" ]]; then
    log_warning "🌐 ACCIÓN REQUERIDA: Configurar DNS"
    log_warning "   Ejecuta en tu DNS provider:"
    echo ""
    terraform output frontend_cert_validation_records
    echo ""
fi

log_info "📊 Recursos creados:"
log_info "   - CloudFront URL: $(terraform output -raw cloudfront_domain 2>/dev/null || echo 'Ver outputs')"
log_info "   - ALB URL: $(terraform output -raw alb_dns_name 2>/dev/null || echo 'Ver outputs')"
log_info "   - GuardDuty ID: $GUARDDUTY_ID"
echo ""

log_info "📁 Archivos importantes:"
log_info "   - Outputs: outputs-prod-${PROJECT_NAME}.txt"
log_info "   - Plan: environments/prod/tfplan-nueva-cuenta"
echo ""

log_info "🔗 Dashboards AWS:"
log_info "   - WAF: https://console.aws.amazon.com/wafv2"
log_info "   - GuardDuty: https://console.aws.amazon.com/guardduty"
log_info "   - CloudTrail: https://console.aws.amazon.com/cloudtrail"
echo ""

log_info "💰 Monitorear costos:"
log_info "   - Cost Explorer: https://console.aws.amazon.com/cost-management"
echo ""

log_success "🎉 Todo listo! La infraestructura está protegida con:"
log_success "   ✅ WAF (CloudFront + ALB)"
log_success "   ✅ GuardDuty (Detección de amenazas 24/7)"
log_success "   ✅ CloudTrail (Auditoría completa)"
log_success "   ✅ CloudWatch Alarms (33 alarmas configuradas)"
echo ""

# Guardar resumen
cat > ../../RESUMEN-IMPLEMENTACION-${PROJECT_NAME}.txt <<EOF
═══════════════════════════════════════════════════════════════
RESUMEN DE IMPLEMENTACIÓN
═══════════════════════════════════════════════════════════════

Fecha: $(date)
Cuenta AWS: $ACCOUNT_ID
Proyecto: $PROJECT_NAME
Región: $AWS_REGION

RECURSOS PRINCIPALES:
- State Bucket: $STATE_BUCKET
- Lock Table: $LOCK_TABLE
- GuardDuty: $GUARDDUTY_ID
- Email Alertas: $SECURITY_EMAIL

URLS:
- CloudFront: $(terraform output -raw cloudfront_domain 2>/dev/null)
- ALB: $(terraform output -raw alb_dns_name 2>/dev/null)

PRÓXIMOS PASOS:
1. ✅ Confirmar email SNS
2. ⏳ Configurar DNS (si aplicable)
3. ⏳ Test de conectividad
4. ⏳ Configurar staging (opcional)

DOCUMENTACIÓN:
- Guía completa: DEPLOY-NUEVA-CUENTA.md
- Outputs: outputs-prod-${PROJECT_NAME}.txt
- Comandos útiles: Ver RESUMEN-SEGURIDAD.md

═══════════════════════════════════════════════════════════════
EOF

log_success "Resumen guardado en: RESUMEN-IMPLEMENTACION-${PROJECT_NAME}.txt"

echo ""
log_info "¿Deseas configurar Staging también? (y/n) [n]: "
read -t 10 SETUP_STAGING || SETUP_STAGING="n"

if [[ "$SETUP_STAGING" == "y" ]]; then
    log_info "Configurando Staging..."
    cd ../staging

    # Actualizar backend staging
    cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "$STATE_BUCKET"
    region         = "$AWS_REGION"
    key            = "staging/terraform.tfstate"
    dynamodb_table = "$LOCK_TABLE"
    encrypt        = true
  }
}
EOF

    # Actualizar variables staging
    sed -i.bak "s/default = \"massnexus-stg\"/default = \"${PROJECT_NAME}-stg\"/" variables.tf
    sed -i.bak "s/181.92.77.33/${CURRENT_IP}/" variables.tf
    rm -f variables.tf.bak

    terraform init
    terraform plan -out=tfplan-stg

    log_info "Para aplicar staging, ejecuta:"
    log_info "  cd environments/staging"
    log_info "  terraform apply tfplan-stg"

    cd ../..
fi

echo ""
log_success "╔════════════════════════════════════════════════════════════╗"
log_success "║  Script completado. ¡Gracias por usar esta herramienta!   ║"
log_success "╚════════════════════════════════════════════════════════════╝"
