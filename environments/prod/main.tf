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

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = false
  one_nat_gateway_per_az = var.enable_nat_gateway # Solo si está habilitado

  enable_dns_hostnames = true
  enable_dns_support   = true

  # (Activamos Flow Logs cuando creemos el bucket de logs de prod)
  enable_flow_log = false

  tags = {
    env   = "prod"
    stack = "yieldpro"
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
    stack = "yieldpro"
    role  = "logs"
  }
}

output "logs_bucket_name" {
  value = module.logs_bucket.s3_bucket_id
}

########################
# KMS Key para cifrado de CloudWatch Logs
########################
resource "aws_kms_key" "cloudwatch_logs" {
  description             = "KMS key for CloudWatch Logs encryption (${var.name})"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    env   = "prod"
    stack = "yieldpro"
    role  = "logs-encryption"
  }
}

resource "aws_kms_alias" "cloudwatch_logs" {
  name          = "alias/${var.name}-cloudwatch-logs"
  target_key_id = aws_kms_key.cloudwatch_logs.key_id
}

# Policy para permitir que CloudWatch Logs y SSM usen la key
data "aws_iam_policy_document" "cloudwatch_logs_kms" {
  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "Allow CloudWatch Logs"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey"
    ]
    resources = ["*"]
    # Condition removed to avoid chicken-egg problem with log group creation
  }

  statement {
    sid    = "Allow SSM Parameters"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ssm.${var.region}.amazonaws.com"]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key_policy" "cloudwatch_logs" {
  key_id = aws_kms_key.cloudwatch_logs.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_kms.json
}

data "aws_caller_identity" "current" {}

########################
# VPC Flow Logs a CloudWatch (prod)
########################
resource "aws_cloudwatch_log_group" "vpc_fl" {
  name              = "/vpc/${var.name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn
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
  log_destination      = aws_cloudwatch_log_group.vpc_fl.arn
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

  tags = { env = "prod", stack = "yieldpro", role = "frontend" }
}

########################
# CloudFront Origin Access Control
# ✅ STAGE 2: Descomentado - Usado por CloudFront
########################
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name}-oac"
  description                       = "OAC for ${var.name} frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Data sources needed by CloudFront (keep these for reference, but won't be used in Stage 1)
data "aws_cloudfront_cache_policy" "managed_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "managed_security" {
  name = "Managed-SecurityHeadersPolicy"
}


########################
# CloudFront (prod) con OAC
# ✅ STAGE 2: Descomentado - Certificados validados
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
    target_origin_id           = "s3-origin"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.managed_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.managed_security.id
    use_forwarded_values       = false
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

  tags = { env = "prod", stack = "yieldpro", role = "cdn" }
}

########################
# ACM para CloudFront (DNS validation)
########################
resource "aws_acm_certificate" "frontend" {
  domain_name       = var.frontend_domain_name
  validation_method = "DNS"

  # CloudFront exige ACM en us-east-1
  provider = aws.us_east_1

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
    description = "HTTPS from allowed IPs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips_alb
  }

  ingress {
    description = "HTTP from allowed IPs (redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips_alb
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

  tags = { env = "prod", stack = "yieldpro", role = "alb" }
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

  tags = { env = "prod", stack = "yieldpro", role = "alb-tg" }
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
# ✅ STAGE 2: Descomentado - Certificado backend validado
########################
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.backend.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

########################
# Redirección 80 -> 443
# ✅ STAGE 2: Descomentado - HTTPS listener activo
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
# Certificado ACM ya está definido arriba como aws_acm_certificate.backend
# No necesitamos duplicados
########################


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
  instance_type = "c6i.large" # 2 vCPU dedicados, 4GB RAM - mejor performance que t3

  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }

  network_interfaces {
    security_groups             = [aws_security_group.app.id]
    associate_public_ip_address = !var.use_private_subnets_for_ec2 # Solo si está en subnets públicas
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    # Log de inicio
    echo "[$(date)] Starting EC2 bootstrap for Laravel 12 / PHP 8.3" | tee -a /var/log/user-data.log

    # Paquetes base
    apt-get update -y
    apt-get install -y nginx software-properties-common unzip jq curl wget git ca-certificates

    # AWS CLI v2 (más reciente y mejor performance)
    if ! command -v aws &>/dev/null; then
      cd /tmp
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
      unzip -q awscliv2.zip
      ./aws/install
      rm -rf aws awscliv2.zip
    fi

    # PHP 8.3 + extensiones para Laravel 12
    add-apt-repository ppa:ondrej/php -y
    apt-get update -y
    apt-get install -y \
      php8.3 \
      php8.3-fpm \
      php8.3-cli \
      php8.3-mysql \
      php8.3-pgsql \
      php8.3-xml \
      php8.3-curl \
      php8.3-mbstring \
      php8.3-zip \
      php8.3-bcmath \
      php8.3-gd \
      php8.3-intl \
      php8.3-redis \
      php8.3-opcache

    # Composer 2.x
    if ! command -v composer &>/dev/null; then
      curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --2
      chmod +x /usr/local/bin/composer
    fi

    # Node.js 20 LTS (para compilar assets si es necesario)
    if ! command -v node &>/dev/null; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
    fi

    # Directorios de la aplicación
    mkdir -p /var/www/app /var/log/app

    # Configuración PHP-FPM optimizada para producción
    cat > /etc/php/8.3/fpm/pool.d/www.conf <<'PHPFPM'
    [www]
    user = www-data
    group = www-data
    listen = /run/php/php8.3-fpm.sock
    listen.owner = www-data
    listen.group = www-data
    listen.mode = 0660

    pm = dynamic
    pm.max_children = 50
    pm.start_servers = 5
    pm.min_spare_servers = 5
    pm.max_spare_servers = 35
    pm.max_requests = 500

    php_admin_value[error_log] = /var/log/php8.3-fpm.log
    php_admin_flag[log_errors] = on
    php_value[session.save_handler] = files
    php_value[session.save_path] = /var/lib/php/sessions
    PHPFPM

    # Optimizaciones PHP para Laravel (php.ini)
    cat > /etc/php/8.3/fpm/conf.d/99-laravel.ini <<'PHPINI'
    memory_limit = 256M
    upload_max_filesize = 64M
    post_max_size = 64M
    max_execution_time = 300
    max_input_time = 300
    opcache.enable=1
    opcache.memory_consumption=128
    opcache.interned_strings_buffer=8
    opcache.max_accelerated_files=10000
    opcache.revalidate_freq=2
    opcache.fast_shutdown=1
    PHPINI

    # Nginx vhost para Laravel
    cat >/etc/nginx/sites-available/app <<'NGINX'
    server {
      listen 80 default_server;
      server_name _;
      root /var/www/app/public;
      index index.php index.html;

      client_max_body_size 64M;

      # Health check endpoint (no pasa por Laravel)
      location /health {
        access_log off;
        return 200 'ok';
        add_header Content-Type text/plain;
      }

      # Laravel routes
      location / {
        try_files $uri $uri/ /index.php?$query_string;
      }

      # PHP-FPM
      location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $realpath_root;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
      }

      # Deny access to hidden files
      location ~ /\. {
        deny all;
      }
    }
    NGINX

    ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
    rm -f /etc/nginx/sites-enabled/default

    # Supervisor para Laravel Queue Workers
    apt-get install -y supervisor

    # Configurar worker de Laravel
    cat > /etc/supervisor/conf.d/laravel-worker.conf <<'SUPERVISOR'
    [program:laravel-worker]
    process_name=%(program_name)s_%(process_num)02d
    command=php /var/www/app/artisan queue:work redis --sleep=3 --tries=3 --max-time=3600 --timeout=60
    autostart=true
    autorestart=true
    stopasgroup=true
    killasgroup=true
    user=www-data
    numprocs=2
    redirect_stderr=true
    stdout_logfile=/var/log/app/worker.log
    stopwaitsecs=3600
    SUPERVISOR

    # Habilitar servicios
    systemctl enable nginx php8.3-fpm supervisor
    systemctl restart php8.3-fpm nginx supervisor

    # Obtener configuración desde SSM y Secrets Manager
    REGION="${var.region}"
    PREFIX="/${var.name}/laravel/"

    get_ssm () {
      aws ssm get-parameter --with-decryption --name "$1" --region "$REGION" 2>/dev/null | jq -r .Parameter.Value || echo ""
    }

    echo "[$(date)] Fetching configuration from SSM/Secrets Manager..." | tee -a /var/log/user-data.log

    APP_KEY=$(get_ssm "$${PREFIX}APP_KEY")
    DB_HOST=$(get_ssm "$${PREFIX}DB_HOST")
    DB_NAME=$(get_ssm "$${PREFIX}DB_NAME")
    DB_USER=$(get_ssm "$${PREFIX}DB_USER")
    DB_SECRET_ARN=$(get_ssm "$${PREFIX}DB_SECRET_ARN")
    REDIS_HOST=$(get_ssm "$${PREFIX}REDIS_HOST")
    REDIS_PASSWORD=$(get_ssm "$${PREFIX}REDIS_PASSWORD")

    if [ -z "$DB_SECRET_ARN" ]; then
      echo "[ERROR] DB_SECRET_ARN not found in SSM" | tee -a /var/log/user-data.log
      exit 1
    fi

    DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region "$REGION" \
      | jq -r '.SecretString | fromjson | .password')

    # CodeDeploy Agent (Ubuntu 22.04)
    if ! systemctl is-active --quiet codedeploy-agent; then
      echo "[$(date)] Installing CodeDeploy agent..." | tee -a /var/log/user-data.log
      apt-get install -y ruby-full wget
      cd /tmp
      wget -q https://aws-codedeploy-${var.region}.s3.${var.region}.amazonaws.com/latest/install -O install_codedeploy
      chmod +x install_codedeploy
      ./install_codedeploy auto
      systemctl enable codedeploy-agent
      systemctl start codedeploy-agent
      echo "[$(date)] CodeDeploy agent installed" | tee -a /var/log/user-data.log
    fi

    # Generar .env de Laravel
    cat > /var/www/app/.env <<ENV
    APP_NAME=Laravel
    APP_ENV=production
    APP_KEY=$${APP_KEY}
    APP_DEBUG=false
    APP_URL=https://${var.backend_domain_name}

    LOG_CHANNEL=stack
    LOG_LEVEL=error

    DB_CONNECTION=mysql
    DB_HOST=$${DB_HOST}
    DB_PORT=3306
    DB_DATABASE=$${DB_NAME}
    DB_USERNAME=$${DB_USER}
    DB_PASSWORD=$${DB_PASS}

    BROADCAST_DRIVER=log
    CACHE_DRIVER=redis
    FILESYSTEM_DISK=local
    QUEUE_CONNECTION=redis
    SESSION_DRIVER=redis

    REDIS_HOST=$${REDIS_HOST}
    REDIS_PASSWORD=$${REDIS_PASSWORD}
    REDIS_PORT=6379

    AWS_DEFAULT_REGION=${var.region}
    AWS_BUCKET=${var.name}-storage
    ENV

    # Placeholder inicial (será reemplazado por CodeDeploy)
    mkdir -p /var/www/app/public
    cat >/var/www/app/public/index.php <<'PHP'
    <?php
    phpinfo();
    echo "\n\n<!-- Laravel 12 / PHP 8.3 Ready (prod) -->";
    PHP

    # Permisos
    chown -R www-data:www-data /var/www/app
    chmod -R 755 /var/www/app
    chmod -R 775 /var/www/app/storage 2>/dev/null || true
    chmod -R 775 /var/www/app/bootstrap/cache 2>/dev/null || true

    systemctl reload nginx
    echo "[$(date)] Bootstrap completed successfully" | tee -a /var/log/user-data.log
  EOF
  )

  lifecycle { create_before_destroy = true }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-app", env = "prod" }
  }
}

########################
# Auto Scaling Group - Alta disponibilidad con mínimo 2 instancias
########################
resource "aws_autoscaling_group" "app" {
  name                      = "${var.name}-asg"
  max_size                  = 4 # Escala hasta 4 instancias bajo carga
  min_size                  = 2 # Siempre 2 instancias corriendo (HA)
  desired_capacity          = 2 # Iniciar con 2 instancias en diferentes AZs
  vpc_zone_identifier       = var.use_private_subnets_for_ec2 ? module.vpc.private_subnets : module.vpc.public_subnets
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
  tag {
    key                 = "env"
    value               = "prod"
    propagate_at_launch = true
  }
  tag {
    key                 = "stack"
    value               = "massnexus"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50 # Siempre mantiene al menos 1 instancia healthy durante updates
      instance_warmup        = 60
    }
  }

  lifecycle { create_before_destroy = true }
}

output "asg_name" { value = aws_autoscaling_group.app.name }

########################
# Bucket policy: OAC
# ✅ STAGE 2: Descomentado - CloudFront distribution creada
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

  tags = { env = "prod", stack = "yieldpro", role = "rds" }
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
  name   = "/${var.name}/laravel/APP_KEY"
  type   = "SecureString"
  value  = random_password.app_key.result
  key_id = aws_kms_key.cloudwatch_logs.id
}

resource "aws_ssm_parameter" "db_host" {
  name   = "/${var.name}/laravel/DB_HOST"
  type   = "SecureString"
  value  = aws_db_instance.mysql.address
  key_id = aws_kms_key.cloudwatch_logs.id
}

resource "aws_ssm_parameter" "db_name" {
  name   = "/${var.name}/laravel/DB_NAME"
  type   = "SecureString"
  value  = var.db_name
  key_id = aws_kms_key.cloudwatch_logs.id
}

resource "aws_ssm_parameter" "db_user" {
  name   = "/${var.name}/laravel/DB_USER"
  type   = "SecureString"
  value  = var.db_username
  key_id = aws_kms_key.cloudwatch_logs.id
}

resource "aws_ssm_parameter" "db_secret_arn" {
  name   = "/${var.name}/laravel/DB_SECRET_ARN"
  type   = "SecureString"
  value  = aws_db_instance.mysql.master_user_secret[0].secret_arn
  key_id = aws_kms_key.cloudwatch_logs.id
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
# Redis 7 - Multi-AZ con failover automático, cifrado + AUTH
########################
resource "random_password" "redis_auth" {
  length  = 32
  special = false # Redis AUTH no soporta caracteres especiales
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.name}-redis"
  description          = "Redis for ${var.name} (prod) - Multi-AZ HA"

  engine               = "redis"
  engine_version       = "7.0"
  parameter_group_name = "default.redis7"
  node_type            = "cache.t4g.small" # 1.37GB - capacidad adecuada para sessions + cache + queues
  num_cache_clusters   = 3                 # 1 primary + 2 replicas en diferentes AZs

  # Alta disponibilidad
  automatic_failover_enabled = true # Failover automático si primary falla
  multi_az_enabled           = true # Distribuir replicas en diferentes AZs

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result # AUTH se habilita automáticamente al proporcionar auth_token

  security_group_ids = [aws_security_group.redis.id]
  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  port               = 6379

  # Mantenimiento y snapshots
  snapshot_retention_limit = 5             # Retener 5 snapshots diarios
  snapshot_window          = "03:00-05:00" # Ventana de backup
  maintenance_window       = "sun:05:00-sun:07:00"

  tags = { env = "prod", stack = "yieldpro", role = "redis-ha" }
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

########################
# SSM: REDIS_HOST y REDIS_PASSWORD
########################
resource "aws_ssm_parameter" "redis_host" {
  name   = "/${var.name}/laravel/REDIS_HOST"
  type   = "SecureString"
  value  = aws_elasticache_replication_group.redis.primary_endpoint_address
  key_id = aws_kms_key.cloudwatch_logs.id
}

resource "aws_ssm_parameter" "redis_password" {
  name   = "/${var.name}/laravel/REDIS_PASSWORD"
  type   = "SecureString"
  value  = random_password.redis_auth.result
  key_id = aws_kms_key.cloudwatch_logs.id
}

########################
# Outputs útiles
########################
output "vpc_id" { value = module.vpc.vpc_id }
output "public_subnets" { value = module.vpc.public_subnets }
output "private_subnets" { value = module.vpc.private_subnets }
output "database_subnets" { value = module.vpc.database_subnets }
# ⚠️ STAGE 2: Output comentado - CloudFront no existe aún
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

# ⚠️ STAGE 2: Output  - CloudFront no existe aún
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

# Lifecycle policy para expirar artifacts antiguos y reducir costos
resource "aws_s3_bucket_lifecycle_configuration" "backend_artifacts" {
  bucket = aws_s3_bucket.backend_artifacts.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    filter {}

    # Eliminar artifacts después de 30 días
    expiration {
      days = 30
    }

    # Eliminar versiones no-current después de 7 días
    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    # Abortar multipart uploads incompletos después de 7 días
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
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
      values = [
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
      aws_s3_bucket.backend_artifacts.arn,
      "${aws_s3_bucket.backend_artifacts.arn}/*"
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
