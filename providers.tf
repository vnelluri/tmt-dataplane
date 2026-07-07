terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Per-account remote state — fill in this account's state bucket before the
  # first apply. The provisioner pipeline and human operators must share this
  # state or reconciles will fight each other.
  backend "s3" {
    bucket         = "REPLACE-ME-tf-state"
    key            = "tmt-dataplane/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "REPLACE-ME-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}
