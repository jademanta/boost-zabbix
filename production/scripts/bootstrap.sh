#!/bin/bash
# Rendered by Terraform templatefile(). Terraform interpolates "dollar-brace"
# references; bash variables that need braces are written with a doubled dollar.
#
# Runs once, as root, at first boot of EVERY instance the ASG launches. The host
# is stateless: all Zabbix state is in RDS, the DB credential comes from Secrets
# Manager via the instance role, Caddy's certificates are restored from S3,
# config comes from this repo. Nothing on this disk needs to survive.
#
# Safe to re-run on a half-bootstrapped host: every step checks before it acts.
#
# NOTE for editors: this file is written with the Write tool, not a Bash
# heredoc. The repo guard blocks shell commands containing the secret-fetch CLI
# string, even when it is only file content.
set -euo pipefail
exec >>/var/log/zabbix-bootstrap.log 2>&1
echo "=== bootstrap start $(date)"

export AWS_DEFAULT_REGION="${aws_region}"
REPO_DIR=/opt/boost-zabbix
RUN_DIR=/srv/zabbix          # secret files + caddy cert cache; local, ephemeral
CADDY_S3="s3://${state_bucket}/${state_prefix}"
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
mkdir -p /etc/zabbix-host && echo "${aws_region}" > /etc/zabbix-host/region

# --- 1. Packages: Docker (official repo), AWS CLI v2 (official installer), jq --
# Ubuntu 24.04 has no `awscli` apt package (it became a snap), so use the
# official installer into /usr/local/bin. Architecture-agnostic for the arm64 image later.
apt-get update -y
apt-get install -y ca-certificates curl gnupg git jq unzip
if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$${VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
usermod -aG docker ubuntu

# --- 2. Take the Elastic IP (self-heal: a replacement instance re-claims it) --
aws ec2 associate-address --allocation-id "${eip_alloc_id}" --instance-id "$INSTANCE_ID" --allow-reassociation
echo "EIP ${eip_alloc_id} associated with $INSTANCE_ID"

# --- 3. DB credential: Secrets Manager -> compose secret files ---------------
# The RDS-managed master secret is JSON {"username":..,"password":..}. It is
# read by the instance role at boot and written to root-only files that compose
# mounts as /run/secrets/*; it is never placed in an env var or in this repo.
# Reaching Secrets Manager depends on the VPC endpoint SG rule in main.tf.
mkdir -p "$RUN_DIR/secrets" "$RUN_DIR/caddy/data" "$RUN_DIR/caddy/config"
chmod 700 "$RUN_DIR/secrets"
aws secretsmanager get-secret-value --secret-id "${db_secret_arn}" --query SecretString --output text \
  | jq -r '.username' | tr -d '\n' > "$RUN_DIR/secrets/MYSQL_USER"
aws secretsmanager get-secret-value --secret-id "${db_secret_arn}" --query SecretString --output text \
  | jq -r '.password' | tr -d '\n' > "$RUN_DIR/secrets/MYSQL_PASSWORD"
# The Zabbix images run as user zabbix (uid 1997) and compose file-secrets keep
# host ownership, so the files must be readable by that uid, not by root only.
chown 1997:1997 "$RUN_DIR"/secrets/*
chmod 400 "$RUN_DIR"/secrets/*

# --- 4. Caddy certificates: restore from S3 (empty on the very first boot) ---
aws s3 sync "$CADDY_S3" "$RUN_DIR/caddy" --only-show-errors || echo "no caddy state in S3 yet"

# --- 5. This repo: compose.yaml, Caddyfile, alertscripts --------------------
git config --system --add safe.directory "$REPO_DIR"   # repo is owned by ubuntu; root (SSM, timers) must be able to pull
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only
else
  git clone --branch "${repo_branch}" "${repo_url}" "$REPO_DIR"
fi
chown -R ubuntu:ubuntu "$REPO_DIR"
cd "$REPO_DIR/production/docker"

cat > .env <<EOC
RUN_DIR=$RUN_DIR
ZABBIX_VERSION=${zabbix_version}
DB_HOST=${db_host}
FQDN=${fqdn}
ZBX_SERVER_NAME=${zbx_server_name}
ACME_EMAIL=${acme_email}
TZ=${timezone}
EOC
chown ubuntu:ubuntu .env

# --- 6. Up. zabbix-server creates/migrates the schema in RDS on first start ---
docker compose pull
docker compose up -d
docker compose ps

# --- 7. Timers: app health -> ASG, and hourly Caddy state save to S3 ---------
install -m 0755 "$REPO_DIR/production/scripts/healthcheck.sh" /usr/local/sbin/zabbix-healthcheck
cat > /etc/systemd/system/zabbix-healthcheck.service <<EOC
[Unit]
Description=Report Zabbix container health to the Auto Scaling group
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zabbix-healthcheck
EOC
cat > /etc/systemd/system/zabbix-healthcheck.timer <<EOC
[Unit]
Description=Run zabbix-healthcheck every minute
[Timer]
OnBootSec=10min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOC
cat > /etc/systemd/system/zabbix-caddy-backup.service <<EOC
[Unit]
Description=Save Caddy certificates to S3
[Service]
Type=oneshot
Environment=AWS_DEFAULT_REGION=${aws_region}
ExecStart=/usr/local/bin/aws s3 sync $RUN_DIR/caddy $CADDY_S3 --delete --only-show-errors
EOC
cat > /etc/systemd/system/zabbix-caddy-backup.timer <<EOC
[Unit]
Description=Save Caddy certificates to S3 hourly
[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOC
systemctl daemon-reload
systemctl enable --now zabbix-healthcheck.timer zabbix-caddy-backup.timer

# --- 8. Zabbix agent 2 on the host (self-monitoring), as a normal package ----
if ! dpkg -s zabbix-agent2 >/dev/null 2>&1; then
  UBU="$(. /etc/os-release && echo "$${VERSION_ID}")"
  curl -fsSL "https://repo.zabbix.com/zabbix/${zabbix_version}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${zabbix_version}+ubuntu$${UBU}_all.deb" -o /tmp/zabbix-release.deb
  dpkg -i /tmp/zabbix-release.deb
  apt-get update -y
  apt-get install -y zabbix-agent2
fi
sed -i -e 's/^Server=.*/Server=127.0.0.1,172.16.0.0\/12/' \
       -e 's/^ServerActive=.*/ServerActive=127.0.0.1/' \
       -e 's/^Hostname=.*/Hostname=Zabbix server/' /etc/zabbix/zabbix_agent2.conf
# The package starts the agent with the default config at install time and
# `enable --now` will not restart a running unit, so restart explicitly.
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2

echo "=== bootstrap complete $(date)"
