# Migration plan: PRTG -> Zabbix (Terraform)

Approach: build a **new** Zabbix host from this repo alongside the old one,
configure it, run it in parallel with PRTG until it has proven alerting, then
retire both old boxes. The old Zabbix box has no configuration worth keeping
(see current-state.md), so no data migration is needed.

## Phase 0 - prerequisites (before `terraform apply`)

1. **SSH key.** Done 2026-09-22: new ed25519 `zabbix` pair, private key at `~/.ssh/zabbix.pem`.
   Either find it, or create a new pair and set `key_name`. SSM Session Manager
   is wired in regardless, so SSH is only a fallback.
   ```bash
   aws --profile boostprod ec2 create-key-pair --key-name zabbix-tf --key-type ed25519 --query KeyMaterial --output text > ~/.ssh/zabbix-tf.pem && chmod 400 ~/.ssh/zabbix-tf.pem
   ```
2. **Push this repo to GitHub** (`main`). The instance clones it at first boot,
   so the compose files must be on the remote before apply.
3. Review `production/variables.tf` defaults (instance size, CIDR allowlists).

## Phase 1 - build

```bash
cd production
export AWS_PROFILE=boostprod
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output
```
RDS takes about 10 minutes to create, then the ASG launches the host and bootstrap runs
3-5 minutes (`/var/log/zabbix-bootstrap.log` on the host). Then run the self-heal test
(`terraform output -raw self_heal_test_command | bash`) once before putting anything on it.
Caddy will not get a certificate until DNS points at the EIP (Phase 4), which
is fine; the stack runs and is reachable by IP over HTTP for initial setup only
if you temporarily hit it through an SSM port-forward:
```bash
aws --profile boostprod ssm start-session --target $(terraform output -raw current_instance_id_command | bash) --document-name AWS-StartPortForwardingSession --parameters 'portNumber=80,localPortNumber=8080'
```
Initial login is Admin / zabbix. Change it immediately.

Add the two poller CIDRs (`terraform output poller_cidrs`, the ASG's subnets) to the four
target SGs (list in current-state.md). CIDRs, not an IP: the host's private IP changes on
every rebuild.

**Status 2026-09-22: Phase 1 done.** RDS + ASG built, self-heal exercised twice (both fixes it
surfaced are in `bootstrap.sh`), server 7.0.31 up against RDS, EIP 32.187.30.106.

## Phase 1b - cutover DNS now (nothing else answers on netmon.boocorp.com)

1. Cloudflare, zone boocorp.com: edit the A record `netmon` -> `32.187.30.106`, and set it to
   **DNS only (grey cloud)** for the first pass so Caddy's HTTP-01 challenge reaches the host
   directly. Within a minute or two `docker logs zabbix-caddy-1` shows the certificate obtained.
2. Optional afterwards: turn the proxy back on (orange cloud) with SSL mode **Full (strict)**,
   and consider Cloudflare Access in front of the login page.
3. Internal AD DNS: update `netmon.boocorp.com` on the DCs to `32.187.30.106` as well.
4. Log in at https://netmon.boocorp.com/ as Admin / zabbix and change the password immediately.
5. First UI task: Data collection > Hosts > "Zabbix server" > interface: change the agent
   interface from 127.0.0.1 to DNS name `host.docker.internal` so the server polls the host's
   agent2 (it is a package on the host, not a container).

## Phase 2 - base Zabbix configuration

- Admin password, disable `guest`, set frontend URL to https://netmon.boocorp.com.
- Users mirroring PRTG: jbowers, gthorpe, jturner, pasper, DevOps, DBA, wallboard
  (read-only). Consider LDAP/SAML against Prod.local or Google later.
- User groups mirroring PRTG notification groups: IT Group, Sysadmin, Production,
  Germany, Blog Support.
- Media types (decided: Slack #it-alerts + email it@boostability.com): built by
  `production/alerting.tf` + `zabbix/apply-alerting.sh` (see README "Alerting").
  PRTG's SMS and Google Chat notifications are not carried over.
- Actions: one per severity band, reproduce the PRTG notification matrix.
- Housekeeping: default 90d history / 365d trends is fine at this scale.

## Phase 3 - recreate monitoring, by PRTG group

| PRTG group / sensor type | Zabbix approach |
|---|---|
| Production Websites, Whitelabel, Corp Websites (`http`, `httpfull`) | One host per site (or one "Websites" host) with **HTTP agent** items via the "Website by HTTP" template, or Web scenarios for the multi-step `launchpad` transaction |
| Website Cert Checks (43 `ptfsslcertexpiration`) | "Website certificate by Zabbix agent 2" template, executed by the `zabbix-agent2` container on the server; one host per site, macro `{$CERT.WEBSITE.HOSTNAME}` |
| Service & APIs | HTTP agent items with response-body checks |
| Production AWS Servers (Windows: DCs, Web01/02, App01/03, DB1/2, SmokeScreen, CorpDC) | Install Zabbix agent 2 (MSI) on each; "Windows by Zabbix agent" template replaces the WMI/RDP sensors. SQL via "MSSQL by ODBC" or agent2 plugin on DB1/DB2. Servers are reachable from the VPC (TGW routes exist) |
| Corp Network / Corp Servers / Baremetal / Virtual (Lehi 10.10.x) | **Zabbix proxy in Lehi** (`zabbix-proxy-sqlite3` container, one small process + a SQLite file, fine on the slow corp hardware) - replaces the PRTG cluster node at 10.10.0.22. The EC2 node stays the master; the proxy only collects and forwards. Active proxy pushes to the EIP on 10051 (Lehi's egress CIDRs are allowed) or over the TGW path. SNMP for firewall, Dell EMC, switches (FiberCore); agent 2 for Windows hosts (C2/C3 Hyper-V, Olympus, FS-L, Valhalla) |
| Corp Internet Connection (Comcast/Centracom gateways, 1.1.1.1, 8.8.8.8, `dns`) | ICMP ping + `net.dns` simple checks from the Lehi proxy |
| Corp Printers | SNMP "Printer by SNMP"-style templates from the proxy |
| Manta.com | HTTP + cert checks as above |

Also add the Zabbix host itself ("Zabbix server", Linux by Zabbix agent 2 +
"Zabbix server health") and the Lehi proxy ("Zabbix proxy health").

Do this in the Zabbix UI first. Once stable, consider exporting hosts/templates
as YAML into this repo (`zabbix/` folder) or managing them with the
`Zabbix Terraform provider`, so config is also git-controlled.

## Phase 4 - cutover

1. Cloudflare: change `netmon.boocorp.com` A record to the new EIP, keep proxied,
   SSL/TLS mode **Full (strict)**. Caddy obtains a Let's Encrypt cert via HTTP-01
   through the Cloudflare proxy. Optionally put Cloudflare Access in front.
2. Internal AD DNS: update the `netmon` record on the boocorp.com zone to match.
3. Verify https://netmon.boocorp.com, alert test to each media type.
4. Optionally tighten `web_ingress_cidrs` to Cloudflare IP ranges + corp/VPN.

## Phase 5 - decommission the old Zabbix box (after cutover)

Jade runs these; they are destructive.
```bash
aws --profile boostprod ec2 terminate-instances --instance-ids i-0b989293472f77900
# root volume is delete_on_termination=false, so remove it separately once the instance is gone:
aws --profile boostprod ec2 delete-volume --volume-id vol-062a5ae270e7b1e44
aws --profile boostprod ec2 delete-security-group --group-id sg-018097c263e719135
```

## Phase 6 - retire PRTG (after 30 days of parallel running with no gaps found)

Checklist before terminating:
- Every PRTG device has a Zabbix equivalent and has alerted at least once in test.
- The Lehi node 10.10.0.22 has been repurposed as (or replaced by) the Zabbix proxy.
- Any dashboards/wallboard pointing at PRTG are repointed.
- Take a final AMI/snapshot of vol-d59df932 for the record (it is 220 GiB; keep 90 days).

```bash
aws --profile boostprod ec2 terminate-instances --instance-ids i-cee45f06
aws --profile boostprod ec2 release-address --allocation-id eipalloc-e9c2e281
aws --profile boostprod ec2 delete-volume --volume-id vol-d59df932   # after snapshot
```
Then remove the 10.0.201.65 rules from sg-1f9f5c7b, sg-44897d20, sg-62d63907,
sg-bcd6a7db, delete sg-59d7173d "CF App PRTG", and disable/delete the APP02
computer account in Prod.local.

## Cost

| | Now | After |
|---|---|---|
| Zabbix | m6i.large on-demand ~$70/mo + 32 GiB | t3.medium ~$30/mo + RDS db.t4g.small ~$25/mo + 20 GiB gp3 + S3 pennies |
| PRTG | t2.large Windows ~$95/mo + 220 GiB gp3 ~$18/mo | $0 |
| Net | ~$185/mo | ~$60/mo |

## Open questions for Jade

- Where is the `zabbix` key pair's private key, or create a new one? (Phase 0)
- Which SMTP path for email alerts: SES in boostprod, or the corp relay PRTG uses?
- Is 10.10.0.22 a VM we can rebuild as the Zabbix proxy, or does it host other things?
- Any PRTG consumers beyond notifications (wallboard URL, API scripts, Datadog)?
