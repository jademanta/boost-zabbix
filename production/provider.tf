provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Repo      = "github.com/jademanta/boost-zabbix"
      Stack     = "Production"
    }
  }
}
