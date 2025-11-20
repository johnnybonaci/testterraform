########################
# CloudWatch Monitoring & Alarms para Producción
# Costo estimado: $5-8/mes
########################

########################
# SNS Topic para Alertas
########################
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"

  tags = {
    env   = "prod"
    stack = "yieldpro"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # Cambiar por tu email real
}

########################
# CloudWatch Log Groups con Retention
########################

# Logs de aplicación (Laravel)
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/ec2/${var.name}/app"
  retention_in_days = 30 # 30 días, ajustar según necesidad (7, 14, 30, 60, 90)
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn

  tags = {
    env   = "prod"
    stack = "yieldpro"
  }
}

# Logs de Nginx
resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/aws/ec2/${var.name}/nginx"
  retention_in_days = 14 # Access logs menos tiempo
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn

  tags = {
    env   = "prod"
    stack = "yieldpro"
  }
}

# Logs de Workers (Supervisor)
resource "aws_cloudwatch_log_group" "workers" {
  name              = "/aws/ec2/${var.name}/workers"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn

  tags = {
    env   = "prod"
    stack = "yieldpro"
  }
}

########################
# RDS ALARMS (5 alarms)
########################

# RDS: CPU > 80%
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization is too high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2 # 2 períodos consecutivos
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300 # 5 minutos
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# RDS: Connections > 80 (de ~100 max para db.t4g.medium)
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name}-rds-connections-high"
  alarm_description   = "RDS database connections are too high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# RDS: Storage < 20% free
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name}-rds-storage-low"
  alarm_description   = "RDS free storage is low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10737418240 # 10GB en bytes (20% de 50GB)
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# RDS: Read latency > 10ms
resource "aws_cloudwatch_metric_alarm" "rds_read_latency" {
  alarm_name          = "${var.name}-rds-read-latency-high"
  alarm_description   = "RDS read latency is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ReadLatency"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 0.01 # 10ms
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# RDS: Write latency > 10ms
resource "aws_cloudwatch_metric_alarm" "rds_write_latency" {
  alarm_name          = "${var.name}-rds-write-latency-high"
  alarm_description   = "RDS write latency is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "WriteLatency"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 0.01 # 10ms
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

########################
# REDIS/ELASTICACHE ALARMS (4 alarms)
########################

# Redis: Memory > 80%
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${var.name}-redis-memory-high"
  alarm_description   = "Redis memory utilization is too high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# Redis: Evictions > 0 (señal de memoria insuficiente)
resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  alarm_name          = "${var.name}-redis-evictions"
  alarm_description   = "Redis is evicting keys (memory full)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# Redis: CPU > 75%
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${var.name}-redis-cpu-high"
  alarm_description   = "Redis CPU utilization is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# Redis: Replication lag > 5 segundos
resource "aws_cloudwatch_metric_alarm" "redis_replication_lag" {
  alarm_name          = "${var.name}-redis-replication-lag"
  alarm_description   = "Redis replication lag is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicationLag"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Maximum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

########################
# EC2/AUTO SCALING ALARMS (2 alarms)
########################

# ASG: CPU promedio > 80%
resource "aws_cloudwatch_metric_alarm" "asg_cpu" {
  alarm_name          = "${var.name}-asg-cpu-high"
  alarm_description   = "Auto Scaling Group CPU is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# ASG: Status checks failed
resource "aws_cloudwatch_metric_alarm" "asg_status_check" {
  alarm_name          = "${var.name}-asg-status-check-failed"
  alarm_description   = "EC2 instance status checks failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

########################
# ALB ALARMS (4 alarms)
########################

# ALB: 5xx errors > 10 en 5 minutos
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx-errors"
  alarm_description   = "ALB is returning 5xx errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# ALB: Response time > 2 segundos
resource "aws_cloudwatch_metric_alarm" "alb_response_time" {
  alarm_name          = "${var.name}-alb-response-time-high"
  alarm_description   = "ALB target response time is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# ALB: Unhealthy targets > 0
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  alarm_name          = "${var.name}-alb-unhealthy-targets"
  alarm_description   = "ALB has unhealthy targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

# ALB: Healthy targets < 2 (deberías tener min 2 instancias)
resource "aws_cloudwatch_metric_alarm" "alb_healthy_targets_low" {
  alarm_name          = "${var.name}-alb-healthy-targets-low"
  alarm_description   = "ALB has less than 2 healthy targets"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 2
  treat_missing_data  = "breaching" # Asumir problema si no hay datos

  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { env = "prod" }
}

########################
# Outputs
########################

output "sns_topic_arn" {
  description = "ARN del SNS Topic para alertas"
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_log_groups" {
  description = "CloudWatch Log Groups creados"
  value = {
    app     = aws_cloudwatch_log_group.app.name
    nginx   = aws_cloudwatch_log_group.nginx.name
    workers = aws_cloudwatch_log_group.workers.name
  }
}
