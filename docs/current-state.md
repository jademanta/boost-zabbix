# Current state (evaluated 2026-09-22)

Account: boostprod 171627987654, us-west-2, VPC vpc-b2a82cd7. Both hosts sit in
public subnet subnet-33e0406a (10.0.200.0/22, us-west-2c). No CloudFormation
stack, launch template, or Terraform state exists for either one; both were
built by hand (the Zabbix box from a console-pasted user-data script).

## Zabbix (to be replaced) - i-0b989293472f77900 "CF Netmon - Zabbix"

| Item | Value |
|---|---|
| Instance | m6i.large, Ubuntu 22.04.5, launched 2025-06-25, up 453 days |
| Public IP | 54.190.103.132, **auto-assigned, not an EIP** (changes on stop/start) |
| Private IP | 10.0.201.44 |
| Root volume | vol-062a5ae270e7b1e44, 32 GiB gp3, unencrypted, delete_on_termination=false, 30% used |
| Key pair | `zabbix` (ed25519, created 2025-06-04). Private key is **not on this workstation** |
| IAM profile | none (not an SSM managed node) |
| SG | sg-018097c263e719135 `netmon_zabbix`: 80/443/10050/10051 open to 0.0.0.0/0; 22 from corp, VPN, Jade |
| Backups | tag Task=Monthly -> Prod_Monthly plan (2nd Sat, 365d); last point 2026-09-12 |
| DNS | `netmon.boocorp.com` -> Cloudflare proxied -> this IP. Origin serves plain HTTP only (no cert in nginx) |
| Pending reboot | yes, 40 upgradable packages |

Stack: upstream `zabbix/zabbix-docker` clone at `/home/ubuntu/zabbix-docker`,
Docker 28.3, `docker compose up -d` of the default `compose.yaml`. Running:
`zabbix-server-mysql:alpine-7.2-latest` (7.2.10), `zabbix-web-nginx-mysql:alpine-7.2`,
`mysql:8.4-oracle`. Leftover exited containers from an earlier Postgres attempt.
Secrets are the upstream defaults (6-char DB password in `env_vars/.MYSQL_PASSWORD`).

**Configuration content is effectively empty**: 1 monitored host (the server
itself), 1 disabled host, 2 users (Admin, guest; Admin password changed from
default), 0 media types, 0 actions, 0 proxies. DB is 261 MB of history for that
one host. There is nothing to migrate; a fresh build loses nothing.

Zabbix 7.2 is a short-term release that is past end of life. The 7.0 line is the
supported LTS.

## PRTG (to be retired) - i-cee45f06 "CF PRTG Probe" (hostname APP02, Prod.local)

| Item | Value |
|---|---|
| Instance | t2.large **Windows Server 2012** (EOL Oct 2023), AMI ami-6de0e35d no longer exists |
| PRTG | 15.4.20.4378 (2015 release) |
| Public IP | EIP 54.213.70.187 (eipalloc-e9c2e281 "PRTG Probe") |
| Private IP | 10.0.201.65 |
| Volume | vol-d59df932 "CF App02", 220 GiB gp3 (created 2015), 70 GB used; PRTG data 9.2 GB |
| IAM profile | CodedeployPROD-EC2-Instance; SSM agent 3.0.529 online |
| SGs | WSFC DomainMemberSG, `CF App PRTG` (sg-59d7173d), `CF External RDP`, `CF App Servers` |
| Web UI | http only, bound to 10.0.201.65:8080 |
| Cluster | **ClusterMode=2, two nodes.** Second node is 10.10.0.22 in Lehi (many established connections on 23570). That node polls the corp LAN devices |

Inventory from `PRTG Configuration.dat` (last written 2026-05-27):
2 probes, 15 groups, **40 devices, 343 sensors**, 10 users, 16 notifications.

Groups: Production Websites, Manta, Production AWS Servers, Corp Internet
Connection, Corp Virtual Environment, Corporate, Corp Servers, Baremetal, Virtual,
Corp Network, Corp Websites, Corp Printers, IT Group home, Sysadmin Group home.

Sensor kinds: 50 http, 49 snmptraffic, 43 ssl-cert-expiration (42 on the
"Website Cert Checks" device), 30 ping, 21 snmpdiskfree, 19 remotedesktop,
18 snmpmemory, 17 wminetwork, 14 snmpcustom, 9 snmpuptime, 9 snmpcpu, 7 dns,
6 wmimemory, 6 wmiuptime, 5 each wmidiskspace/wmipagefile/wmiprocessor, 4
snmpdellphysicaldisk, plus a handful of ssl, httpfull, lastwindowsupdate,
hyperv, dellsystemhealth and probe-health sensors.

Devices by location:
- **AWS (via TGW/VPC):** CF DC1 10.0.0.10, CF DC2 10.0.64.10, Web01/Web02
  10.0.97.215, App01 10.0.32.165, App03 10.0.200.152, SmokeScreenAWS 10.0.41.95,
  DB1 10.0.0.200, DB2 10.0.64.200, AWS CorpDC 10.0.43.55.
- **Lehi corp LAN 10.10.x (polled by the 10.10.0.22 cluster node):** Corp
  Firewall 10.10.0.1, C2/C3 Hyper-V hosts .15/.16, Olympus .12, Dell EMC storage
  .4, Wideload .50, Vastload .90, itwiki .91, GSync .9, FS-L .5, Ironhide/Valhalla
  .25, CloudberryBuffer .29, Evil Mayo 10.10.1.103, Maidenless 10.10.2.9,
  FiberCore1 10.10.1.91, WiFi mgmt https://10.10.0.22:8443.
- **Internet:** Comcast gw 50.207.234.25, Centracom gw 205.197.213.193,
  1.1.1.1, 8.8.8.8, manta.com, ~50 Boost/whitelabel/partner websites and
  service.* API endpoints, ~42 certificate-expiry checks.

Notifications in use: email to groups (IT Group, Sysadmin, PRTG Production,
Germany, Blog Support, Jade), SMS to Production and Blog Support, "PRTG to
Slack", "Slack Prod Alerts", "PRTG_to_italerts_google_space" (Google Chat).
Users: DBA (Slack email gateway), DevOps, gthorpe, jbowers, jturner, pasper,
admin, wallboard, User; rclarke disabled.

## Things that depend on the PRTG core's address

Security groups with rules for 10.0.201.65/32 (need the new Zabbix private IP
added before cutover, and can drop PRTG afterwards):
`sg-1f9f5c7b` CF Allow PRTG Requests, `sg-44897d20` CF ICMP All Internal,
`sg-62d63907` Ubuntu Web, `sg-bcd6a7db` Stage Allow PRTG requests.

Cloudflare (public NS hank/ruth.ns.cloudflare.com) hosts `boocorp.com`;
`netmon.boocorp.com` is proxied and points at the old Zabbix box. Internal AD
DNS also resolves the name (to 54.190.103.132 directly).

## Reference: how boost-n8n-tf does it

Same account and VPC. Single `aws_instance` from a launch template, EIP with
`prevent_destroy`, SG allowlist, Caddy for TLS, Ubuntu + Docker installed by
user-data, repo cloned on the box, S3 backend `boost.cloudformation` /
`Terraform_state_files/<env>/<app>.tfstate` with `use_lockfile`. Lessons it
learned the hard way and this repo bakes in from day one: pin the AMI /
ignore LT drift so a new Canonical image never proposes replacement; keep the
data off the root disk; give the host an SSM-only instance profile.
