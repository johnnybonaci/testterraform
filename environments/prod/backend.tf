terraform {
  backend "s3" {
    bucket         = "massnexus-tf-state-nico" # tu bucket de state
    region         = "us-east-1"
    key            = "prod/terraform.tfstate" # <- distinto a staging
    dynamodb_table = "tf-locks-massnexus"
    encrypt        = true
  }
}