locals {
  name = "netmon-zabbix"

  common_tags = {
    Name = local.name
    # Prod_Monthly AWS Backup plan selects on aws:ResourceTag/Task = Monthly.
    # The instance is disposable, so this matters mostly on the RDS instance
    # (rds.tf); it is harmless here and keeps the account's convention.
    Task = "Monthly"
  }
}

data "aws_caller_identity" "current" {}

data "aws_subnet" "asg" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

# Ubuntu 24.04 LTS (noble). With an ASG, a new Canonical image is harmless: it
# creates a new launch template version that is only used on the next rebuild.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------------------------------------------------------------------------
# Security group for the host. Rules are separate resources keyed by a stable
# name, so adding/removing one CIDR is a one-line plan, not a rewrite of the set.
# ---------------------------------------------------------------------------
resource "aws_security_group" "zabbix" {
  name        = "${local.name}-sg"
  description = "Zabbix server: web via Caddy, trapper 10051, SSH allowlist"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.name}-sg" }
}

locals {
  ingress_rules = merge(
    { for k, v in var.ssh_ingress_cidrs : "ssh ${k}" => { port = 22, cidr = v } },
    { for c in var.web_ingress_cidrs : "http ${c}" => { port = 80, cidr = c } },
    { for c in var.web_ingress_cidrs : "https ${c}" => { port = 443, cidr = c } },
    { for c in var.trapper_ingress_cidrs : "trapper ${c}" => { port = 10051, cidr = c } },
  )
}

resource "aws_vpc_security_group_ingress_rule" "zabbix" {
  for_each = local.ingress_rules

  security_group_id = aws_security_group.zabbix.id
  description       = each.key
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  tags              = { Name = each.key }
}

resource "aws_vpc_security_group_egress_rule" "zabbix_all" {
  security_group_id = aws_security_group.zabbix.id
  description       = "All outbound (polling targets, image pulls, ACME, RDS, S3)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Static IP. Allocated here, attached by the instance itself at boot (see
# scripts/bootstrap.sh and iam.tf) so a replacement instance takes it over.
# DNS and target-side firewall rules reference it: never release.
# ---------------------------------------------------------------------------
resource "aws_eip" "zabbix" {
  domain = "vpc"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name         = "${local.name}-eip"
    DoNotRelease = "true"
  }
}

# ---------------------------------------------------------------------------
# Launch template + Auto Scaling group of exactly one
# ---------------------------------------------------------------------------
resource "aws_launch_template" "zabbix" {
  name_prefix            = "prod-zabbix-"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.zabbix_host.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # bootstrap runs on the host; containers do not need IMDS
  }

  network_interfaces {
    associate_public_ip_address = true # needed for apt/docker/secret fetch before the EIP is attached
    device_index                = 0
    security_groups             = [aws_security_group.zabbix.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap.sh", {
    aws_region      = var.aws_region
    eip_alloc_id    = aws_eip.zabbix.allocation_id
    db_secret_arn   = aws_db_instance.zabbix.master_user_secret[0].secret_arn
    db_host         = aws_db_instance.zabbix.address
    state_bucket    = aws_s3_bucket.state.bucket
    repo_url        = var.repo_url
    repo_branch     = var.repo_branch
    zabbix_version  = var.zabbix_version
    fqdn            = var.fqdn
    zbx_server_name = var.zbx_server_name
    acme_email      = var.acme_email
    timezone        = var.timezone
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-root" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "zabbix" {
  name                      = local.name
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = var.subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 600 # bootstrap takes ~5 min
  default_cooldown          = 300

  launch_template {
    id      = aws_launch_template.zabbix.id
    version = "$Latest"
  }

  # A launch template change (new AMI, edited bootstrap) does NOT touch the
  # running host; the new version is used on the next launch only. Roll it on
  # purpose by terminating the instance (output self_heal_test_command) or:
  #   aws autoscaling start-instance-refresh --auto-scaling-group-name netmon-zabbix
  # Deliberately no instance_refresh{} block with triggers: with min=max=1 an
  # automatic refresh on every LT change would mean surprise downtime on apply.
  #
  # health_check_type is EC2 on purpose: application health is reported by the
  # host itself (scripts/healthcheck.sh -> autoscaling set-instance-health).

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

}
