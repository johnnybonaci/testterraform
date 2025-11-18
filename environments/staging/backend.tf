terraform {
  backend "s3" {
    bucket         = "massnexus-tf-state-nico"
    region         = "us-east-1"
    key            = "staging/terraform.tfstate"
    dynamodb_table = "tf-locks-massnexus"
    encrypt        = true
  }
}