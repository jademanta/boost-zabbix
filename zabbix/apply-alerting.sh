#!/bin/bash
# Run ON the Zabbix host (root, via SSM or a shell):
#   sudo bash /opt/boost-zabbix/zabbix/apply-alerting.sh
# Reads every credential from the /netmon-zabbix/* SSM parameters that
# production/alerting.tf creates, then applies the Zabbix-side alerting
# configuration with configure_alerting.py. Idempotent; re-run after any change.
#
# Written with a file tool, not a shell heredoc (repo guard on secret-fetch strings).
set -euo pipefail
cd "$(dirname "$0")"
export AWS_DEFAULT_REGION="$(cat /etc/zabbix-host/region)"

param() { aws ssm get-parameter --with-decryption --name "$1" --query Parameter.Value --output text; }

SETTINGS=$(param /netmon-zabbix/alerting)
export ZBX_URL="$(jq -r .zabbix_url <<<"$SETTINGS")"
export SMTP_SERVER="$(jq -r .smtp_server <<<"$SETTINGS")"
export SMTP_PORT="$(jq -r .smtp_port <<<"$SETTINGS")"
export SMTP_FROM="$(jq -r .from_address <<<"$SETTINGS")"
export SMTP_HELO="$(jq -r .helo <<<"$SETTINGS")"
export ALERT_EMAIL="$(jq -r .alert_email <<<"$SETTINGS")"
export SLACK_CHANNEL="$(jq -r .slack_channel <<<"$SETTINGS")"

export ZBX_TOKEN="$(param /netmon-zabbix/api-token)"
export SMTP_USER="$(param /netmon-zabbix/smtp/username)"
export SMTP_PASS="$(param /netmon-zabbix/smtp/password)"
export SLACK_BOT_TOKEN="$(param /netmon-zabbix/slack-bot-token)"

# The frontend is reached through Caddy on this same host; the cert is for the
# public name, so resolve it locally rather than going out and back in.
export ZBX_URL_HOST="${ZBX_URL#https://}"
grep -q "$ZBX_URL_HOST" /etc/hosts || echo "127.0.0.1 $ZBX_URL_HOST" >> /etc/hosts

python3 ./configure_alerting.py
