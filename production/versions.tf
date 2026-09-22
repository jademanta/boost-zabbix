terraform {
  # Minimum for S3-native state locking (use_lockfile), added in Terraform 1.10.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  # Same bucket/prefix convention as boost-n8n-tf.
  backend "s3" {
    bucket       = "boost.cloudformation"
    key          = "Terraform_state_files/production/zabbix.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
