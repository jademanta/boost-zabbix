# boost-zabbix

Terraform + Docker Compose for the Boost production network monitor
(**Zabbix**, replacing PRTG). Built like [boost-n8n-tf](https://github.com/jademanta/boost-n8n-tf)
(Docker Compose, Caddy for TLS, S3-backed Terraform state) but designed so the EC2
host can be terminated at any time and come back on its own.

## Architecture: a disposable host in front of a managed database

```
Cloudflare (netmon.boocorp.com, proxied)
        |
   Elastic IP  <-- re-attached by every new instance at boot
        |
  Auto Scaling group, min = max = 1
        |
  EC2 (Ubuntu 24.04, stock AMI)            S3 boost-caddy-state-*/netmon-zabbix/
    caddy ---------------------------------> (certs, restored at boot, saved hourly)
    zabbix-web  \
    zabbix-server ---> RDS MySQL 8.4 (netmon-zabbix, private subnets, encrypted, 14-day backups)
    zabbix-agent2 (host package)
    healthcheck timer ---> autoscaling set-instance-health
```

Everything Zabbix knows (hosts, templates, users, history, alert config) is rows in
the RDS database. The EC2 host holds only running containers, so:

- **Instance dies or is terminated** -> the ASG launches a replacement, `bootstrap.sh`
  installs Docker, re-claims the EIP, reads the DB credential from Secrets Manager,
  restores Caddy's certificates from S3, starts the stack. ~5 minutes, no human step.
- **Containers die but the instance is up** -> the health-check timer marks the
  instance Unhealthy after 5 failed minutes and the ASG replaces it.
- **AZ loss** -> the ASG spans two public subnets; RDS can be made Multi-AZ (`db_multi_az`).
- **Database loss** -> RDS automated backups (point-in-time, 14 days) and a final
  snapshot on deletion. `prevent_destroy` and deletion protection are on.

The EC2 node is the Zabbix **server** (master). Lehi corp-LAN devices are reached
through a lightweight Zabbix **proxy** there, not a second server.

- `production/` - Terraform (ASG + launch template, SG rules, EIP, IAM/SSM, RDS, shared Caddy-state bucket)
- `production/docker/` - the compose stack the host runs (server, web, Caddy)
- `production/scripts/bootstrap.sh` - user-data: Docker install, EIP, secrets, S3 restore, `compose up`, timers
- `production/scripts/healthcheck.sh` - per-minute container health -> ASG
- `docs/current-state.md` - what exists today (old Zabbix box, PRTG cluster, inventory)
- `docs/migration-plan.md` - phased plan from build to PRTG retirement

## How the stack works

Zabbix is not one program. It ships as separate processes, and the official images
keep them separate, so the compose file has three services plus the external database:

| Service | Image | Role | Reachable from |
|---|---|---|---|
| `zabbix-server` | `zabbix/zabbix-server-mysql` | The daemon: polls hosts, evaluates triggers, sends alerts. Owns the DB schema and migrates it on upgrade | host port **10051** (agents/proxies push here) |
| `zabbix-web` | `zabbix/zabbix-web-nginx-mysql` | The PHP UI (nginx + php-fpm). Reads/writes the same DB; talks to the server only for "is it alive" and a few runtime commands | compose network only, port 8080 |
| `caddy` | `caddy:2` | TLS termination and reverse proxy to `zabbix-web`, same as the n8n box | host ports 80/443 |

Things that look different from a typical stack, and why:

- **Two Zabbix containers, not one.** Server and frontend are separate upstream
  images with separate release cycles. Both must run the same minor version; the
  single `ZABBIX_VERSION` in `.env` guarantees that.
- **`*_FILE` environment variables and a `secrets:` block.** The Zabbix images follow
  the official-image convention of reading credentials from a file path instead of an
  env var. `bootstrap.sh` writes the two files into `/srv/zabbix/secrets/` from the
  RDS-managed secret in Secrets Manager; nothing secret is in git, state, or `docker inspect`.
- **No database container.** `DB_SERVER_HOST` is the RDS endpoint. The
  `zabbix-server` image creates the schema on an empty database at first start and
  migrates it on version upgrades. TLS to RDS is required by the parameter group.
- **`ZBX_*` env vars.** Every `zabbix_server.conf` / frontend setting is exposed as
  an env var by the images (`ZBX_STARTPINGERS`, `ZBX_SERVER_NAME`, ...). There is no
  config file to mount; add settings in `compose.yaml` and `docker compose up -d`.
- **Bind mounts from the repo.** `docker/alertscripts`, `externalscripts`, `mibs` are
  git-controlled drop-in dirs the server reads at runtime, so they survive a rebuild.
- **Host agent is a package, not a container.** `zabbix-agent2` is installed on the
  Ubuntu host from repo.zabbix.com so it reports real host CPU/disk/memory. It
  connects to the server through the published port 10051 on localhost.
- **Upstream `zabbix-docker` repo is not used.** The old box ran the upstream
  `compose.yaml` (5 OS variants x 2 databases, profiles, 20 optional services).
  This file is the four services we need, written by hand.

Ports on the host: 80/443 (Caddy), 10051 (server trapper). Nothing else is exposed;
the SG in Terraform matches.

## Deploy

Prerequisites: Terraform >= 1.10, AWS CLI profile `boostprod`, an EC2 key pair
(`zabbix`, private key at `~/.ssh/zabbix.pem`), and this repo pushed to GitHub (the host clones `main` at boot).

```bash
cd production
export AWS_PROFILE=boostprod
terraform fmt -check -recursive && terraform init && terraform validate
terraform plan -out tfplan      # review: first apply is all creates, no destroys
terraform apply tfplan          # RDS takes ~10 min, then the ASG launches the host
terraform output
```

Always apply the reviewed `tfplan` file, never a bare `terraform apply`.

Then point `netmon.boocorp.com` (Cloudflare, proxied, SSL Full strict) at
`zabbix_elastic_ip`. Caddy fetches the certificate automatically once DNS resolves.

## Access

- Web: https://netmon.boocorp.com (initial login Admin / zabbix - change it)
- Shell: `terraform output ssm_session_command` (Session Manager, no key needed) or SSH from the allowlisted CIDRs. The instance id changes on every rebuild; the output looks it up from the ASG.
- Logs on host: `/var/log/zabbix-bootstrap.log`, `docker compose -f /opt/boost-zabbix/production/docker/compose.yaml logs`, `journalctl -u zabbix-healthcheck`

## Day-2

- **Test the self-heal** (do this once after the first apply, then whenever bootstrap changes):
  `terraform output -raw self_heal_test_command | bash`. Expect a new instance with the same
  EIP and all Zabbix config intact in about 5 minutes.
- **Change the stack** (compose, Caddyfile, scripts): push to `main`, then either rebuild
  (self-heal command above) or, for a no-gap change, on the host
  `cd /opt/boost-zabbix && git pull && docker compose -f production/docker/compose.yaml up -d`.
- **Patch Zabbix within a minor**: on the host `docker compose pull && docker compose up -d`, or rebuild.
- **Upgrade Zabbix minor/major**: take a manual RDS snapshot first
  (`aws rds create-db-snapshot --db-instance-identifier netmon-zabbix --db-snapshot-identifier pre-7x-upgrade`),
  bump `zabbix_version`, `terraform apply` (only the launch template changes), rebuild. The
  server container migrates the schema on start.
- **Launch template changes** (new AMI, edited `bootstrap.sh`) do not touch the running host.
  They take effect on the next launch. Roll deliberately with the self-heal command.
- **RDS changes** wait for the Sunday 03:00-04:00 MT maintenance window (`apply_immediately = false`).
- **Never** `terraform destroy` casually: RDS, the EIP, and the Caddy state bucket are `prevent_destroy`.
- **Editing `bootstrap.sh`**: the repo's Claude Code guard blocks Bash commands containing the
  secret-fetch CLI string, even as heredoc content. Edit the file with a file tool, not a shell heredoc.

## Phase 2: baked AMI with Packer

Once the stack is proven, a Packer image (Docker, awscli, jq, zabbix-agent2 installed and the
three images pre-pulled) cuts a rebuild from ~5 minutes to ~1 and removes the boot-time
dependency on apt mirrors, Docker Hub, and repo.zabbix.com. Model it on
`/home/jade/git/packer/aws-ubuntu.pkr.hcl`; tag the AMI `Role=netmon-zabbix`, switch
`data.aws_ami` to `owners = ["self"]` behind a `use_baked_ami` variable, and drop steps 1 and 8
from `bootstrap.sh` when it is set.

## Terraform state

S3 `boost.cloudformation` / `Terraform_state_files/production/zabbix.tfstate`, S3-native
locking (`use_lockfile`), bucket versioned and encrypted. The provider lockfile
`production/.terraform.lock.hcl` is committed on purpose. No secrets are in state: the RDS
password is RDS-managed in Secrets Manager and Terraform only sees its ARN.
