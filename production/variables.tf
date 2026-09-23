variable "aws_region" {
  type    = string
  default = "us-west-2"
}

# ---------------------------------------------------------------------------
# Compute (stateless; rebuilt by the Auto Scaling group)
# ---------------------------------------------------------------------------
variable "instance_type" {
  description = "Zabbix host size. Server + frontend + Caddy only (DB is on RDS). 40 devices / ~350 checks is small."
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 key pair for emergency SSH (ed25519 'zabbix', recreated 2026-09-22; private key ~/.ssh/zabbix.pem). SSM Session Manager is the primary access path."
  type        = string
  default     = "zabbix"
}

variable "vpc_id" {
  description = "boostprod VPC (CloudFormation boostprod-vpc)."
  type        = string
  default     = "vpc-b2a82cd7"
}

variable "subnet_ids" {
  description = "Public subnets the ASG may launch into (both route 0.0.0.0/0 to the IGW). Two AZs so an AZ loss also self-heals. Target-side firewall rules must allow both CIDRs (see poller_cidrs output)."
  type        = list(string)
  default = [
    "subnet-33e0406a", # 10.0.200.0/22 us-west-2c - where the old Zabbix and PRTG live
    "subnet-43ac3026", # 10.0.96.0/20  us-west-2b - Prod-Public-Subnet, where n8n lives
  ]
}

variable "root_volume_size" {
  description = "Root volume GiB. OS, docker images, Caddy certs. Nothing here needs to survive."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Database (the only state)
# ---------------------------------------------------------------------------
variable "db_instance_class" {
  description = "RDS class. db.t4g.small (2 vCPU, 2 GiB) is plenty for ~50 hosts; the old box's DB was 261 MB after 14 months."
  type        = string
  default     = "db.t4g.small"
}

variable "db_engine_version" {
  description = "RDS MySQL major.minor. Zabbix 7.x supports MySQL 8.0.30+ and 8.4. Leaving it at the major version lets RDS apply minor upgrades."
  type        = string
  default     = "8.4"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling GiB."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Synchronous standby in a second AZ. Doubles DB cost (~+$25/mo at t4g.small). Off to start; flip on if monitoring outages during RDS maintenance windows become a problem."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 14

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "RDS allows 1-35 days."
  }
}

variable "db_subnet_ids" {
  description = "Private RDS subnets (the RDS-Pvt-subnet-1..4 set that rds-ec2-db-subnet-group-1 already uses)."
  type        = list(string)
  default = [
    "subnet-02023f5b468faa523", # RDS-Pvt-subnet-1 us-west-2c
    "subnet-0ca83c158501f86da", # RDS-Pvt-subnet-3 us-west-2b
    "subnet-0d79f68f8d2423032", # RDS-Pvt-subnet-4 us-west-2a
    "subnet-0ac259cafaf62592b", # RDS-Pvt-subnet-2 us-west-2d
  ]
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
variable "zabbix_version" {
  description = "Zabbix image line. 7.0 is the current LTS (supported into 2029). The attached 7.4 docs also apply; 7.4 is the short-term release. Bump to 8.0 when that LTS ships."
  type        = string
  default     = "7.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.zabbix_version))
    error_message = "zabbix_version must be major.minor, e.g. 7.0."
  }
}

variable "fqdn" {
  description = "Public hostname. Exists in Cloudflare (proxied) pointing at the old box; repoint to the EIP at cutover."
  type        = string
  default     = "netmon.boocorp.com"
}

variable "zbx_server_name" {
  type    = string
  default = "Boost Netmon"
}

variable "acme_email" {
  type    = string
  default = "it@boostability.com"
}

variable "timezone" {
  type    = string
  default = "America/Denver"
}

variable "repo_url" {
  description = "This repo; the instance clones it at boot for compose.yaml, Caddyfile, alertscripts."
  type        = string
  default     = "https://github.com/jademanta/boost-zabbix.git"
}

variable "repo_branch" {
  type    = string
  default = "main"
}

# ---------------------------------------------------------------------------
# Network allowlists
# ---------------------------------------------------------------------------
variable "ssh_ingress_cidrs" {
  description = "SSH allowlist, description => CIDR. Mirrors boost-n8n-tf."
  type        = map(string)
  default = {
    "corp lan"                                                         = "10.10.0.0/22"
    "ssl vpn"                                                          = "205.197.213.195/32"
    "Jade egress 2026-08 (district CGNAT - rotate when ISP fixes NAT)" = "160.7.241.142/32"
  }
}

variable "web_ingress_cidrs" {
  description = "HTTP/HTTPS allowlist. 0.0.0.0/0 is needed for Let's Encrypt HTTP-01 and the Cloudflare proxy; tighten to Cloudflare ranges + corp once proven."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "trapper_ingress_cidrs" {
  description = "Who may reach server port 10051 (active agents, the Lehi proxy). AWS VPCs via TGW plus Lehi over the VPN path, plus Lehi's public egress in case the proxy is pointed at the EIP."
  type        = list(string)
  default = [
    "10.0.0.0/8",
    "50.207.234.24/29",   # Corp Comcast
    "205.197.213.192/27", # Corp Centracom
  ]
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
variable "alert_from_domain" {
  description = "Domain verified in SES (Easy DKIM) that alert mail is sent from."
  type        = string
  default     = "boostability.com"
}

variable "alert_from_address" {
  description = "From: address on Zabbix emails. Needs no mailbox; replies bounce. Must be under alert_from_domain."
  type        = string
  default     = "netmon@boostability.com"
}

variable "alert_email" {
  description = "Where problem notifications go."
  type        = string
  default     = "it@boostability.com"
}

variable "slack_channel" {
  description = "Slack channel for problem notifications (boostability workspace). The Zabbix bot must be invited to it."
  type        = string
  default     = "#it-alerts"
}

variable "secretsmanager_endpoint_sg_id" {
  description = "Security group of the VPC's Secrets Manager interface endpoint (vpce-0758d22218276d2d9, private DNS on). Every host in the VPC resolves secretsmanager.us-west-2.amazonaws.com to that endpoint, so this SG must admit the Zabbix host or the boot-time secret fetch times out. Set to \"\" if the endpoint is ever removed."
  type        = string
  default     = "sg-02fc84a6affdb351a"
}
