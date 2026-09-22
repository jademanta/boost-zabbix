#!/bin/bash
# Application-level health for the ASG. The ASG's own EC2 health check only sees
# the hypervisor; this runs every minute (systemd timer, installed by
# bootstrap.sh) and after FAIL_LIMIT consecutive failures marks the instance
# Unhealthy so the ASG replaces it. Self-heal for "containers are down", not
# just "instance is gone".
#
# Healthy means: zabbix-server container running, zabbix-web container healthy
# (its own healthcheck curls /ping), caddy running.
set -u
FAIL_LIMIT=5
STATE=/run/zabbix-healthcheck.failures
REGION=$(cat /etc/zabbix-host/region)

ok=1
[ "$(docker inspect -f '{{.State.Running}}' zabbix-zabbix-server-1 2>/dev/null)" = "true" ] || { echo "zabbix-server not running"; ok=0; }
[ "$(docker inspect -f '{{.State.Health.Status}}' zabbix-zabbix-web-1 2>/dev/null)" = "healthy" ] || { echo "zabbix-web not healthy"; ok=0; }
[ "$(docker inspect -f '{{.State.Running}}' zabbix-caddy-1 2>/dev/null)" = "true" ] || { echo "caddy not running"; ok=0; }

if [ "$ok" = 1 ]; then
  echo 0 > "$STATE"
  exit 0
fi

fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$STATE"
echo "unhealthy ($fails/$FAIL_LIMIT)"

if [ "$fails" -ge "$FAIL_LIMIT" ]; then
  TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
  echo "marking $ID Unhealthy in the ASG"
  aws --region "$REGION" autoscaling set-instance-health --instance-id "$ID" --health-status Unhealthy --no-should-respect-grace-period
  echo 0 > "$STATE"
fi
