# Caddy's data dir (Let's Encrypt account + certificates) is the one piece of
# host state worth keeping across rebuilds: without it every self-heal requests
# a new certificate and Let's Encrypt allows 5 duplicates per week. Same idea as
# Loki on S3, applied to a few KB. bootstrap.sh restores it before compose up; a
# systemd timer saves it hourly.
#
# Dedicated bucket, shared by design: any Caddy-fronted host (n8n next) gets its
# own prefix and an IAM grant scoped to that prefix. Kept separate from
# boost.cloudformation so certificate private keys never sit next to Terraform
# state and no instance role needs access to that bucket.
locals {
  state_bucket = "boost-caddy-state-${data.aws_caller_identity.current.account_id}"
  state_prefix = "netmon-zabbix"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = local.state_bucket }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
