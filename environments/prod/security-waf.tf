########################
# WAF para CloudFront (SCOPE: CLOUDFRONT)
# IMPORTANTE: WAF para CloudFront DEBE estar en us-east-1
########################

resource "aws_wafv2_web_acl" "cloudfront" {
  name  = "${var.name}-cloudfront-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Regla 0: Rate Limiting (protección DDoS capa 7)
  rule {
    name     = "RateLimitRule"
    priority = 0

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 2000 # 2000 requests per 5 minutes por IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Regla 1: AWS Managed Rules - Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Excluir reglas que generen falsos positivos en React/Laravel
        # Descomenta si tienes problemas con body size o query strings largos
        # rule_action_override {
        #   name = "SizeRestrictions_BODY"
        #   action_to_use {
        #     count {}
        #   }
        # }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 2: AWS Managed Rules - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Regla 3: AWS Managed Rules - SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-sqli-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 4: Geo-blocking (opcional: bloquear países sospechosos)
  # Descomenta si quieres restringir por país
  # rule {
  #   name     = "GeoBlockRule"
  #   priority = 4
  #
  #   action {
  #     block {}
  #   }
  #
  #   statement {
  #     geo_match_statement {
  #       country_codes = ["CN", "RU", "KP"] # Ejemplos: China, Rusia, Corea del Norte
  #     }
  #   }
  #
  #   visibility_config {
  #     cloudwatch_metrics_enabled = true
  #     metric_name                = "${var.name}-geo-block"
  #     sampled_requests_enabled   = true
  #   }
  # }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    env   = "prod"
    stack = "massnexus"
    role  = "waf-cloudfront"
  }
}

########################
# WAF para ALB (SCOPE: REGIONAL)
########################

resource "aws_wafv2_web_acl" "alb" {
  name  = "${var.name}-alb-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Regla 0: Rate Limiting específico para API backend
  rule {
    name     = "APIRateLimitRule"
    priority = 0

    action {
      block {
        custom_response {
          response_code = 429
          custom_response_body_key = "rate_limit_body"
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 1000 # Más restrictivo para API: 1000 req/5min
        aggregate_key_type = "IP"

        # Rate limit solo en endpoints críticos (login, register, etc)
        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/api/login"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/api/register"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-api-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Regla 1: AWS Managed Rules - Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-alb-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 2: AWS Managed Rules - PHP Application Protection
  rule {
    name     = "AWSManagedRulesPHPRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesPHPRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-php-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 3: SQL Injection Protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-alb-sqli-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 4: Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-alb-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Custom response para rate limiting
  custom_response_body {
    key          = "rate_limit_body"
    content      = jsonencode({
      error = "Too many requests. Please try again later."
    })
    content_type = "APPLICATION_JSON"
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    env   = "prod"
    stack = "massnexus"
    role  = "waf-alb"
  }
}

########################
# Asociar WAF al ALB
########################

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

########################
# Logging para WAF (requiere Kinesis Firehose)
# Para habilitar, crear primero Kinesis Firehose stream
# y descomentar las configuraciones abajo
########################

# resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
#   resource_arn            = aws_wafv2_web_acl.cloudfront.arn
#   log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_logs.arn]
#
#   redacted_fields {
#     single_header {
#       name = "authorization"
#     }
#   }
# }

# resource "aws_wafv2_web_acl_logging_configuration" "alb" {
#   resource_arn            = aws_wafv2_web_acl.alb.arn
#   log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_logs.arn]
#
#   redacted_fields {
#     single_header {
#       name = "authorization"
#     }
#   }
# }

########################
# Outputs
########################

output "waf_cloudfront_id" {
  value       = aws_wafv2_web_acl.cloudfront.id
  description = "ID del WAF de CloudFront"
}

output "waf_alb_id" {
  value       = aws_wafv2_web_acl.alb.id
  description = "ID del WAF del ALB"
}
