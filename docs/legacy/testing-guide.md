# Testing Guide

## OCI Oracle Linux 9 — Secure Admin Stack

> **This document is for contributors and deployers** who want to validate changes to the stack or diagnose issues on a running instance. It covers both pre-deployment validation (what you can check before launching a VM) and incremental live testing on a real OCI instance.

## Table of Contents

1. [Testing Philosophy](#1-testing-philosophy)
2. [Pre-Deployment Validation](#2-pre-deployment-validation)
3. [Incremental Live Testing Strategy](#3-incremental-live-testing-strategy)
4. [Testing Individual Components](#4-testing-individual-components)
5. [Full Stack Verification](#5-full-stack-verification)
6. [Testing deploy-service.sh](#6-testing-deploy-servicesh)
7. [Common Failure Patterns](#7-common-failure-patterns)

## 1. Testing Philosophy

The cloud-init script cannot be unit tested in isolation — it provisions OS-level state, installs packages, creates systemd units, and configures services that only exist on a live Oracle Linux 9 instance. However, most failure modes fall into predictable categories that can be caught either before deployment (syntax and logic errors) or incrementally on a live instance (configuration and service errors).

The recommended approach is:

1. **Validate the template locally** before deploying — catch YAML syntax errors, variable substitution issues, and shell script logic problems without consuming an instance
2. **Test incrementally on a live instance** — run each `runcmd` block manually in sequence rather than relying on cloud-init to run the full script, so failures are isolated immediately
3. **Use `verify-stack.sh`** for final end-to-end confirmation

The OCI Free Tier provides two AMD Micro instances and up to 4 ARM (Ampere A1) cores at no cost. Use a free-tier instance for testing before deploying to a production instance.

## 2. Pre-Deployment Validation

Run all of the following locally before generating `cloud-config.yaml`.

### 2.1 Validate YAML Syntax

```bash
# Install yamllint if not present
pip install yamllint

# Validate the template (before envsubst)
yamllint cloud-config.example.yaml
```

`yamllint` will catch indentation errors, duplicate keys, and invalid YAML constructs. Note that `${VARIABLE}` placeholders are valid YAML string content and will not cause errors.

### 2.2 Validate After Variable Substitution

```bash
# Generate cloud-config.yaml from your .env file
export $(cat .env | xargs)
envsubst '${DOMAIN} ${ACME_EMAIL} ${ADMIN_EMAIL} ${CF_SECRET_OCID} ${AUTH_SECRET_OCID} ${WG_SECRET_OCID}' \
  < cloud-config.example.yaml > cloud-config.yaml

# Validate the generated file
yamllint cloud-config.yaml
```

Also visually inspect the generated file to confirm all placeholders were substituted:

```bash
# Should return nothing if all variables were substituted
grep '\${' cloud-config.yaml
```

### 2.3 Validate Shell Scripts Within the YAML

Extract and lint the `runcmd` shell blocks:

```bash
# Install shellcheck if not present (macOS: brew install shellcheck)
# Extract shell content from runcmd blocks and check syntax
grep -A 1000 '^runcmd:' cloud-config.yaml \
  | grep -v '^runcmd:' \
  | sed 's/^  - |//' \
  | sed 's/^  - //' \
  | shellcheck -s bash -
```

This is approximate — shellcheck works best on complete standalone scripts. For a more thorough check, copy individual `runcmd` blocks into temporary `.sh` files and run `shellcheck` on each.

### 2.4 Validate cloud-init Schema

```bash
# cloud-init includes a schema validator
cloud-init schema --config-file cloud-config.yaml
```

This requires `cloud-init` to be installed locally (available on Linux; on macOS install via a Linux VM or container). It validates the cloud-init key structure — `packages`, `write_files`, `runcmd` — but does not execute anything.

### 2.5 Check Variable Substitution Completeness

Verify all six variables are present in `.env` and non-empty:

```bash
while IFS='=' read -r key value; do
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
  if [[ -z "$value" ]]; then
    echo "EMPTY: $key"
  else
    echo "OK:    $key"
  fi
done < .env
```

## 3. Incremental Live Testing Strategy

When cloud-init fails on a live instance, the full script has already run (or partially run) and it can be difficult to isolate which step failed. The recommended approach for testing changes is to run each `runcmd` block manually in the correct sequence.

### 3.1 Prepare the Instance

1. Launch an OCI instance with Oracle Linux 9 and attach a block volume
2. **Do not use the cloud-config.yaml as user data** — leave the User Data field empty
3. SSH into the instance as `opc`
4. Copy the `write_files` content manually (or run the cloud-init write_files phase only):

```bash
# Run only the write_files and packages phases, not runcmd
sudo cloud-init init
sudo cloud-init modules --mode=config
# Do NOT run: sudo cloud-init modules --mode=final
```

### 3.2 Run runcmd Blocks Individually

Copy each `runcmd` block from `cloud-config.yaml` and run it as root. Stop at the first error and resolve it before continuing.

The blocks in order and what each one tests:

| Step | Block                             | What to verify after                                                                                                              |
| ---- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Boot volume expansion             | `df -h /` shows expanded root filesystem                                                                                          |
| 2    | Block storage setup               | `mountpoint /data` exits 0; `cat /etc/fstab` shows UUID entry                                                                     |
| 3    | Persistent directory structure    | `ls /data/` shows expected subdirectories                                                                                         |
| 4    | Symlinks                          | `readlink -f /etc/traefik/letsencrypt` returns `/data/traefik/letsencrypt`                                                        |
| 5    | Traefik directories and ownership | `ls -la /etc/traefik/` shows `traefik:traefik` ownership                                                                          |
| 6    | Container tools                   | `podman --version`; `podman images` shows authelia and wg-easy pulled                                                             |
| 7    | Vault secrets                     | `cat /etc/traefik/env` shows `CF_DNS_API_TOKEN=<token>`; `/run/authelia-bootstrap.tmp` exists                                     |
| 8    | Authelia bootstrap                | `/data/authelia/env` exists; `/data/authelia/config/configuration.yml` exists; `/data/authelia/config/users_database.yaml` exists |
| 9    | wg-easy env                       | `/data/containers/wg-easy/env` exists; `/run/wg-bootstrap.tmp` does not exist                                                     |
| 10   | SELinux contexts                  | `ausearch -m avc -ts recent \| grep traefik` returns nothing                                                                      |
| 11   | System hardening                  | `getenforce` returns `Enforcing`; `systemctl is-active auditd` returns `active`                                                   |
| 12   | Traefik binary                    | `/usr/local/bin/traefik version` prints version                                                                                   |
| 13   | IP forwarding                     | `sysctl net.ipv4.ip_forward` returns `1`                                                                                          |
| 14   | Journal persistence               | `/var/log/journal/` directory exists                                                                                              |
| 15   | Firewall rules                    | `firewall-cmd --list-all` shows http, https, 51820/udp                                                                            |
| 16   | Service start                     | `systemctl is-active traefik authelia wg-easy cockpit pmcd pmlogger`                                                              |

### 3.3 Running a Block

```bash
# Example: running the block storage setup block
sudo bash << 'BLOCK'
BLOCK_DEV=""
for dev in /dev/oracleoci/oraclevdb /dev/sdb /dev/vdb; do
  [ -b "$dev" ] && BLOCK_DEV="$dev" && break
done

if [ -n "$BLOCK_DEV" ]; then
  if ! blkid "$BLOCK_DEV" | grep -q TYPE; then
    mkfs.xfs "$BLOCK_DEV"
    echo "Formatted $BLOCK_DEV as XFS"
  fi
  mkdir -p /data
  UUID=$(blkid -s UUID -o value "$BLOCK_DEV")
  if ! grep -q "UUID=$UUID" /etc/fstab; then
    echo "UUID=$UUID /data xfs defaults,noatime 0 2" >> /etc/fstab
  fi
  mount /data || true
else
  echo "WARNING: No block device found — persistent storage unavailable"
fi
BLOCK
```

### 3.4 After All Blocks Pass

Once all blocks have run successfully, run the full verification:

```bash
sudo ./verify-stack.sh
```

## 4. Testing Individual Components

### 4.1 Traefik Configuration

```bash
# Validate Traefik static config syntax
/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yaml --help > /dev/null
# Traefik exits 0 if config is parseable

# Check Traefik is listening
ss -tlnp | grep traefik

# Check Traefik logs for errors
sudo journalctl -u traefik.service -n 50

# Test HTTP → HTTPS redirect
curl -I http://traefik.yourdomain.com
# Expected: 301 redirect to https://
```

### 4.2 Authelia

```bash
# Check Authelia container is running
sudo podman ps | grep authelia

# Check Authelia logs
sudo journalctl -u authelia.service -n 50

# Test Authelia API is reachable from localhost
curl -s http://127.0.0.1:9091/api/health
# Expected: {"status":"OK"}

# Verify Authelia configuration parses correctly
sudo podman exec authelia authelia validate-config --config /config/configuration.yml
```

### 4.3 wg-easy

```bash
# Check wg-easy container is running
sudo podman ps | grep wg-easy

# Check wg-easy logs
sudo journalctl -u wg-easy.service -n 50

# Check WireGuard interface is up
sudo wg show
# Expected: interface wg0, public key, listening port 51820

# Test wg-easy API is reachable from localhost (before VPN peer added)
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:51821
# Expected: 200 (login page)
```

### 4.4 Cockpit

```bash
# Check Cockpit socket is active
systemctl is-active cockpit.socket

# Test Cockpit is reachable from localhost
curl -sk -o /dev/null -w "%{http_code}" http://127.0.0.1:9090
# Expected: 200
```

### 4.5 TLS Certificate Issuance

```bash
# Watch Traefik logs for ACME activity (run immediately after first start)
sudo journalctl -u traefik.service -f | grep -i "acme\|certificate\|challenge\|cloudflare"

# Check acme.json is being written
watch -n 5 "stat -c '%s bytes' /data/traefik/letsencrypt/acme.json 2>/dev/null || echo 'not yet created'"

# Once acme.json is > 1KB, verify certificate content
cat /data/traefik/letsencrypt/acme.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for resolver, content in data.items():
    for cert in content.get('Certificates', []):
        print(cert.get('domain', {}).get('main', 'unknown'))
"
```

### 4.6 SELinux

```bash
# Check for any AVC denials across all services
sudo ausearch -m avc -ts today | grep -E "traefik|authelia|podman"

# If denials exist, generate a local policy
sudo ausearch -m avc -ts today | audit2allow -M local-stack
sudo semodule -i local-stack.pp

# Verify Traefik binary has correct context
ls -Z /usr/local/bin/traefik
# Expected: system_u:object_r:bin_t:s0
```

## 5. Full Stack Verification

After the incremental steps pass, run the automated verification script:

```bash
sudo ./verify-stack.sh
```

Then perform the manual end-to-end test:

1. Add a WireGuard peer via the SSH port-forward method (see `stack-guide.md` Section 10.1)
2. Connect the WireGuard client on a test device
3. Open each admin URL in a browser:
   - `https://traefik.yourdomain.com` → Authelia login → Traefik dashboard
   - `https://metrics.yourdomain.com/metrics` → Authelia login → Prometheus output
   - `https://cockpit.yourdomain.com` → Authelia login → Cockpit OS console
   - `https://wg.yourdomain.com` → Authelia login → wg-easy peer management
4. Disconnect WireGuard and confirm all admin URLs return `403 Forbidden`
5. Reconnect WireGuard and confirm access is restored

## 6. Testing deploy-service.sh

### 6.1 Dry Run First

Always use `--dry-run` before deploying a new service:

```bash
sudo ./deploy-service.sh \
  --name testapp \
  --image nginx:latest \
  --port 8080 \
  --domain test.yourdomain.com \
  --dry-run
```

Inspect the generated Quadlet and Traefik files printed to stdout. Verify indentation, port binding, volume paths, and middleware are correct before writing to disk.

### 6.2 Deploy a Test Service

```bash
# Deploy a simple nginx container as a public test service
sudo ./deploy-service.sh \
  --name testapp \
  --image nginx:latest \
  --port 8080 \
  --domain test.yourdomain.com

# Verify the service started
sudo systemctl status testapp

# Verify Traefik picked up the route (check Traefik dashboard or logs)
sudo journalctl -u traefik.service -n 20

# Test the endpoint (after DNS propagates)
curl -I https://test.yourdomain.com
# Expected: 200 OK with nginx response
```

### 6.3 Verify the Manifest

```bash
# Check the manifest was saved
cat /data/apps/testapp.sh

# Test manifest replay (simulates VM replacement)
sudo bash /data/apps/testapp.sh --dry-run
```

### 6.4 Clean Up the Test Service

```bash
sudo systemctl disable --now testapp
sudo rm /etc/containers/systemd/testapp.container
sudo rm /etc/traefik/config/testapp.yaml
sudo rm /data/apps/testapp.sh
sudo systemctl daemon-reload
```

## 7. Common Failure Patterns

### Block volume not found

**Symptom:** `WARNING: No block device found` in cloud-init output; `/data` not mounted.

**Cause:** Block volume was not attached before instance launch, or the device path differs from the probed paths.

**Fix:** Verify the volume is attached in OCI Console. Check `lsblk` to find the actual device path and add it to the probe list in the script.

### OCI Vault secret fetch fails

**Symptom:** `cloud-init` fails at the Vault secrets step; `/etc/traefik/env` contains the placeholder value.

**Causes and fixes:**

- Instance Principal not configured: verify the instance's dynamic group and IAM policy (see `stack-guide.md` Section 7.1)
- Wrong secret OCID: verify OCIDs in `.env` against OCI Console
- `oci-cli` not installed: check if the DNF install step succeeded

```bash
# Test Instance Principal auth manually
oci secrets secret-bundle get \
  --secret-id <CF_SECRET_OCID> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d
```

### Traefik fails to start

**Symptom:** `traefik.service` is failed; `journalctl -u traefik.service` shows config errors.

**Causes:**

- Syntax error in `traefik.yaml` or a dynamic config file — use `yamllint` locally first
- SELinux denying access to config files — check `ausearch -m avc -ts recent`
- Port 80 or 443 already in use — check `ss -tlnp | grep ':80\|:443'`

### Authelia container fails to start

**Symptom:** `authelia.service` is failed; `journalctl -u authelia.service` shows container errors.

**Causes:**

- `/data/authelia/config/configuration.yml` not copied from template — check if bootstrap ran
- Wrong secret env var names — check `data/authelia/env` contains the correct Authelia v4 variable names
- Image not pulled — verify `podman images | grep authelia`

### TLS certificates not issued

**Symptom:** `acme.json` exists but is smaller than 1 KB after 5+ minutes.

**Causes:**

- DNS records do not exist or have not propagated — verify with `dig +short traefik.yourdomain.com`
- Cloudflare token lacks `Zone → DNS → Edit` permission on the zone
- Cloudflare token stored incorrectly in Vault — verify secret content matches the token exactly (no trailing newlines)

```bash
# Check Traefik ACME logs
sudo journalctl -u traefik.service | grep -i "acme\|cloudflare\|challenge\|error"
```

### WireGuard interface not up

**Symptom:** `wg show wg0` returns an error; `wg-easy.service` is failed.

**Causes:**

- `NET_ADMIN` capability not available — check if the container was started with the correct capabilities
- `net.ipv4.ip_forward` not set — verify `sysctl net.ipv4.ip_forward` returns `1`
- wg-easy database not initialised — check `/data/containers/wg-easy/` for database files

```bash
sudo journalctl -u wg-easy.service -n 50
sudo podman logs wg-easy
```

### SELinux blocking services

**Symptom:** Services start but behave incorrectly; `ausearch -m avc -ts recent` shows denials.

**Fix:**

```bash
# Generate and apply a local policy for any denials
sudo ausearch -m avc -ts recent | audit2allow -M local-stack
sudo semodule -i local-stack.pp
sudo systemctl restart traefik.service
```

If denials persist, open an issue with the full `ausearch` output — the SELinux file contexts in the script may need updating for your specific OCI image version.
