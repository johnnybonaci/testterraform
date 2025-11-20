########################
# WAF para CloudFront (Staging)
########################

resource "aws_wafv2_web_acl" "cloudfront" {
  name  = "${var.name}-cloudfront-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Regla 0: IP Whitelist para Staging (solo IPs del equipo)
  rule {
    name     = "IPWhitelistRule"
    priority = 0

    action {
      block {
        custom_response {
          response_code            = 403
          custom_response_body_key = "ip_blocked"
        }
      }
    }

    statement {
      not_statement {
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.allowed_ips.arn
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-whitelist"
      sampled_requests_enabled   = true
    }
  }

  # Regla 1: Rate Limiting
  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Regla 2: AWS Managed Rules - Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

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
      metric_name                = "${var.name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Regla 3: Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

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

  # Custom response bodies
  custom_response_body {
    key = "ip_blocked"
    content = jsonencode({
      error = "Access denied. Your IP is not whitelisted for staging environment."
    })
    content_type = "APPLICATION_JSON"
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "waf-cloudfront"
  }
}

########################
# IP Set para Whitelist (Staging)
########################

resource "aws_wafv2_ip_set" "allowed_ips" {
  name               = "${var.name}-allowed-ips"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"

  # IMPORTANTE: Agregar las IPs de tu equipo aquí
  addresses = var.allowed_ips_staging

  tags = {
    env   = "staging"
    stack = "massnexus"
  }
}

########################
# WAF para ALB (Staging)
########################

resource "aws_wafv2_web_acl" "alb" {
  name  = "${var.name}-alb-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Regla 0: IP Whitelist
  rule {
    name     = "IPWhitelistRule"
    priority = 0

    action {
      block {}
    }

    statement {
      not_statement {
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.allowed_ips_alb.arn
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-alb-ip-whitelist"
      sampled_requests_enabled   = true
    }
  }

  # Regla 1: Rate Limiting
  rule {
    name     = "APIRateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-api-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Regla 2: Common Rules
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

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

  # Regla 3: PHP Rules
  rule {
    name     = "AWSManagedRulesPHPRuleSet"
    priority = 3

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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "waf-alb"
  }
}

########################
# IP Set para ALB (Regional)
########################

resource "aws_wafv2_ip_set" "allowed_ips_alb" {
  name               = "${var.name}-allowed-ips-alb"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"

  addresses = var.allowed_ips_staging

  tags = {
    env   = "staging"
    stack = "massnexus"
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
# Outputs
########################

output "waf_cloudfront_id" {
  value       = aws_wafv2_web_acl.cloudfront.id
  description = "ID del WAF de CloudFront (staging)"
}

output "waf_alb_id" {
  value       = aws_wafv2_web_acl.alb.id
  description = "ID del WAF del ALB (staging)"
}
