########################
# CloudTrail - Auditoría de API Calls
########################

# Bucket S3 para CloudTrail logs
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.name}-cloudtrail-logs"
  force_destroy = false

  tags = {
    env   = "prod"
    stack = "yieldpro"
    role  = "cloudtrail"
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "cloudtrail-logs-lifecycle"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365 # Retener logs por 1 año
    }
  }
}

# Política del bucket para que CloudTrail pueda escribir
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

########################
# CloudTrail Trail (Multi-Region)
########################

resource "aws_cloudtrail" "main" {
  name                          = "${var.name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  enable_logging                = true

  # Enviar logs también a CloudWatch para alertas en tiempo real
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # Eventos avanzados para detección de amenazas (reemplaza event_selector)
  advanced_event_selector {
    name = "Log all management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "Log S3 data events"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.cloudtrail
  ]

  tags = {
    env   = "prod"
    stack = "yieldpro"
    role  = "audit"
  }
}

########################
# CloudWatch Logs para CloudTrail
########################

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.name}"
  retention_in_days = 90

  tags = {
    env   = "prod"
    stack = "yieldpro"
  }
}

# IAM Role para que CloudTrail escriba en CloudWatch
resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "${var.name}-cloudtrail-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    env = "prod"
  }
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "${var.name}-cloudtrail-cloudwatch-policy"
  role = aws_iam_role.cloudtrail_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailCreateLogStream"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}

########################
# Métricas y Alarmas de CloudTrail
########################

# Alarma para cambios en Security Groups
resource "aws_cloudwatch_log_metric_filter" "security_group_changes" {
  name           = "${var.name}-security-group-changes"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupEgress) }"

  metric_transformation {
    name      = "SecurityGroupChanges"
    namespace = "${var.name}/CloudTrail"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "security_group_changes" {
  alarm_name          = "${var.name}-security-group-changes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "SecurityGroupChanges"
  namespace           = "${var.name}/CloudTrail"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Alerta cuando hay cambios en Security Groups"
  treat_missing_data  = "notBreaching"

  # Descomentar cuando tengas SNS topic configurado
  # alarm_actions = [aws_sns_topic.security_alerts.arn]

  tags = {
    env = "prod"
  }
}

# Alarma para cambios en IAM policies
resource "aws_cloudwatch_log_metric_filter" "iam_policy_changes" {
  name           = "${var.name}-iam-policy-changes"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.eventName = PutUserPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) }"

  metric_transformation {
    name      = "IAMPolicyChanges"
    namespace = "${var.name}/CloudTrail"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_policy_changes" {
  alarm_name          = "${var.name}-iam-policy-changes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "IAMPolicyChanges"
  namespace           = "${var.name}/CloudTrail"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Alerta cuando hay cambios en políticas IAM"
  treat_missing_data  = "notBreaching"

  tags = {
    env = "prod"
  }
}

# Alarma para intentos de acceso denegado (posible reconocimiento)
resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls" {
  name           = "${var.name}-unauthorized-api-calls"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"

  metric_transformation {
    name      = "UnauthorizedAPICalls"
    namespace = "${var.name}/CloudTrail"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  alarm_name          = "${var.name}-unauthorized-api-calls"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "UnauthorizedAPICalls"
  namespace           = "${var.name}/CloudTrail"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5" # Más de 5 intentos fallidos en 5 min
  alarm_description   = "Alerta cuando hay múltiples intentos de acceso no autorizado"
  treat_missing_data  = "notBreaching"

  tags = {
    env = "prod"
  }
}

# Alarma para cambios en Network ACLs
resource "aws_cloudwatch_log_metric_filter" "network_acl_changes" {
  name           = "${var.name}-network-acl-changes"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.eventName = CreateNetworkAcl*) || ($.eventName = DeleteNetworkAcl*) || ($.eventName = ReplaceNetworkAcl*) }"

  metric_transformation {
    name      = "NetworkACLChanges"
    namespace = "${var.name}/CloudTrail"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "network_acl_changes" {
  alarm_name          = "${var.name}-network-acl-changes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "NetworkACLChanges"
  namespace           = "${var.name}/CloudTrail"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Alerta cuando hay cambios en Network ACLs"
  treat_missing_data  = "notBreaching"

  tags = {
    env = "prod"
  }
}

########################
# Outputs
########################

output "cloudtrail_arn" {
  value       = aws_cloudtrail.main.arn
  description = "ARN del CloudTrail trail"
}

output "cloudtrail_bucket" {
  value       = aws_s3_bucket.cloudtrail.bucket
  description = "Bucket S3 para logs de CloudTrail"
}

output "cloudtrail_log_group" {
  value       = aws_cloudwatch_log_group.cloudtrail.name
  description = "CloudWatch Log Group para CloudTrail"
}
