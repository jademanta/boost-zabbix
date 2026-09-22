# ---------------------------------------------------------------------------
# The database IS Zabbix. Hosts, templates, users, history, trends, media types,
# sessions: everything lives here. Keeping it on RDS is what makes the EC2 host
# disposable (the Loki-on-S3 idea, applied to a stateful app).
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "zabbix" {
  name       = "netmon-zabbix"
  subnet_ids = var.db_subnet_ids
  tags       = { Name = "netmon-zabbix" }
}

resource "aws_security_group" "db" {
  name        = "netmon-zabbix-db-sg"
  description = "MySQL from the Zabbix host only"
  vpc_id      = var.vpc_id
  tags        = { Name = "netmon-zabbix-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_zabbix" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from Zabbix server/frontend"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.zabbix.id
}

# Zabbix's schema import creates functions/triggers; with binary logging on
# (which RDS automated backups imply) MySQL refuses that unless this is set.
# The Zabbix docs call for exactly this, and the old box ran mysqld with the
# same flag. Charset/collation match what Zabbix requires (utf8mb4 / utf8mb4_bin).
resource "aws_db_parameter_group" "zabbix" {
  name        = "netmon-zabbix-mysql84"
  family      = "mysql8.4"
  description = "Zabbix requirements for MySQL 8.4"

  parameter {
    name  = "log_bin_trust_function_creators"
    value = "1"
  }
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
  parameter {
    name  = "collation_server"
    value = "utf8mb4_bin"
  }
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
}

resource "aws_db_instance" "zabbix" {
  identifier = "netmon-zabbix"

  engine = "mysql"
  # Major.minor only. The provider suppresses the diff against the actual
  # patch version RDS runs, so auto_minor_version_upgrade causes no drift.
  engine_version         = var.db_engine_version
  instance_class         = var.db_instance_class
  parameter_group_name   = aws_db_parameter_group.zabbix.name
  db_subnet_group_name   = aws_db_subnet_group.zabbix.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # The schema is created by the zabbix-server container on first start, using
  # this master user. No separate app user: one credential, one secret.
  db_name                     = "zabbix"
  username                    = "zabbix"
  manage_master_user_password = true # password lives in Secrets Manager; the host reads it at boot

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "09:00-10:00" # 03:00-04:00 America/Denver
  maintenance_window      = "sun:10:00-sun:11:00"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = false
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "netmon-zabbix-final"

  performance_insights_enabled = false

  lifecycle {
    prevent_destroy = true
  }

  # Backups: RDS automated backups (db_backup_retention_days) plus the final
  # snapshot. The account's Prod_Monthly AWS Backup plan only selects EC2
  # instances, so a Task=Monthly tag here would do nothing. Take a manual
  # snapshot before Zabbix major upgrades (README).
  tags = { Name = "netmon-zabbix" }
}
