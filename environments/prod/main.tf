########################
# AZs disponibles
########################
data "aws_availability_zones" "available" {}

########################
# VPC (prod) – 2 AZs, subnets /21 (newbits=5)
########################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1"

  name = var.name
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /21 para tener más subredes disponibles (newbits=5)
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 5, 0),
    cidrsubnet(var.vpc_cidr, 5, 1)
  ]

  private_subnets = [
    cidrsubnet(var.vpc_cidr, 5, 10),
    cidrsubnet(var.vpc_cidr, 5, 11)
  ]

  database_subnets = [
    cidrsubnet(var.vpc_cidr, 5, 20),
    cidrsubnet(var.vpc_cidr, 5, 21)
  ]

  enable_nat_gateway     = false
  single_nat_gateway     = false
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # (Activamos Flow Logs cuando creemos el bucket de logs de prod)
  enable_flow_log = false

  tags = {
    env   = "prod"
    stack = "massnexus"
  }
}

########################
# VPC Endpoints (sin NAT)
########################

# S3: gateway endpoint (gratis)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = { env = "prod", role = "vpce-s3" }
}

# Interface endpoints (SSM, EC2Messages, SSMMessages, Logs, KMS)
locals {
  interface_endpoints = [
    "ssm",
    "ec2messages",
    "ssmmessages",
    "logs",
    "kms"
  ]
}

resource "aws_security_group" "vpce" {
  name        = "${var.name}-vpce"
  description = "SG for Interface VPC Endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { env = "prod" }
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { env = "prod", role = "vpce-${each.key}" }
}

########################
# Bucket central de logs (prod)
########################
module "logs_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1"

  bucket = "${var.name}-logs" # ej: massnexus-prd-logs (si existe, usa uno único)
  acl    = "log-delivery-write"

  # Requerido para CloudFront logs (ACLs activas)
  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  # Bloqueo público
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = { sse_algorithm = "AES256" }
    }
  }

  lifecycle_rule = [{
    id                                     = "logs"
    enabled                                = true
    abort_incomplete_multipart_upload_days = 7
    noncurrent_version_expiration          = { days = 30 }
    expiration                             = { days = 90 }
  }]

  tags = {
    env   = "prod"
    stack = "massnexus"
    role  = "logs"
  }
}

output "logs_bucket_name" {
  value = module.logs_bucket.s3_bucket_id
}

########################
# VPC Flow Logs a CloudWatch (prod)
########################
resource "aws_cloudwatch_log_group" "vpc_fl" {
  name              = "/vpc/${var.name}"
  retention_in_days = 30
  tags              = { env = "prod" }
}

resource "aws_iam_role" "vpc_fl" {
  name               = "${var.name}-vpc-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.vpc_fl_assume.json
}

data "aws_iam_policy_document" "vpc_fl_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "vpc_fl" {
  name   = "${var.name}-vpc-flow-logs-policy"
  role   = aws_iam_role.vpc_fl.id
  policy = data.aws_iam_policy_document.vpc_fl_policy.json
}

data "aws_iam_policy_document" "vpc_fl_policy" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
    resources = [aws_cloudwatch_log_group.vpc_fl.arn, "${aws_cloudwatch_log_group.vpc_fl.arn}:*"]
  }
}

resource "aws_flow_log" "this" {
  log_destination_type = "cloud-watch-logs"
  log_group_name       = aws_cloudwatch_log_group.vpc_fl.name
  iam_role_arn         = aws_iam_role.vpc_fl.arn
  traffic_type         = "ALL"
  vpc_id               = module.vpc.vpc_id
  tags                 = { env = "prod" }
}

########################
# S3 del frontend (prod)
########################
module "s3_frontend" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1"

  bucket = "${var.name}-frontend" # ej: massnexus-prd-frontend (si choca, cambialo por uno único)
  acl    = null

  force_destroy = false

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = { sse_algorithm = "AES256" }
    }
  }

  logging = {
    target_bucket = module.logs_bucket.s3_bucket_id
    target_prefix = "s3-frontend/"
  }

  tags = { env = "prod", stack = "massnexus", role = "frontend" }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name}-oac"
  description                       = "OAC for ${var.name} frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "managed_optimized" {
  name = "Managed-CachingOptimized"
}


########################
# CloudFront (prod) con OAC
########################
module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 5.0"

  comment             = "${var.name}-frontend"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"
  default_root_object = "index.html"

  # headers de seguridad administrados
  depends_on = [module.s3_frontend] # asegura que el bucket exista

  origin = {
    s3 = {
      domain_name              = module.s3_frontend.s3_bucket_bucket_regional_domain_name
      origin_id                = "s3-origin"
      origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
      s3_origin_config         = {}
    }
  }

  origin_access_control = {
    s3 = {
      description      = "OAC for ${var.name} frontend"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  default_cache_behavior = {
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.managed_optimized.id
    use_forwarded_values   = false
  }

  # WAF asociado (desde security-waf.tf)
  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  custom_error_response = [
    {
      error_code            = 404
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    },
    {
      error_code            = 403
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
  ]

  aliases = [var.frontend_domain_name] # ej: "yieldpro.massnexus.com"

  # 2) Certificado ACM para ese dominio
  viewer_certificate = {
    acm_certificate_arn      = aws_acm_certificate.frontend.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config = {
    bucket          = replace(module.logs_bucket.s3_bucket_bucket_domain_name, "https://", "")
    prefix          = "cloudfront/"
    include_cookies = false
  }

  tags = { env = "prod", stack = "massnexus", role = "cdn" }
}

########################
# ACM para CloudFront (DNS validation)
########################
resource "aws_acm_certificate" "frontend" {
  domain_name       = var.frontend_domain_name
  validation_method = "DNS"

  # CloudFront exige ACM en us-east-1
  provider = aws # asumimos provider ya está en us-east-1 para prod

  lifecycle {
    create_before_destroy = true
  }

  tags = { env = "prod", role = "cloudfront-cert" }
}

########################
# Security Groups (prod)
########################

# SG del ALB: expone HTTP 80 por ahora
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB SG (prod)"
  vpc_id      = module.vpc.vpc_id

ingress {
  description = "HTTPS from allowed IP only"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = [
    "200.123.128.225/32",
    "190.19.143.121/32", # si querés mantener la vieja por ahora
  ]
}

ingress {
  description = "HTTP from allowed IP only"
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = [
    "200.123.128.225/32",
    "190.19.143.121/32",
  ]
}

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { env = "prod" }
}

# SG de la app: solo recibe del ALB (80)
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "App SG (prod)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { env = "prod" }
}

########################
# ALB (prod) HTTP + TG
########################

resource "aws_lb" "app" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = { env = "prod", stack = "massnexus", role = "alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id

  health_check {
    enabled             = true
    port                = "traffic-port"
    protocol            = "HTTP"
    path                = "/health"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 15

  tags = { env = "prod", stack = "massnexus", role = "alb-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

########################
# HTTPS listener para ALB
########################
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = "arn:aws:acm:us-east-1:838108223027:certificate/76a7501d-f39c-4b68-8a66-f4db5fde1925"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

########################
# Redirección 80 -> 443
########################
resource "aws_lb_listener_rule" "redirect_http_to_https" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

########################
# ACM para ALB (DNS validation)
########################
resource "aws_acm_certificate" "backend" {
  domain_name       = var.backend_domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
  tags = { env = "prod", role = "alb-backend-cert" }
}

output "backend_cert_validation_records" {
  description = "CNAMEs para validar el cert del backend en GoDaddy"
  value = [
    for dvo in aws_acm_certificate.backend.domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ]
}

########################
# ACM (opcional) para el ALB
########################

# 1) Solicitud del certificado (si hay dominio)
resource "aws_acm_certificate" "alb" {
  count                     = var.backend_domain_name != "" ? 1 : 0
  domain_name               = var.backend_domain_name
  validation_method         = "DNS"
  subject_alternative_names = []

  lifecycle {
    create_before_destroy = true
  }

  tags = { env = "prod", role = "alb-cert" }
}

# 2) (Opcional) Validación automática si usás Route53
resource "aws_route53_record" "alb_cert_validation" {
  count   = var.backend_domain_name != "" && var.backend_domain_zone_id != "" ? 1 : 0
  zone_id = var.backend_domain_zone_id

  name    = one(aws_acm_certificate.alb[0].domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.alb[0].domain_validation_options).resource_record_type
  records = [one(aws_acm_certificate.alb[0].domain_validation_options).resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "alb" {
  count           = 0
  certificate_arn = aws_acm_certificate.alb[0].arn
  # validation_record_fqdns = var.backend_domain_zone_id != "" ? [aws_route53_record.alb_cert_validation[0].fqdn] : []
}

# Output útil (queda vacío si no seteaste dominio)
output "alb_certificate_arn" {
  value       = try(aws_acm_certificate_validation.alb[0].certificate_arn, "")
  description = "ARN del cert ACM validado para el ALB (si se configuró dominio)."
}


########################
# IAM para EC2 (SSM)
########################
resource "aws_iam_role" "ec2_role" {
  name               = "${var.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

########################
# AMI Ubuntu 22.04 (jammy)
########################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

########################
# Launch Template (Nginx + /health)
########################
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"

  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }

  network_interfaces {
    security_groups             = [aws_security_group.app.id]
    associate_public_ip_address = true # TEMPORAL hasta tener NAT
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y nginx software-properties-common unzip jq awscli
    add-apt-repository ppa:ondrej/php -y
    apt-get update -y
    apt-get install -y php8.2 php8.2-fpm php8.2-cli php8.2-mysql php8.2-xml php8.2-curl php8.2-mbstring php8.2-redis

    mkdir -p /var/www/app /var/log/app

    # Nginx vhost
    cat >/etc/nginx/sites-available/app <<'NGINX'
    server {
      listen 80 default_server;
      server_name _;
      root /var/www/app/public;
      index index.php index.html;

      location /health { return 200 'ok'; add_header Content-Type text/plain; }

      location / {
        try_files $uri $uri/ /index.php?$query_string;
      }

      location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
      }
    }
    NGINX

    ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
    rm -f /etc/nginx/sites-enabled/default
    systemctl enable --now nginx php8.2-fpm

    REGION="${var.region}"
    PREFIX="/${var.name}/laravel/"

    get_ssm () {
      aws ssm get-parameter --with-decryption --name "$1" --region "$REGION" | jq -r .Parameter.Value
    }

    APP_KEY=$(get_ssm "$${PREFIX}APP_KEY" || echo "")
    DB_HOST=$(get_ssm "$${PREFIX}DB_HOST")
    DB_NAME=$(get_ssm "$${PREFIX}DB_NAME")
    DB_USER=$(get_ssm "$${PREFIX}DB_USER")
    DB_SECRET_ARN=$(get_ssm "$${PREFIX}DB_SECRET_ARN")
    REDIS_HOST=$(get_ssm "$${PREFIX}REDIS_HOST")

    DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region "$REGION" \
      | jq -r '.SecretString | fromjson | .password')


    ##############################
    # CodeDeploy Agent (Ubuntu 22.04)
    ##############################
    if ! systemctl is-active --quiet codedeploy-agent; then
      echo "[codedeploy] installing agent..."
      apt-get update -y
      # ruby es requerido por el agente clásico
      DEBIAN_FRONTEND=noninteractive apt-get install -y ruby wget
      cd /tmp
      # instalador oficial para us-east-1
      wget -q https://aws-codedeploy-us-east-1.s3.us-east-1.amazonaws.com/latest/install -O install_codedeploy
      chmod +x install_codedeploy
      ./install_codedeploy auto || ./install_codedeploy auto
      systemctl enable codedeploy-agent
      systemctl restart codedeploy-agent
      echo "[codedeploy] agent installed"
    else
      echo "[codedeploy] agent already running"
    fi 

    # .env mínimo
    cat > /var/www/app/.env <<ENV
    APP_NAME=Laravel
    APP_ENV=production
    APP_KEY=$${APP_KEY}
    APP_DEBUG=false
    APP_URL=http://localhost

    LOG_CHANNEL=single
    LOG_LEVEL=info

    DB_CONNECTION=mysql
    DB_HOST=$${DB_HOST}
    DB_PORT=3306
    DB_DATABASE=$${DB_NAME}
    DB_USERNAME=$${DB_USER}
    DB_PASSWORD=$${DB_PASS}

    CACHE_DRIVER=redis
    QUEUE_CONNECTION=redis
    REDIS_HOST=$${REDIS_HOST}
    REDIS_PORT=6379
    ENV

    mkdir -p /var/www/app/public
    cat >/var/www/app/public/index.php <<'PHP'
    <?php
    echo "Laravel placeholder running (prod)";
    PHP

    chown -R www-data:www-data /var/www/app
    systemctl reload nginx
  EOF
  )

  lifecycle { create_before_destroy = true }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-app", env = "prod" }
  }
}

########################
# Auto Scaling Group
########################
resource "aws_autoscaling_group" "app" {
  name                      = "${var.name}-asg"
  max_size                  = 2
  min_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = module.vpc.public_subnets
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.app.arn]

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = true
  }
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 60
    }
  }

  lifecycle { create_before_destroy = true }
}

output "asg_name" { value = aws_autoscaling_group.app.name }

########################
# Bucket policy: OAC
########################
resource "aws_s3_bucket_policy" "frontend_oac" {
  bucket = module.s3_frontend.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowCloudFrontListBucketViaOAC",
        Effect    = "Allow",
        Principal = { Service = "cloudfront.amazonaws.com" },
        Action    = ["s3:ListBucket"],
        Resource  = module.s3_frontend.s3_bucket_arn,
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = module.cloudfront.cloudfront_distribution_arn
          }
        }
      },
      {
        Sid       = "AllowCloudFrontGetObjectViaOAC",
        Effect    = "Allow",
        Principal = { Service = "cloudfront.amazonaws.com" },
        Action    = ["s3:GetObject", "s3:GetObjectVersion"],
        Resource  = "${module.s3_frontend.s3_bucket_arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = module.cloudfront.cloudfront_distribution_arn
          }
        }
      }
    ]
  })
}

########################
# SG de RDS (solo desde la app en puerto 3306)
########################
resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS MySQL SG (prod)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from app SG"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { env = "prod" }
}

########################
# Subnet group (usa subnets de DB privadas)
########################
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = module.vpc.database_subnets
  tags       = { Name = "${var.name}-db-subnets", env = "prod" }
}

########################
# RDS MySQL 8.0 — Multi-AZ, cifrado, autoscaling
########################
resource "aws_db_instance" "mysql" {
  identifier = "${var.name}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_cls

  allocated_storage     = var.db_allocated
  max_allocated_storage = 1000

  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true # Secrets Manager mantiene la pass

  multi_az            = true
  publicly_accessible = false
  storage_encrypted   = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  backup_retention_period  = var.db_backup_days
  delete_automated_backups = true
  deletion_protection      = true

  maintenance_window = "Sun:01:00-Sun:03:00"
  backup_window      = "03:00-06:00"

  performance_insights_enabled = true

  tags = { env = "prod", stack = "massnexus", role = "rds" }
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

########################
# SSM Parameters (prod)
########################

# APP_KEY aleatorio
resource "random_password" "app_key" {
  length  = 32
  special = true
}

resource "aws_ssm_parameter" "app_key" {
  name  = "/${var.name}/laravel/APP_KEY"
  type  = "SecureString"
  value = random_password.app_key.result
}

resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.name}/laravel/DB_HOST"
  type  = "SecureString"
  value = aws_db_instance.mysql.address
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.name}/laravel/DB_NAME"
  type  = "SecureString"
  value = var.db_name
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/${var.name}/laravel/DB_USER"
  type  = "SecureString"
  value = var.db_username
}

resource "aws_ssm_parameter" "db_secret_arn" {
  name  = "/${var.name}/laravel/DB_SECRET_ARN"
  type  = "SecureString"
  value = aws_db_instance.mysql.master_user_secret[0].secret_arn
}

########################
# IAM inline policy para EC2: SSM + Secrets + Logs
########################
data "aws_iam_policy_document" "ec2_inline" {
  statement {
    sid    = "ReadSSMParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParameterHistory",
      "ssm:DescribeParameters"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadRDSSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [aws_db_instance.mysql.master_user_secret[0].secret_arn]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_inline" {
  name   = "${var.name}-ec2-inline"
  role   = aws_iam_role.ec2_role.id
  policy = data.aws_iam_policy_document.ec2_inline.json
}

########################
# SG de Redis (solo desde la app)
########################
resource "aws_security_group" "redis" {
  name        = "${var.name}-redis"
  description = "ElastiCache Redis SG (prod)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Redis from app SG"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { env = "prod" }
}

########################
# Subnet group de ElastiCache (privadas)
########################
resource "aws_elasticache_subnet_group" "redis" {
  name        = "${var.name}-redis-subnets"
  description = "Subnets privadas para Redis"
  subnet_ids  = module.vpc.private_subnets
}

########################
# Redis 7 - 1 nodo, cifrado
########################
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.name}-redis"
  description          = "Redis for ${var.name} (prod)"

  engine               = "redis"
  engine_version       = "7.0"
  parameter_group_name = "default.redis7"
  node_type            = "cache.t4g.micro" # ajustá cuando crezca
  num_cache_clusters   = 1                 # single node en prod inicial

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  security_group_ids = [aws_security_group.redis.id]
  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  port               = 6379

  tags = { env = "prod", stack = "massnexus", role = "redis" }
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

########################
# SSM: REDIS_HOST
########################
resource "aws_ssm_parameter" "redis_host" {
  name  = "/${var.name}/laravel/REDIS_HOST"
  type  = "SecureString"
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

########################
# Outputs útiles
########################
output "vpc_id" { value = module.vpc.vpc_id }
output "public_subnets" { value = module.vpc.public_subnets }
output "private_subnets" { value = module.vpc.private_subnets }
output "database_subnets" { value = module.vpc.database_subnets }
output "cloudfront_domain" { value = module.cloudfront.cloudfront_distribution_domain_name }
output "frontend_bucket" { value = module.s3_frontend.s3_bucket_id }


########################
# Outputs para validar en Cloudflare
########################
output "frontend_cert_validation_records" {
  description = "CNAMEs que debes crear en Cloudflare para validar el cert del frontend"
  value = [
    for dvo in aws_acm_certificate.frontend.domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ]
}

########################
# GitHub OIDC + Role (Frontend deploy)
########################

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "gh_front_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Reemplazá con tu repo frontend real (owner/repo)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:beatsmedia/yieldpro_front_tmp:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gh_front_role" {
  name               = "${var.name}-gh-frontend-deploy"
  assume_role_policy = data.aws_iam_policy_document.gh_front_trust.json
  tags               = { env = "prod", app = "frontend" }
}

data "aws_iam_policy_document" "gh_front_policy" {
  statement {
    sid    = "S3FrontendAccess"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      module.s3_frontend.s3_bucket_arn,
      "${module.s3_frontend.s3_bucket_arn}/*"
    ]
  }

  statement {
    sid       = "CloudFrontInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["*"]
  }

  statement {
    sid    = "CloudFrontListAndInvalidate"
    effect = "Allow"
    actions = [
      "cloudfront:ListDistributions",
      "cloudfront:CreateInvalidation"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "gh_front_policy" {
  name   = "${var.name}-gh-frontend-policy"
  policy = data.aws_iam_policy_document.gh_front_policy.json
}

resource "aws_iam_role_policy_attachment" "gh_front_attach" {
  role       = aws_iam_role.gh_front_role.name
  policy_arn = aws_iam_policy.gh_front_policy.arn
}

output "gh_front_role_arn" {
  value       = aws_iam_role.gh_front_role.arn
  description = "ARN del rol que asumirá GitHub Actions (frontend)"
}

output "cloudfront_distribution_id" {
  value       = module.cloudfront.cloudfront_distribution_id
  description = "ID de la distribución CloudFront de prod"
}


########################
# CodeDeploy: app + deployment group (prod)
########################

# S3 para artefactos de deploy del backend
resource "aws_s3_bucket" "backend_artifacts" {
  bucket        = "${var.name}-backend-artifacts"
  force_destroy = false
  tags          = { env = "prod", app = "backend" }
}

resource "aws_s3_bucket_versioning" "backend_artifacts" {
  bucket = aws_s3_bucket.backend_artifacts.id
  versioning_configuration { status = "Enabled" }
}

# Rol de servicio que usa CodeDeploy para operar sobre el ASG
data "aws_iam_policy_document" "codedeploy_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy_service" {
  name               = "${var.name}-codedeploy-service"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_trust.json
  tags               = { env = "prod" }
}

# Política administrada recomendada por AWS para CodeDeploy (EC2/On-Prem)
resource "aws_iam_role_policy_attachment" "codedeploy_managed" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# Aplicación CodeDeploy (backend)
resource "aws_codedeploy_app" "backend" {
  name             = "${var.name}-backend"
  compute_platform = "Server"
}

# Deployment Group que apunta a tu ASG de prod
resource "aws_codedeploy_deployment_group" "backend" {
  app_name              = aws_codedeploy_app.backend.name
  deployment_group_name = "${var.name}-backend-dg"
  service_role_arn      = aws_iam_role.codedeploy_service.arn

  autoscaling_groups = [aws_autoscaling_group.app.name]

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL" # podemos cambiar a ALL_AT_ONCE si preferís
    deployment_type   = "IN_PLACE"
  }

  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.app.name
    }
  }

  # No activamos blue/green por ahora; mantenemos simple (IN_PLACE)
  termination_hook_enabled = false
}

########################
# OIDC para GitHub (backend) — para subir bundle a S3 y lanzar deployments
########################

# Usa el mismo OIDC provider de GitHub que ya creamos para el frontend
# (si ya existe aws_iam_openid_connect_provider.github, no lo reprovisiones)

data "aws_iam_policy_document" "gh_back_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:beatsmedia/yieldpro_back_tmp:*"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gh_backend_role" {
  name               = "${var.name}-gh-backend-deploy"
  assume_role_policy = data.aws_iam_policy_document.gh_back_trust.json
  tags               = { env = "prod", app = "backend" }
}

# Permisos mínimos para:
# - subir el bundle al bucket de artefactos
# - crear deployments en CodeDeploy
data "aws_iam_policy_document" "gh_backend_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:HeadObject"
    ]
    resources = [
      "arn:aws:s3:::massnexus-prd-backend-artifacts",
      "arn:aws:s3:::massnexus-prd-backend-artifacts/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetApplicationRevision"
    ]
    resources = ["*"]
  }
}

# Permisos para que la instancia EC2 lea el artefacto de deploy desde S3
data "aws_iam_policy_document" "ec2_read_backend_artifacts" {
  statement {
    sid    = "ReadBackendArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.backend_artifacts.arn,
      "${aws_s3_bucket.backend_artifacts.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "ec2_read_backend_artifacts" {
  name   = "${var.name}-ec2-read-backend-artifacts"
  policy = data.aws_iam_policy_document.ec2_read_backend_artifacts.json
}


# 2) Derivar el NOMBRE del rol a partir del role_arn
locals {
  app_role_name = element(split("/", data.aws_iam_instance_profile.app.role_arn), 1)
}



# Busca el Instance Profile que usa el Launch Template
data "aws_iam_instance_profile" "app" {
  name = aws_launch_template.app.iam_instance_profile[0].name
}

# Adjunta la policy al rol real que usan las instancias EC2
resource "aws_iam_role_policy_attachment" "ec2_read_backend_artifacts_attach" {
  role       = local.app_role_name
  policy_arn = aws_iam_policy.ec2_read_backend_artifacts.arn
}

resource "aws_iam_policy" "gh_backend_policy" {
  name   = "${var.name}-gh-backend-policy"
  policy = data.aws_iam_policy_document.gh_backend_policy.json
}

resource "aws_iam_role_policy_attachment" "gh_backend_attach" {
  role       = aws_iam_role.gh_backend_role.name
  policy_arn = aws_iam_policy.gh_backend_policy.arn
}

########################
# Outputs útiles
########################
output "backend_artifacts_bucket" {
  value       = aws_s3_bucket.backend_artifacts.bucket
  description = "Bucket S3 para artefactos de deploy del backend"
}

output "codedeploy_app_name" {
  value       = aws_codedeploy_app.backend.name
  description = "Nombre de la aplicación CodeDeploy (backend)"
}

output "codedeploy_deployment_group" {
  value       = aws_codedeploy_deployment_group.backend.deployment_group_name
  description = "Deployment Group de CodeDeploy (backend)"
}

output "gh_backend_role_arn" {
  value       = aws_iam_role.gh_backend_role.arn
  description = "Rol que usará GitHub Actions (backend)"
}