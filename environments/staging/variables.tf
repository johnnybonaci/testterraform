variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "massnexus-stg"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_allocated" {
  type    = number
  default = 20
}

variable "db_backup_days" {
  type    = number
  default = 7
}

variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0" # cámbialo por TU_IP/32, p.ej. "203.0.113.45/32"
}

variable "allowed_ips_staging" {
  type        = list(string)
  description = "IPs permitidas para acceder a staging (equipo de desarrollo)"
  default = [
    "181.92.77.33/32",     # IP actual Nico
    "190.19.143.121/32",   # IP oficina 1
    "200.123.128.225/32",  # IP oficina 2
    # Agregar más IPs del equipo aquí
  ]
}