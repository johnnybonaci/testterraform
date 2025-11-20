terraform {
  backend "s3" {
    bucket         = "yp-test-tf-state" # Mismo bucket de state remoto que prod
    region         = "us-east-1"
    key            = "staging/terraform.tfstate" # State file separado para staging
    dynamodb_table = "tf-locks-yp-test"          # Misma tabla de locks
    encrypt        = true
  }
}
