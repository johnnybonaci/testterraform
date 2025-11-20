########################
# GuardDuty - Detección de Amenazas
########################

resource "aws_guardduty_detector" "main" {
  enable = true

  # Analizar S3 logs para detectar accesos sospechosos
  datasources {
    s3_logs {
      enable = true
    }

    kubernetes {
      audit_logs {
        enable = false # No usamos EKS
      }
    }

    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true # Escanear EBS si se detecta actividad sospechosa
        }
      }
    }
  }

  # Frecuencia de publicación de findings
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    env   = "prod"
    stack = "yieldpro"
    role  = "threat-detection"
  }
}

########################
# SNS Topic para Alertas de GuardDuty
########################

resource "aws_sns_topic" "guardduty_alerts" {
  name              = "${var.name}-guardduty-alerts"
  display_name      = "GuardDuty Security Alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    env   = "prod"
    stack = "yieldpro"
  }
}

# Email subscription (reemplaza con tu email)
resource "aws_sns_topic_subscription" "guardduty_email" {
  topic_arn = aws_sns_topic.guardduty_alerts.arn
  protocol  = "email"
  endpoint  = var.security_alert_email

  # Nota: Requerirá confirmación por email después del apply
}

########################
# EventBridge Rule para GuardDuty Findings
########################

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${var.name}-guardduty-findings"
  description = "Captura todos los findings de GuardDuty"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
  })

  tags = {
    env = "prod"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.guardduty_alerts.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      title       = "$.detail.title"
      description = "$.detail.description"
      type        = "$.detail.type"
      region      = "$.region"
      accountId   = "$.account"
      time        = "$.time"
    }

    input_template = <<EOF
"🚨 GUARDDUTY ALERT - Severity: <severity>"
"Account: <accountId>"
"Region: <region>"
"Time: <time>"
""
"Type: <type>"
"Title: <title>"
""
"Description: <description>"
""
"Action Required: Review this finding in the GuardDuty console."
EOF
  }
}

# Política para que EventBridge pueda publicar en SNS
resource "aws_sns_topic_policy" "guardduty_alerts" {
  arn = aws_sns_topic.guardduty_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.guardduty_alerts.arn
      }
    ]
  })
}

########################
# EventBridge Rule para High Severity Findings
########################

resource "aws_cloudwatch_event_rule" "guardduty_high_severity" {
  name        = "${var.name}-guardduty-high-severity"
  description = "Findings de GuardDuty con severidad alta (7.0+)"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [
        { numeric = [">=", 7.0] }
      ]
    }
  })

  tags = {
    env = "prod"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_high_severity_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_high_severity.name
  target_id = "SendToSNSHighSeverity"
  arn       = aws_sns_topic.guardduty_alerts.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      title       = "$.detail.title"
      description = "$.detail.description"
      type        = "$.detail.type"
    }

    input_template = <<EOF
"🔴 CRITICAL GUARDDUTY ALERT - Severity: <severity>"
""
"Type: <type>"
"Title: <title>"
""
"Description: <description>"
""
"⚠️ IMMEDIATE ACTION REQUIRED ⚠️"
EOF
  }
}

########################
# Lambda para respuesta automática (opcional)
########################

# Puedes descomentar esto para crear una Lambda que responda automáticamente
# a ciertos tipos de amenazas (ej: aislar instancia comprometida)

# data "archive_file" "guardduty_response" {
#   type        = "zip"
#   source_file = "${path.module}/lambda/guardduty_response.py"
#   output_path = "${path.module}/lambda/guardduty_response.zip"
# }

# resource "aws_lambda_function" "guardduty_response" {
#   filename      = data.archive_file.guardduty_response.output_path
#   function_name = "${var.name}-guardduty-auto-response"
#   role          = aws_iam_role.guardduty_lambda.arn
#   handler       = "guardduty_response.lambda_handler"
#   runtime       = "python3.11"
#   timeout       = 60
#
#   environment {
#     variables = {
#       SNS_TOPIC_ARN = aws_sns_topic.guardduty_alerts.arn
#     }
#   }
#
#   tags = {
#     env = "prod"
#   }
# }

########################
# CloudWatch Dashboard para GuardDuty
########################

resource "aws_cloudwatch_dashboard" "guardduty" {
  dashboard_name = "${var.name}-guardduty-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/GuardDuty", "FindingCount", { stat = "Sum", label = "Total Findings" }]
          ]
          period = 300
          stat   = "Sum"
          region = var.region
          title  = "GuardDuty Findings Count"
        }
      },
      {
        type = "log"
        properties = {
          query  = "SOURCE '/aws/guardduty/${var.name}' | fields @timestamp, severity, type, title | sort @timestamp desc | limit 20"
          region = var.region
          title  = "Recent GuardDuty Findings"
        }
      }
    ]
  })
}

########################
# Threat Intelligence List (opcional)
########################

# Puedes añadir listas de IPs conocidas como maliciosas
# resource "aws_guardduty_threat_intel_set" "custom" {
#   name        = "${var.name}-custom-threat-intel"
#   detector_id = aws_guardduty_detector.main.id
#   format      = "TXT"
#   location    = "s3://${aws_s3_bucket.threat_intel.bucket}/threat-list.txt"
#   activate    = true
# }

########################
# Outputs
########################

output "guardduty_detector_id" {
  value       = aws_guardduty_detector.main.id
  description = "ID del detector de GuardDuty"
}

output "guardduty_sns_topic" {
  value       = aws_sns_topic.guardduty_alerts.arn
  description = "ARN del SNS topic para alertas de GuardDuty"
}

output "guardduty_dashboard_url" {
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.name}-guardduty-dashboard"
  description = "URL del dashboard de GuardDuty en CloudWatch"
}
