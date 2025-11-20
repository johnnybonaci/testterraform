# Guía de Limpieza y Arranque desde Cero - Terraform

Esta guía te ayudará a entender qué existe en AWS, cómo limpiarlo, y cómo empezar correctamente con la infraestructura actualizada.

## 📋 Requisitos Previos

Antes de empezar, asegúrate de tener instalado en tu máquina local:

```bash
# Verificar versiones instaladas
terraform --version  # Debe ser >= 1.6.0
aws --version        # AWS CLI v2 recomendado
aws sts get-caller-identity  # Verificar que estás autenticado
```

## 🔍 PASO 1: Investigar qué existe actualmente

### 1.1 Verificar si existe el bucket de state remoto

```bash
# Verificar si el bucket de Terraform state existe
aws s3 ls s3://massnexus-tf-state-nico/ 2>/dev/null

# Si existe, ver qué state files hay:
aws s3 ls s3://massnexus-tf-state-nico/prod/
aws s3 ls s3://massnexus-tf-state-nico/staging/
```

**¿Qué significa cada resultado?**

- **"Bucket does not exist"** → Nunca ejecutaste el bootstrap, empezar desde cero es fácil
- **"terraform.tfstate" visible** → Ya tienes infraestructura desplegada con Terraform
- **Bucket vacío** → El bucket existe pero no hay infraestructura desplegada

### 1.2 Buscar recursos AWS creados manualmente o con versiones anteriores

Ejecuta estos comandos para ver qué recursos existen con el nombre "massnexus":

```bash
# VPCs
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*massnexus*" \
  --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table

# EC2 Instances
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*massnexus*" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Load Balancers
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `massnexus`)].LoadBalancerArn' \
  --output table

# RDS Instances
aws rds describe-db-instances \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `massnexus`)].DBInstanceIdentifier' \
  --output table

# ElastiCache (Redis)
aws elasticache describe-cache-clusters \
  --query 'CacheClusters[?contains(CacheClusterId, `massnexus`)].CacheClusterId' \
  --output table

# S3 Buckets
aws s3 ls | grep massnexus

# CloudFront Distributions
aws cloudfront list-distributions \
  --query 'DistributionList.Items[?contains(Origins.Items[0].DomainName, `massnexus`)].Id' \
  --output table

# NAT Gateways
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=*massnexus*" \
  --query 'NatGateways[*].[NatGatewayId,State]' --output table
```

**Anota todo lo que encuentres**. Estos son recursos que consumen dinero.

## 🧹 PASO 2: Estrategia de Limpieza

Tienes dos opciones según lo que encontraste:

### Opción A: Tenés State File y recursos gestionados por Terraform

Si encontraste `terraform.tfstate` en S3, significa que Terraform ya gestionó recursos. **Esta es la forma más segura de destruir**:

```bash
# 1. Ir al entorno que querés destruir
cd environments/prod  # o environments/staging

# 2. Inicializar Terraform (conecta con el state remoto)
terraform init

# 3. Ver qué recursos existen según Terraform
terraform state list

# 4. Ver el plan de destrucción
terraform plan -destroy

# 5. DESTRUIR TODO (cuidado, esto borra TODA la infraestructura)
terraform destroy

# Terraform te pedirá confirmación. Escribe "yes" para confirmar.
```

**⚠️ IMPORTANTE**: `terraform destroy` eliminará:
- Todos los EC2 instances
- Load balancers
- RDS databases (se hará snapshot automático si está configurado)
- Redis clusters
- VPCs y todo el networking
- S3 buckets (solo si están vacíos, sino fallará)

**Recursos que NO se destruyen automáticamente**:
- S3 buckets con contenido (debes vaciarlos primero)
- Algunos backups/snapshots

### Opción B: No tenés State File pero tenés recursos huérfanos

Si encontraste recursos en AWS pero NO hay state file, fueron creados manualmente o se perdió el state. **Debes destruir manualmente**:

#### 1. Vaciar y eliminar S3 buckets

```bash
# Listar buckets massnexus
aws s3 ls | grep massnexus

# Para cada bucket, primero vaciarlo:
aws s3 rm s3://massnexus-prd-frontend --recursive
aws s3 rm s3://massnexus-prd-logs --recursive
aws s3 rm s3://massnexus-prd-backend-artifacts --recursive

# Luego eliminar el bucket
aws s3 rb s3://massnexus-prd-frontend
aws s3 rb s3://massnexus-prd-logs
aws s3 rb s3://massnexus-prd-backend-artifacts
```

#### 2. Eliminar CloudFront distributions

```bash
# Obtener lista de distributions
aws cloudfront list-distributions

# Para cada distribution massnexus:
# 1. Deshabilitarla primero
aws cloudfront get-distribution-config --id <DISTRIBUTION_ID> > dist-config.json
# Editar dist-config.json y cambiar "Enabled": true → "Enabled": false
aws cloudfront update-distribution --id <DISTRIBUTION_ID> --if-match <ETAG> --distribution-config file://dist-config.json

# 2. Esperar a que esté "Deployed" (puede tomar 15-20 minutos)
aws cloudfront get-distribution --id <DISTRIBUTION_ID> --query 'Distribution.Status'

# 3. Eliminarla
aws cloudfront delete-distribution --id <DISTRIBUTION_ID> --if-match <NEW_ETAG>
```

#### 3. Eliminar RDS instances

```bash
# Ver instancias
aws rds describe-db-instances

# Eliminar (sin snapshot final para testing)
aws rds delete-db-instance \
  --db-instance-identifier massnexus-prd-mysql \
  --skip-final-snapshot

# O con snapshot final (recomendado si tenés datos)
aws rds delete-db-instance \
  --db-instance-identifier massnexus-prd-mysql \
  --final-db-snapshot-identifier massnexus-prd-mysql-final-snapshot
```

#### 4. Eliminar ElastiCache (Redis)

```bash
aws elasticache delete-replication-group \
  --replication-group-id massnexus-prd-redis \
  --no-retain-primary-cluster
```

#### 5. Eliminar Load Balancers y Target Groups

```bash
# Obtener ARN del ALB
aws elbv2 describe-load-balancers

# Eliminar ALB
aws elbv2 delete-load-balancer --load-balancer-arn <ARN>

# Eliminar Target Group (después de eliminar ALB)
aws elbv2 describe-target-groups
aws elbv2 delete-target-group --target-group-arn <ARN>
```

#### 6. Terminar EC2 Instances y Auto Scaling Groups

```bash
# Si hay Auto Scaling Group
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name massnexus-prd-asg \
  --force-delete

# Si hay instancias standalone
aws ec2 describe-instances --filters "Name=tag:Name,Values=*massnexus*"
aws ec2 terminate-instances --instance-ids <ID1> <ID2>
```

#### 7. Eliminar NAT Gateways (si existen)

```bash
# NAT Gateways cuestan ~$32/mes, importante eliminarlos
aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=*massnexus*"
aws ec2 delete-nat-gateway --nat-gateway-id <NAT_ID>

# Esperar a que estén eliminados, luego liberar las Elastic IPs
aws ec2 describe-addresses
aws ec2 release-address --allocation-id <ALLOCATION_ID>
```

#### 8. Eliminar VPC (al final)

```bash
# La VPC se debe eliminar después de todo lo demás
# Primero eliminar subnets, security groups, internet gateways

# Ver VPCs
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*massnexus*"

# Eliminar VPC (esto fallará si todavía tiene recursos dependientes)
aws ec2 delete-vpc --vpc-id <VPC_ID>
```

## 🚀 PASO 3: Empezar desde Cero (Orden Correcto)

Una vez que limpiaste TODO, sigue este orden exacto:

### 3.1 Bootstrap (Solo una vez, crear remote state)

```bash
cd 0-bootstrap/remote-state

# Inicializar (usa state LOCAL porque todavía no existe el bucket)
terraform init

# Ver qué va a crear
terraform plan \
  -var="state_bucket_name=massnexus-tf-state-nico" \
  -var="lock_table_name=tf-locks-massnexus"

# Crear el bucket S3 y tabla DynamoDB
terraform apply \
  -var="state_bucket_name=massnexus-tf-state-nico" \
  -var="lock_table_name=tf-locks-massnexus"

# Escribir "yes" para confirmar
```

**¿Qué hace esto?**
- Crea bucket S3: `massnexus-tf-state-nico` (para guardar el state)
- Crea tabla DynamoDB: `tf-locks-massnexus` (para evitar que dos personas ejecuten terraform al mismo tiempo)

### 3.2 Desplegar Staging (Entorno de prueba)

```bash
cd ../../environments/staging

# Inicializar (ahora SÍ usa remote state en S3)
terraform init

# Ver el plan completo
terraform plan

# Aplicar (esto creará TODA la infraestructura de staging)
terraform apply

# Escribir "yes" para confirmar
```

**Tiempo estimado**: 15-25 minutos (RDS tarda ~10 min, Redis ~5 min)

**Costo mensual aproximado**: ~$150/mes

**Qué se crea**:
- VPC con subnets públicas/privadas
- NAT Gateway (principal costo)
- EC2 instance (t3.small) con Auto Scaling
- RDS MySQL (db.t4g.small, Single-AZ)
- ElastiCache Redis (cache.t4g.micro)
- Application Load Balancer
- S3 buckets para frontend y logs
- CloudFront distribution
- ACM certificates (requiere validación DNS)

### 3.3 Validar Certificados SSL (CRÍTICO)

Terraform creará los certificados pero se quedará esperando validación DNS:

```bash
# Ver qué registros DNS necesitas crear
terraform output frontend_cert_validation_records
terraform output backend_cert_validation_records
```

**Para Staging** (`yieldpro.massnexus.com`):
1. Copiar el registro CNAME que te muestra el output
2. Ir a tu DNS provider (Cloudflare, GoDaddy, etc.)
3. Crear el registro CNAME
4. Esperar 5-10 minutos
5. Ejecutar `terraform apply` de nuevo (detectará que el cert fue validado)

**Si no haces esto**: CloudFront no funcionará con HTTPS

### 3.4 Desplegar Aplicación

Una vez que la infraestructura está lista:

#### Frontend (React)

```bash
# En tu repo de frontend, configurar GitHub Actions
# Ver GUIA-MIGRACION-PRODUCCION.md sección "GitHub Actions"

# O deployment manual:
npm run build
aws s3 sync dist/ s3://massnexus-stg-frontend/
aws cloudfront create-invalidation --distribution-id <ID> --paths "/*"
```

#### Backend (Laravel)

```bash
# SSH a la instancia EC2 via Session Manager
aws ssm start-session --target <INSTANCE_ID>

# Dentro del EC2:
cd /var/www/app
sudo -u www-data composer install --no-dev --optimize-autoloader
sudo -u www-data php artisan migrate --force
sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache

# Reiniciar services
sudo systemctl restart php8.3-fpm
sudo supervisorctl restart all
```

### 3.5 Verificar que todo funciona

```bash
# Ver todos los outputs
terraform output

# URLs importantes
terraform output alb_dns_name        # Backend API
terraform output cloudfront_domain   # Frontend

# Conexiones a DB
terraform output db_endpoint
terraform output redis_endpoint
```

**Pruebas**:
1. Abrir CloudFront domain en navegador → Debe ver el frontend React
2. Curl al ALB → Debe ver respuesta Laravel
3. Verificar logs del worker:
   ```bash
   aws ssm start-session --target <INSTANCE_ID>
   sudo tail -f /var/log/app/worker.log
   ```

## 🎓 Entendiendo el Flujo de Trabajo

### ¿Qué hace `terraform init`?

1. Lee el archivo `backend.tf`
2. Se conecta al bucket S3 remoto
3. Descarga el state file (si existe)
4. Descarga los providers (AWS)

### ¿Qué hace `terraform plan`?

1. Lee todos los archivos `.tf`
2. Compara con el state file actual
3. Compara con la realidad en AWS (llama a APIs de AWS)
4. Muestra qué va a crear (+), cambiar (~), o destruir (-)

**NO modifica nada**, solo muestra el plan.

### ¿Qué hace `terraform apply`?

1. Ejecuta `plan` primero
2. Te pide confirmación
3. Crea/modifica/destruye recursos en AWS según el plan
4. Actualiza el state file con los nuevos IDs/ARNs

### ¿Cómo modificar la infraestructura después?

```bash
# 1. Editar archivos .tf
# 2. Ver qué cambios haría
terraform plan

# 3. Aplicar los cambios
terraform apply

# Terraform solo modifica lo que cambió
```

**Ejemplo**: Si cambias `instance_type = "t3.small"` a `instance_type = "t3.medium"`:
- Terraform detectará el cambio
- Mostrará que va a reemplazar (~) la instancia
- Al aplicar, creará la nueva y destruirá la vieja

## 📊 Verificar Costos Actuales

Antes de empezar, revisa qué estás pagando actualmente:

```bash
# AWS Cost Explorer (desde consola web)
https://console.aws.amazon.com/cost-management/home#/dashboard

# O via CLI
aws ce get-cost-and-usage \
  --time-period Start=2025-11-01,End=2025-11-19 \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=SERVICE
```

## 🆘 Troubleshooting Común

### "Error acquiring the state lock"

Otra persona o proceso está ejecutando Terraform. Espera 5 minutos, si persiste:

```bash
# Forzar unlock (SOLO si estás seguro que nadie más está ejecutando)
terraform force-unlock <LOCK_ID>
```

### "AccessDenied" al crear recursos

Tu usuario IAM no tiene permisos. Necesitas una política como:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "*",
    "Resource": "*"
  }]
}
```

(En producción real, usar permisos más restrictivos)

### "Bucket already exists" al crear state bucket

Alguien ya creó el bucket. Opciones:
1. Usar otro nombre: `-var="state_bucket_name=massnexus-tf-state-TUNOMBRE"`
2. Importar el bucket existente: `terraform import aws_s3_bucket.state massnexus-tf-state-nico`

### RDS tarda mucho en crear

Es normal. RDS Multi-AZ puede tardar 15-20 minutos. Sé paciente.

### CloudFront queda en "In Progress"

También normal. CloudFront puede tardar 15-30 minutos en desplegar.

## 📝 Checklist Final

Antes de considerar que terminaste:

- [ ] Bootstrap ejecutado correctamente
- [ ] Staging/Prod infrastructure deployed
- [ ] Certificados SSL validados en DNS
- [ ] Frontend desplegado y accesible
- [ ] Backend API responde
- [ ] Conexión a RDS funciona
- [ ] Redis funciona (sessions/cache)
- [ ] Queue workers corriendo (Supervisor)
- [ ] Logs visibles en CloudWatch
- [ ] Backups RDS configurados
- [ ] Costos monitoreados

## 🎯 Próximos Pasos Recomendados

Una vez que entiendas el flujo básico:

1. **Configurar GitHub Actions** (ver `GUIA-MIGRACION-PRODUCCION.md`)
2. **Implementar monitoreo CloudWatch** (opcional)
3. **Configurar alertas SNS** para RDS, EC2, workers
4. **Habilitar NAT Gateway en prod** cuando estés listo (costo adicional)
5. **Implementar CI/CD completo** con CodeDeploy

## 💡 Recursos de Aprendizaje

- [Terraform Getting Started](https://developer.hashicorp.com/terraform/tutorials/aws-get-started)
- [AWS CLI Reference](https://awscli.amazonaws.com/v2/documentation/api/latest/reference/index.html)
- [Terraform State](https://developer.hashicorp.com/terraform/language/state)
- [Terraform Backend Configuration](https://developer.hashicorp.com/terraform/language/settings/backends/s3)

---

**¿Dudas?** Ejecuta los comandos de verificación del PASO 1 y comparte los resultados. Te ayudaré a interpretar qué encontraste y qué hacer al respecto.
