# Monitoreo CloudWatch - Guía Completa

Esta guía documenta el monitoreo implementado en la infraestructura de producción.

## 📊 Resumen

**Costo mensual**: ~$5-8/mes
**Alarms totales**: 17
**Coverage**: RDS, Redis, EC2, ALB, Auto Scaling

## 🔔 Alertas Configuradas

### RDS MySQL (5 alarms)

| Alarm | Threshold | Período | Qué significa |
|-------|-----------|---------|---------------|
| **CPU High** | > 80% | 10 min (2x5min) | Base de datos sobrecargada |
| **Connections High** | > 80 | 10 min | Muchas conexiones activas |
| **Storage Low** | < 10GB | 5 min | Espacio en disco bajo |
| **Read Latency** | > 10ms | 15 min (3x5min) | Queries SELECT lentas |
| **Write Latency** | > 10ms | 15 min (3x5min) | INSERT/UPDATE lentos |

**Acciones**:
- **CPU High**: Considerar upgrade a db.r6g.large o optimizar queries
- **Connections**: Revisar connection pool de Laravel, posible leak
- **Storage**: RDS auto-scale hasta 1TB, pero alertar temprano
- **Latency**: Revisar slow query log, crear índices

### Redis ElastiCache (4 alarms)

| Alarm | Threshold | Período | Qué significa |
|-------|-----------|---------|---------------|
| **Memory High** | > 80% | 10 min | Redis casi lleno |
| **Evictions** | > 0 | 5 min | Redis está borrando keys (CRÍTICO) |
| **CPU High** | > 75% | 10 min | Redis sobrecargado |
| **Replication Lag** | > 5s | 2 min (2x1min) | Replicas atrasadas |

**Acciones**:
- **Memory**: Limpiar cache antiguo o upgrade a cache.m6g.large
- **Evictions**: URGENTE - upgrade inmediato, pérdida de datos
- **CPU**: Revisar operaciones O(N) costosas (KEYS *, SMEMBERS grandes)
- **Replication Lag**: Verificar red, posible problema Multi-AZ

### EC2 / Auto Scaling (2 alarms)

| Alarm | Threshold | Período | Qué significa |
|-------|-----------|---------|---------------|
| **CPU High** | > 80% | 10 min | Servidores sobrecargados |
| **Status Check Failed** | > 0 | 2 min (2x1min) | Instancia con problemas |

**Acciones**:
- **CPU**: Auto scaling debería haber agregado instancias (revisar policy)
- **Status Check**: Auto scaling reemplazará instancia automáticamente

### Application Load Balancer (4 alarms)

| Alarm | Threshold | Período | Qué significa |
|-------|-----------|---------|---------------|
| **5xx Errors** | > 10 en 5min | 5 min | Errores del backend |
| **Response Time** | > 2s | 10 min (2x5min) | Respuestas lentas |
| **Unhealthy Targets** | > 0 | 1 min | Instancias caídas |
| **Healthy Targets Low** | < 2 | 1 min | No hay suficientes instancias |

**Acciones**:
- **5xx**: Revisar logs Laravel `/var/log/app/laravel.log`
- **Response Time**: Revisar queries lentas, cache
- **Unhealthy**: Auto scaling creará nueva instancia
- **Healthy Low**: CRÍTICO - Capacidad reducida

## 📧 Configuración de Email

### Paso 1: Cambiar email en variables.tf

```hcl
variable "alert_email" {
  default = "tu-email@empresa.com" # CAMBIAR ESTO
}
```

### Paso 2: Confirmar suscripción SNS

Después de `terraform apply`:

1. Recibirás email de AWS: "AWS Notification - Subscription Confirmation"
2. Click en "Confirm subscription"
3. Verás: "Subscription confirmed!"

**Hasta que NO confirmes, NO recibirás alertas**.

## 🚀 Auto Scaling Automático

### Target Tracking (Principal)

**Configurado**: Mantener CPU promedio en **70%**

```
CPU < 70% → Scale in (reducir instancias)
CPU > 70% → Scale out (agregar instancias)
```

**Ejemplo real**:
```
Estado inicial: 2 instancias, CPU 50%
Spike de tráfico: CPU sube a 85%
Auto Scaling: Agrega 1 instancia (total 3)
Nueva CPU: 56% (distribuido entre 3)
```

**Cooldowns**:
- Scale out: 60 segundos (responde rápido)
- Scale in: 300 segundos (evita flapping)

### Step Scaling (Emergencias)

**Configurado**: CPU > 90% = acción agresiva

```
CPU 90-99%: +1 instancia
CPU > 100%: +2 instancias (máximo)
```

Esto se activa SOLO en emergencias, `TargetTracking` maneja lo normal.

## 📊 CloudWatch Log Groups

**Logs centralizados** con retention:

| Log Group | Retention | Uso |
|-----------|-----------|-----|
| `/aws/ec2/massnexus-prd/app` | 30 días | Laravel logs (errores, debug) |
| `/aws/ec2/massnexus-prd/nginx` | 14 días | Access logs, error logs |
| `/aws/ec2/massnexus-prd/workers` | 30 días | Supervisor workers |

**Costo estimado logs**: ~$3-4/mes (6GB/mes estimado)

### Ver logs en tiempo real

```bash
# Laravel logs
aws logs tail /aws/ec2/massnexus-prd/app --follow --region us-east-1

# Nginx errors
aws logs tail /aws/ec2/massnexus-prd/nginx --follow --region us-east-1

# Workers
aws logs tail /aws/ec2/massnexus-prd/workers --follow --region us-east-1
```

### Buscar en logs

```bash
# Buscar errores 500 en últimas 2 horas
aws logs filter-log-events \
  --log-group-name /aws/ec2/massnexus-prd/app \
  --region us-east-1 \
  --start-time $(date -u -d '2 hours ago' +%s)000 \
  --filter-pattern "500"

# Buscar excepciones de Laravel
aws logs filter-log-events \
  --log-group-name /aws/ec2/massnexus-prd/app \
  --region us-east-1 \
  --start-time $(date -u -d '1 hour ago' +%s)000 \
  --filter-pattern "Exception"
```

## 💰 Desglose de Costos

### Alarms (17 total)

```
Primeros 10: $0 (free tier)
Siguientes 7: $0.10 × 7 = $0.70/mes
```

### Logs

```
Ingestion (6GB/mes): $3.00/mes
Storage (mes 1): $0.18/mes
Storage (mes 3+): $0.54/mes
```

### Custom Metrics (futuro)

Si agregas métricas custom (queue depth, memory):
```
2 custom metrics: $0.60/mes
```

### Total Estimado

**Mes 1**: $3.88/mes
**Mes 3+**: $4.24-5.00/mes

Con custom metrics: ~$5-8/mes

## 🎯 Interpretación de Alertas

### Ejemplo 1: Email "RDS CPU High"

```
Alarm: massnexus-prd-rds-cpu-high
Estado: ALARM
Threshold: 80%
Valor actual: 92%
```

**Qué hacer**:
1. Ir a CloudWatch → RDS → Ver gráfica CPU
2. Si es spike temporal: OK, monitorear
3. Si es sostenido (> 30 min): Problema real
   - Revisar slow query log
   - Considerar upgrade a db.r6g.large

### Ejemplo 2: Email "Redis Evictions"

```
Alarm: massnexus-prd-redis-evictions
Estado: ALARM
Evictions: 125 keys
```

**Qué hacer**:
1. **URGENTE** - Redis está borrando datos
2. Usuarios pueden perder sessions
3. Queue jobs pueden perderse
4. Acción inmediata:
   ```bash
   # Limpiar cache manualmente
   redis-cli -h <endpoint> --tls AUTH <password>
   > FLUSHDB

   # O upgrade Redis
   terraform apply # Con node_type = cache.m6g.large
   ```

### Ejemplo 3: Email "ALB Unhealthy Targets"

```
Alarm: massnexus-prd-alb-unhealthy-targets
Estado: ALARM
Unhealthy: 1 de 2
```

**Qué hacer**:
1. Auto Scaling creará nueva instancia automáticamente
2. Verificar logs de la instancia fallida:
   ```bash
   # Obtener instance ID
   aws ec2 describe-instances \
     --filters "Name=tag:Name,Values=massnexus-prd-app" \
     --query 'Reservations[*].Instances[*].[InstanceId,State.Name]'

   # Ver logs via SSM
   aws ssm start-session --target i-XXXXXXX
   sudo tail -f /var/log/nginx/error.log
   ```

## 📈 Dashboard CloudWatch (Opcional)

Puedes crear dashboard visual en CloudWatch console:

1. Ir a CloudWatch → Dashboards → Create dashboard
2. Agregar widgets:
   - RDS: CPU, Connections, Latency
   - Redis: Memory, CPU, Evictions
   - ALB: Request count, 5xx, Latency
   - ASG: Instance count, CPU

**Costo**: $3/mes (o gratis si usas 1 de los 3 free tier)

## 🔧 Troubleshooting

### No recibo emails de alertas

1. Verificar SNS subscription confirmada:
   ```bash
   aws sns list-subscriptions-by-topic \
     --topic-arn arn:aws:sns:us-east-1:ACCOUNT:massnexus-prd-alerts \
     --region us-east-1
   ```

   Debe mostrar: `"SubscriptionArn": "arn:aws:sns:..."`
   NO: `"SubscriptionArn": "PendingConfirmation"`

2. Revisar spam/junk folder

3. Forzar alarm para testear:
   ```bash
   aws cloudwatch set-alarm-state \
     --alarm-name massnexus-prd-alb-unhealthy-targets \
     --state-value ALARM \
     --state-reason "Testing" \
     --region us-east-1
   ```

### Alarm en estado "INSUFFICIENT_DATA"

Normal al principio (primeros 5-10 minutos después de deploy).
Si persiste > 30 minutos: revisar que el recurso existe.

### Demasiadas alertas (alarm fatigue)

Si recibes muchas alertas:

1. Aumentar thresholds:
   ```hcl
   threshold = 85 # En lugar de 80
   ```

2. Aumentar evaluation periods:
   ```hcl
   evaluation_periods = 3 # En lugar de 2
   ```

3. Cambiar `treat_missing_data = "notBreaching"` si es flaky

## 📚 Referencias

- [CloudWatch Pricing](https://aws.amazon.com/cloudwatch/pricing/)
- [RDS Best Practices](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html)
- [ElastiCache Monitoring](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/CacheMetrics.html)
- [Auto Scaling Target Tracking](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)

## ✅ Checklist Post-Deploy

Después de `terraform apply`:

- [ ] Email SNS subscription confirmado
- [ ] Recibido email de test (forzar 1 alarm)
- [ ] Verificar alarms en estado OK en CloudWatch console
- [ ] Configurar dashboard (opcional)
- [ ] Revisar logs en CloudWatch Logs
- [ ] Documentar runbook de incidentes

## 🚨 Runbook de Incidentes

Ver archivo separado: `RUNBOOK-INCIDENTES.md` (crear si necesario)

Básico:
1. Recibir email alert
2. Verificar gráfica en CloudWatch
3. Si ALARM sostenido > 15 min: investigar
4. Revisar logs correspondientes
5. Escalar o remediar según tipo
6. Documentar en post-mortem

---

**Última actualización**: 2025-01-19
**Mantenido por**: DevOps Team
