########################
# Datos de AZs
########################
data "aws_availability_zones" "available" {}

########################
# VPC segura (2 AZs)
########################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1"

  name = var.name
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 0),
    cidrsubnet(var.vpc_cidr, 4, 1)
  ]
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 10),
    cidrsubnet(var.vpc_cidr, 4, 11)
  ]
  database_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 12),
    cidrsubnet(var.vpc_cidr, 4, 13)
  ]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Flow Logs: los activamos en el próximo paso con bucket central de logs
  enable_flow_log = false

  tags = {
    env   = "staging"
    stack = "massnexus"
  }
}

########################
# Bucket central de logs
########################
module "logs_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1"

  bucket = "${var.name}-logs" # ejemplo: massnexus-stg-logs
  acl    = "log-delivery-write"

  # Habilitar ACLs para CloudFront:
  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  # Bloqueo público
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id                                     = "logs"
      enabled                                = true
      abort_incomplete_multipart_upload_days = 7
      noncurrent_version_expiration          = { days = 30 }
      expiration                             = { days = 90 }
    }
  ]

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "logs"
  }
}

########################
# S3 del frontend (privado)
########################
module "s3_frontend" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1"

  bucket = "${var.name}-frontend" # ej: massnexus-stg-frontend
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

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "frontend"
  }
}


resource "aws_s3_bucket_policy" "frontend_oac" {
  bucket = module.s3_frontend.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowCloudFrontReadViaOAC",
        Effect    = "Allow",
        Principal = { Service = "cloudfront.amazonaws.com" },
        Action    = ["s3:GetObject"],
        Resource  = ["${module.s3_frontend.s3_bucket_arn}/*"],
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = module.cloudfront.cloudfront_distribution_arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name}-oac"
  description                       = "OAC for ${var.name} frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Política administrada de security headers (CloudFront)
data "aws_cloudfront_response_headers_policy" "managed_security" {
  name = "Managed-SecurityHeadersPolicy"
}

########################
# CloudFront con OAC apuntando al S3
########################
module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 5.0"

  comment             = "${var.name}-frontend"
  enabled             = true
  default_root_object = "index.html"
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"
  web_acl_id          = aws_wafv2_web_acl.cloudfront.arn

  # Definimos la OAC dentro del módulo (clave "s3")
  origin_access_control = {
    s3 = {
      description      = "OAC for ${var.name} frontend"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  # IMPORTANTE: 'origin' (singular), no 'origins'
  origin = {
    s3 = {
      domain_name              = module.s3_frontend.s3_bucket_bucket_regional_domain_name
      origin_id                = "s3-origin"
      s3_origin_config         = {} # vacío cuando usás OAC
      origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
      origin_access_control    = "s3" # referenciamos la OAC definida arriba
    }
  }

  default_cache_behavior = {
    target_origin_id           = "s3-origin"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.managed_security.id
  }

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

  viewer_certificate = {
    cloudfront_default_certificate = true
  }

  logging_config = {
    bucket          = replace(module.logs_bucket.s3_bucket_bucket_domain_name, "https://", "")
    prefix          = "cloudfront/"
    include_cookies = false
  }

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "cdn"
  }
}

########################
# Security Groups
########################

# SG del ALB: expone solo HTTP 80 por ahora
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB SG"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "HTTP from allowed IP only"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = [var.allowed_cidr]
    ipv6_cidr_blocks = []
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { env = "staging" }
}

# SG de la app: solo recibe del ALB (80). Más adelante si querés TLS interno, abrimos 443 también.
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "App SG"
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

  tags = { env = "staging" }
}


########################
# ALB nativo (HTTP por ahora)
########################

# 1) Load Balancer
resource "aws_lb" "app" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "alb"
  }
}

# 2) Target Group (HTTP -> puerto 80 en las instancias)
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
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
  }

  deregistration_delay = 15

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "alb-tg"
  }
}

# 3) Listener HTTP 80 -> forward al Target Group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Output del DNS del ALB
output "alb_dns_name" {
  value = aws_lb.app.dns_name
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
# Política adicional para la instancia
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
# AMI Ubuntu 22.04 (jammy)
########################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

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

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    security_groups = [aws_security_group.app.id]
    # sin public IP (está en subred privada a través del ASG)
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

    # AWS CLI v2
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

    # Node.js 20 LTS
    if ! command -v node &>/dev/null; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
    fi

    # Directorios de la aplicación
    mkdir -p /var/www/app /var/log/app

    # Configuración PHP-FPM optimizada
    cat > /etc/php/8.3/fpm/pool.d/www.conf <<'PHPFPM'
    [www]
    user = www-data
    group = www-data
    listen = /run/php/php8.3-fpm.sock
    listen.owner = www-data
    listen.group = www-data
    listen.mode = 0660

    pm = dynamic
    pm.max_children = 30
    pm.start_servers = 3
    pm.min_spare_servers = 2
    pm.max_spare_servers = 10
    pm.max_requests = 500

    php_admin_value[error_log] = /var/log/php8.3-fpm.log
    php_admin_flag[log_errors] = on
    php_value[session.save_handler] = files
    php_value[session.save_path] = /var/lib/php/sessions
    PHPFPM

    # Optimizaciones PHP para Laravel
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

      # Health check endpoint
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
    numprocs=1
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

    # Generar .env de Laravel
    cat > /var/www/app/.env <<ENV
    APP_NAME=Laravel
    APP_ENV=staging
    APP_KEY=$${APP_KEY}
    APP_DEBUG=true
    APP_URL=http://localhost

    LOG_CHANNEL=stack
    LOG_LEVEL=debug

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

    # Placeholder inicial
    mkdir -p /var/www/app/public
    cat >/var/www/app/public/index.php <<'PHP'
    <?php
    phpinfo();
    echo "\n\n<!-- Laravel 12 / PHP 8.3 Ready (staging) -->";
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

  lifecycle {
    create_before_destroy = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name}-app"
      env  = "staging"
    }
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
  vpc_zone_identifier       = module.vpc.private_subnets
  health_check_type         = "EC2"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 90
    }
    # triggers = ["launch_template"]  # <-- quitar esta línea
  }

  target_group_arns = [aws_lb_target_group.app.arn]

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

########################
# SG de la base de datos (solo app -> 3306)
########################
resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS MySQL SG"
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

  tags = { env = "staging" }
}

########################
# SG de Redis (solo app -> 6379)
########################
resource "aws_security_group" "redis" {
  name        = "${var.name}-redis"
  description = "ElastiCache Redis SG"
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

  tags = { env = "staging" }
}

########################
# Subnet group de ElastiCache
########################
resource "aws_elasticache_subnet_group" "redis" {
  name        = "${var.name}-redis-subnets"
  subnet_ids  = module.vpc.private_subnets
  description = "Subnets privadas para Redis"
}

########################
# Redis 7 - 1 nodo, cifrado + AUTH
########################
resource "random_password" "redis_auth" {
  length  = 32
  special = false # Redis AUTH no soporta caracteres especiales
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.name}-redis"
  description                = "Redis for ${var.name}"
  engine                     = "redis"
  engine_version             = "7.0"
  parameter_group_name       = "default.redis7"
  node_type                  = "cache.t4g.micro" # Suficiente para staging
  num_cache_clusters         = 1
  multi_az_enabled           = false
  automatic_failover_enabled = false

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token_enabled         = true
  auth_token                 = random_password.redis_auth.result

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  port = 6379

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "redis"
  }
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

########################
# Subnet group de RDS (usa database_subnets)
########################
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = module.vpc.database_subnets
  tags = {
    Name = "${var.name}-db-subnets"
    env  = "staging"
  }
}

########################
# RDS MySQL 8.0 (single-AZ para staging)
########################
resource "aws_db_instance" "mysql" {
  identifier = "${var.name}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t4g.small"

  allocated_storage     = var.db_allocated
  max_allocated_storage = 200

  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true # Secrets Manager maneja la pass

  multi_az            = false
  publicly_accessible = false

  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  backup_retention_period  = var.db_backup_days
  delete_automated_backups = true
  skip_final_snapshot      = true  # Temporal para destroy
  # final_snapshot_identifier = "${var.name}-mysql-final-snapshot"
  deletion_protection      = false

  maintenance_window = "Sun:01:00-Sun:03:00"
  backup_window      = "03:00-06:00"

  tags = {
    env   = "staging"
    stack = "massnexus"
    role  = "rds"
  }
}

########################
# Outputs de RDS
########################
output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

########################
# SSM: REDIS_HOST y REDIS_PASSWORD
########################
resource "aws_ssm_parameter" "redis_host" {
  name  = "/${var.name}/laravel/REDIS_HOST"
  type  = "SecureString"
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

resource "aws_ssm_parameter" "redis_password" {
  name  = "/${var.name}/laravel/REDIS_PASSWORD"
  type  = "SecureString"
  value = random_password.redis_auth.result
}

########################
# SSM Parameters (para .env de Laravel)
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

# Host/DB/User (la pass la leemos desde Secrets Manager)
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

# ARN del secreto administrado por RDS (contiene {username,password})
resource "aws_ssm_parameter" "db_secret_arn" {
  name  = "/${var.name}/laravel/DB_SECRET_ARN"
  type  = "SecureString"
  value = aws_db_instance.mysql.master_user_secret[0].secret_arn
}


output "logs_bucket_name" {
  value = module.logs_bucket.s3_bucket_id
}

########################
# Outputs
########################
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "database_subnets" {
  value = module.vpc.database_subnets
}

output "cloudfront_domain" {
  value = module.cloudfront.cloudfront_distribution_domain_name
}

output "frontend_bucket" {
  value = module.s3_frontend.s3_bucket_id
}