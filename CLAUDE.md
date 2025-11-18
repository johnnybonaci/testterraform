# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Terraform infrastructure code for a multi-environment AWS deployment supporting a Laravel application with separate frontend and backend infrastructure. The project is named "massnexus" and uses a three-tier architecture with VPC, compute (EC2 Auto Scaling), database (RDS MySQL), caching (ElastiCache Redis), and CDN (CloudFront).

## Repository Structure

```
terraform/
├── 0-bootstrap/
│   └── remote-state/          # S3 backend + DynamoDB lock table setup
│       ├── main.tf            # Creates state bucket & lock table
│       ├── variables.tf       # region, bucket name, table name
│       └── outputs.tf
└── environments/
    ├── prod/                  # Production environment
    │   ├── backend.tf         # S3 backend configuration
    │   ├── providers.tf       # AWS provider (Terraform ~> 1.6.0, AWS ~> 5.60)
    │   ├── variables.tf       # Environment-specific variables
    │   └── main.tf            # All infrastructure resources
    └── staging/               # Staging environment
        ├── backend.tf
        ├── providers.tf
        ├── variables.tf
        └── main.tf
```

## Infrastructure Architecture

### Environment Differences

**Staging (`massnexus-stg`)**:
- VPC: 10.0.0.0/16 with NAT Gateways (one per AZ)
- RDS: Single-AZ, db.t4g.small, 20GB storage
- Redis: Single node, cache.t4g.micro, no Multi-AZ
- CloudFront: Default certificate, WAF enabled with AWS managed rules
- ALB: HTTP only (port 80)
- EC2: Instances in private subnets

**Production (`massnexus-prd`)**:
- VPC: 10.0.0.0/16 with /21 subnets (newbits=5) but NO NAT Gateways
- VPC Endpoints: S3 (Gateway), SSM, EC2Messages, SSMMessages, Logs, KMS (Interface endpoints for private subnet access without NAT)
- RDS: Multi-AZ, db.t4g.medium, 50GB storage, deletion protection enabled
- Redis: Single node with encryption at rest and in transit
- CloudFront: Custom ACM certificate for `yieldpro.massnexus.com`, OAC for S3 access
- ALB: HTTPS (port 443) with ACM cert + HTTP redirect to HTTPS
- EC2: Instances in public subnets (associate_public_ip_address = true) due to no NAT Gateway
- CodeDeploy: Backend deployment automation with S3 artifacts bucket
- GitHub OIDC: Roles for both frontend and backend deployments

### Key Infrastructure Components

1. **VPC Layout**:
   - 2 Availability Zones
   - Public subnets (CIDR offsets 0, 1)
   - Private subnets (CIDR offsets 10, 11)
   - Database subnets (CIDR offsets 20, 21 in prod; 12, 13 in staging)

2. **Frontend Stack**:
   - S3 bucket (private, versioned, encrypted)
   - CloudFront distribution with Origin Access Control (OAC)
   - Logs to central logs bucket with 90-day lifecycle
   - GitHub OIDC role for CI/CD deployments

3. **Backend Stack**:
   - Auto Scaling Group (min: 1, max: 2) with rolling instance refresh
   - Launch Template: Ubuntu 22.04 with Nginx + PHP 8.2-FPM
   - Application Load Balancer with target group health checks
   - CodeDeploy application and deployment group (prod only)
   - GitHub OIDC role for CI/CD deployments (prod only)

4. **Data Layer**:
   - RDS MySQL 8.0 with automatic storage scaling (max 1000GB prod, 200GB staging)
   - ElastiCache Redis 7.0 with encryption
   - All passwords managed via AWS Secrets Manager
   - Configuration stored in SSM Parameter Store (SecureString)

5. **Security**:
   - Security groups restrict traffic: ALB → App → DB/Redis
   - Prod ALB restricted to specific IPs (200.123.128.225/32, 190.19.143.121/32)
   - All S3 buckets encrypted (AES256), versioned, public access blocked
   - VPC Flow Logs to CloudWatch (prod only)
   - IAM roles follow least privilege (SSM for EC2, specific S3/CloudFront permissions for GitHub)

## Common Terraform Commands

### Initial Setup (One-Time Bootstrap)

```bash
# 1. Create remote state infrastructure (S3 + DynamoDB)
cd 0-bootstrap/remote-state
terraform init
terraform plan -var="state_bucket_name=massnexus-tf-state-nico" -var="lock_table_name=tf-locks-massnexus"
terraform apply -var="state_bucket_name=massnexus-tf-state-nico" -var="lock_table_name=tf-locks-massnexus"
cd ../..
```

### Working with Environments

```bash
# Navigate to environment
cd environments/staging  # or environments/prod

# Initialize (first time or after provider changes)
terraform init

# Plan changes
terraform plan

# Apply changes
terraform apply

# Refresh state from actual AWS resources
terraform refresh

# Show current state
terraform show

# List all resources
terraform state list

# Show specific resource
terraform state show aws_lb.app
```

### Working with Specific Resources

```bash
# Target a specific resource for plan/apply
terraform plan -target=aws_autoscaling_group.app
terraform apply -target=aws_db_instance.mysql

# Taint a resource to force replacement on next apply
terraform taint aws_launch_template.app

# Import existing AWS resource
terraform import aws_lb.app <alb-arn>

# Remove resource from state without destroying
terraform state rm aws_security_group.app
```

### Output and Debugging

```bash
# Show all outputs
terraform output

# Show specific output
terraform output alb_dns_name
terraform output cloudfront_domain

# Enable detailed logging
export TF_LOG=DEBUG
terraform plan

# Validate configuration syntax
terraform validate

# Format code
terraform fmt -recursive
```

### Deployment Workflow

```bash
# 1. Make changes to .tf files
# 2. Validate syntax
terraform validate

# 3. Review plan
terraform plan -out=tfplan

# 4. Apply saved plan
terraform apply tfplan

# 5. Verify outputs
terraform output
```

## Important Configuration Details

### SSM Parameter Store Structure

All Laravel environment variables are stored in SSM with the pattern:
```
/<environment-name>/laravel/<KEY>
```

**Prod Parameters** (`/massnexus-prd/laravel/`):
- `APP_KEY` - Auto-generated 32-char random password
- `DB_HOST` - RDS endpoint
- `DB_NAME` - Database name (default: "app")
- `DB_USER` - Database username (default: "appuser")
- `DB_SECRET_ARN` - ARN pointing to Secrets Manager for password
- `REDIS_HOST` - ElastiCache primary endpoint

**Staging Parameters** (`/massnexus-stg/laravel/`): Same structure

### User Data Bootstrap Process

EC2 instances auto-configure on launch via user_data script:
1. Install Nginx, PHP 8.2-FPM, AWS CLI
2. Configure Nginx with Laravel public root
3. Fetch configuration from SSM Parameter Store
4. Retrieve DB password from Secrets Manager using ARN from SSM
5. Generate `.env` file at `/var/www/app/.env`
6. Install CodeDeploy agent (prod only)
7. Create placeholder Laravel app at `/var/www/app/public/index.php`

### Health Check Configuration

**Staging**:
- Path: `/health`
- Expected: 200
- Interval: 30s

**Prod**:
- Path: `/` (changed from `/health`)
- Expected: 200-399
- Interval: 15s

### GitHub Actions Integration

**Frontend Deployments** (both environments in prod):
- OIDC Role ARN: `aws_iam_role.gh_front_role.arn`
- Permissions: S3 upload to frontend bucket, CloudFront invalidation
- Repo: `beatsmedia/yieldpro_front` (main branch)

**Backend Deployments** (prod only):
- OIDC Role ARN: `aws_iam_role.gh_backend_role.arn`
- Permissions: S3 upload to artifacts bucket, CodeDeploy trigger
- Repo: `beatsmedia/yieldpro` (any branch)
- Artifacts bucket: `massnexus-prd-backend-artifacts`

### CloudFront + ACM Certificate Validation

**Prod Frontend**: Requires DNS validation in Cloudflare for `yieldpro.massnexus.com`
```bash
terraform output frontend_cert_validation_records
# Create CNAME records in Cloudflare DNS
```

**Prod Backend**: Requires DNS validation in GoDaddy for `ypback.massnexus.com`
```bash
terraform output backend_cert_validation_records
# Create CNAME records in GoDaddy DNS
```

## Troubleshooting Common Issues

### EC2 Instances Not Healthy in Target Group

1. Check security group allows ALB → App (port 80)
2. Verify health check path returns expected status code
3. SSH via SSM Session Manager: `aws ssm start-session --target <instance-id>`
4. Check Nginx logs: `sudo journalctl -u nginx -f`
5. Verify `.env` file created: `cat /var/www/app/.env`

### RDS Connection Failures

1. Verify security group allows App → DB (port 3306)
2. Check SSM parameters exist and are readable by EC2 role
3. Verify Secrets Manager password retrieval works
4. Test from EC2: `mysql -h <rds-endpoint> -u appuser -p`

### Terraform State Lock

If state is locked:
```bash
# Force unlock (use lock ID from error message)
terraform force-unlock <lock-id>
```

### Launch Template Changes Not Applying

Auto Scaling Group uses `$Latest` version but doesn't auto-refresh. To deploy:
```bash
# Trigger instance refresh manually
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name massnexus-prd-asg \
  --preferences MinHealthyPercentage=50,InstanceWarmup=60
```

Or update ASG to force new instances:
```bash
terraform taint aws_autoscaling_group.app
terraform apply
```

### Prod-Specific: No NAT Gateway - VPC Endpoints Required

Prod has no NAT Gateway to save costs. Private subnet instances access AWS services via VPC Endpoints:
- S3: Gateway endpoint (free)
- SSM, EC2Messages, SSMMessages, Logs, KMS: Interface endpoints (~$0.01/hr each)

If adding new AWS service dependencies, ensure VPC endpoint exists or instances can't reach the service.

## Important Constraints

1. **Prod ALB IP Restrictions**: Only `200.123.128.225/32` and `190.19.143.121/32` can access. Update `aws_security_group.alb` to add IPs.

2. **Hardcoded Certificate ARN**: Prod HTTPS listener uses hardcoded cert ARN:
   ```hcl
   certificate_arn = "arn:aws:acm:us-east-1:838108223027:certificate/76a7501d-f39c-4b68-8a66-f4db5fde1925"
   ```
   This should be replaced with `aws_acm_certificate.backend.arn` for proper tracking.

3. **Public Subnets for Prod EC2**: Due to no NAT Gateway, prod EC2 instances are in public subnets with `associate_public_ip_address = true`. This is temporary until NAT is enabled.

4. **CodeDeploy Role Permissions**: The EC2 instance role needs read access to `massnexus-prd-backend-artifacts` S3 bucket for CodeDeploy to work.

5. **State File Location**: Both environments share the same S3 bucket but different keys:
   - Prod: `prod/terraform.tfstate`
   - Staging: `staging/terraform.tfstate`
