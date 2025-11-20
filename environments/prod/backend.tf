terraform {
  backend "s3" {
    bucket         = "yp-test-tf-state" # Bucket de state remoto (creado en bootstrap)
    region         = "us-east-1"
    key            = "prod/terraform.tfstate" # State file de prod
    dynamodb_table = "tf-locks-yp-test"       # Tabla de locks (creada en bootstrap)
    encrypt        = true
  }
}