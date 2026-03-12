#!/usr/bin/env bash
# setup.sh — One-shot Ceph lab finalisation: S3 user, IAM, Dashboard.
# Runs via the 'setup' compose service after the cluster services are up.
# Variables come from the compose env_file (.env); all have sensible defaults.
#
# NOT handled here (already done by docker-compose services):
#   - RGW realm/zonegroup/zone creation + period commit  → rgw container startup
#   - Dashboard package install + module enable           → mgr container startup

set -euo pipefail

# ─── Variables (with defaults) ───────────────────────────────────────────────

RGW_PORT="${RGW_PORT:-7480}"
RGW_DNS_NAME="${RGW_DNS_NAME:-localhost}"
RGW_STS_KEY="${RGW_STS_KEY:-s3cretSTSkey1234}"   # must be exactly 16 bytes (AES-128)

DASHBOARD_PORT="${DASHBOARD_PORT:-8443}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-admin}"

S3_USER="${S3_USER:-s3user}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-s3accesskey12345}"
S3_SECRET_KEY="${S3_SECRET_KEY:-s3secretkey12345}"

IAM_UID="${IAM_UID:-iamadmin}"
IAM_ACCESS_KEY="${IAM_ACCESS_KEY:-iamaccess123456}"
IAM_SECRET_KEY="${IAM_SECRET_KEY:-iamsecret1234567}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
info() { echo "    $*"; }
ok()   { echo "    ✔ $*"; }

# ─── Step 1: Cluster status ──────────────────────────────────────────────────
# mgr + rgw healthchecks already passed before this script runs, so the
# cluster is guaranteed to be up and MGR is active.

log "Cluster status:"
ceph -s
echo ""

# ─── Step 2: Enable optional MGR modules ─────────────────────────────────────

log "Enabling MGR modules: prometheus..."
ceph mgr module enable prometheus --force || true
ok "MGR modules enabled."

# ─── Step 3: Cluster-wide RGW config ─────────────────────────────────────────
# Stored in the monitor config DB; picked up by radosgw on start/restart.
# Realm/zone creation is handled by the rgw container startup script.

log "Applying cluster-wide RGW config..."
ceph config set client.rgw rgw_enable_apis     "s3,iam,sts,admin,swift"
ceph config set client.rgw rgw_s3_auth_use_sts true
# NOTE: rgw_sts_key is NOT set in the config DB. The running radosgw process
# reads config at startup — a config DB change only takes effect after restart.
# The key is passed directly via --rgw-sts-key in docker-compose.yml instead.
ceph config rm  client.rgw debug_rgw 2>/dev/null || true
# NOTE: rgw_dns_name is NOT set in the config DB. When set via 'ceph config set',
# the dashboard module reads it and uses it as the admin API hostname instead of
# the zone endpoint (http://rgw:7480), causing 'Connection refused'. It is passed
# directly to the radosgw process via --rgw-dns-name in docker-compose.yml.
ok "RGW config applied."

# ─── Step 4: S3 demo user ────────────────────────────────────────────────────

log "Creating S3 demo user: ${S3_USER}..."
if radosgw-admin user info --uid="${S3_USER}" 2>/dev/null | grep -q '"user_id"'; then
  ok "User '${S3_USER}' already exists, skipping creation."
else
  radosgw-admin user create \
    --uid="${S3_USER}" \
    --display-name="S3 Demo User" \
    --access-key="${S3_ACCESS_KEY}" \
    --secret-key="${S3_SECRET_KEY}" >/dev/null
  ok "User '${S3_USER}' created."
fi

# Force keys to match .env in case of a re-run with different credentials.
radosgw-admin key create \
  --uid="${S3_USER}" \
  --key-type=s3 \
  --access-key="${S3_ACCESS_KEY}" \
  --secret-key="${S3_SECRET_KEY}" &>/dev/null || true

for cap in "users=*" "buckets=*" "metadata=*" "usage=*" "zone=*" "roles=*" "oidc-provider=*"; do
  radosgw-admin caps add --uid="${S3_USER}" --caps="$cap" &>/dev/null || true
done
ok "S3 demo user ready."

# ─── Step 5: IAM admin user ──────────────────────────────────────────────────

log "Creating IAM admin user: ${IAM_UID}..."
if radosgw-admin user info --uid="${IAM_UID}" 2>/dev/null | grep -q '"user_id"'; then
  ok "User '${IAM_UID}' already exists, skipping."
else
  radosgw-admin user create \
    --uid="${IAM_UID}" \
    --display-name="IAM Admin" \
    --access-key="${IAM_ACCESS_KEY}" \
    --secret-key="${IAM_SECRET_KEY}" >/dev/null
  for cap in "users=*" "roles=*" "oidc-provider=*"; do
    radosgw-admin caps add --uid="${IAM_UID}" --caps="$cap" &>/dev/null || true
  done
  ok "IAM admin user '${IAM_UID}' created."
fi

# ─── Step 6: Demo IAM role ───────────────────────────────────────────────────

log "Creating demo IAM role 'demo-role'..."
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam:::user/'"${S3_USER}"'"},
    "Action": "sts:AssumeRole"
  }]
}'
if radosgw-admin role get --role-name=demo-role 2>/dev/null | grep -q '"RoleName"'; then
  ok "Role 'demo-role' already exists, skipping."
else
  radosgw-admin role create \
    --role-name=demo-role \
    --assume-role-policy-doc="${TRUST_POLICY}" >/dev/null
  ok "IAM role 'demo-role' created."
fi

# ─── Step 7: Configure Dashboard ─────────────────────────────────────────────
# The mgr already installed and enabled the dashboard module at startup.
# Here we disable SSL (HTTP on port 8080) and set credentials.

log "Configuring Ceph Dashboard..."
# Disable SSL so the dashboard serves plain HTTP on port 8080.
ceph config set mgr mgr/dashboard/ssl false
ceph config set mgr mgr/dashboard/server_addr 0.0.0.0
ceph config set mgr mgr/dashboard/server_port "${DASHBOARD_PORT}"

printf '%s' "${DASHBOARD_PASSWORD}" > /tmp/dashpass
if ceph dashboard ac-user-show admin &>/dev/null; then
  ceph dashboard ac-user-set-password admin -i /tmp/dashpass
else
  ceph dashboard ac-user-create admin -i /tmp/dashpass administrator
fi
rm -f /tmp/dashpass
ok "Dashboard configured."

# ─── Step 8: Link RGW credentials to Dashboard ───────────────────────────────

log "Creating RGW system user for dashboard integration..."
if radosgw-admin user info --uid="rgw-admin" 2>/dev/null | grep -q '"user_id"'; then
  ok "RGW system user 'rgw-admin' already exists."
else
  radosgw-admin user create \
    --uid="rgw-admin" \
    --display-name="RGW Dashboard Admin" \
    --system >/dev/null
  ok "RGW system user 'rgw-admin' created."
fi

RGW_ADMIN_ACCESS=$(radosgw-admin user info --uid=rgw-admin \
  | python3 -c "import sys,json; k=json.load(sys.stdin)['keys'][0]; print(k['access_key'])")
RGW_ADMIN_SECRET=$(radosgw-admin user info --uid=rgw-admin \
  | python3 -c "import sys,json; k=json.load(sys.stdin)['keys'][0]; print(k['secret_key'])")

printf '%s' "${RGW_ADMIN_ACCESS}" > /tmp/rgw_access
printf '%s' "${RGW_ADMIN_SECRET}" > /tmp/rgw_secret
# Credentials are set explicitly; host/port/scheme are auto-discovered from the
# zone endpoint (https://rgw:7480). Disable SSL verify for self-signed cert.
ceph dashboard set-rgw-api-access-key -i /tmp/rgw_access
ceph dashboard set-rgw-api-secret-key -i /tmp/rgw_secret
ceph dashboard set-rgw-api-ssl-verify False
rm -f /tmp/rgw_access /tmp/rgw_secret
ok "RGW credentials linked to Dashboard."

log "Restarting dashboard module to apply settings..."
ceph mgr module disable dashboard || true
sleep 5
ceph mgr module enable dashboard
sleep 10
ok "Dashboard module restarted."

# ─── Summary ─────────────────────────────────────────────────────────────────

log "Final MGR services:"
ceph mgr services --format json-pretty 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         Ceph Lab Setup Complete                  ║"
echo "╠══════════════════════════════════════════════════╣"
printf  "║  Dashboard  http://localhost:%-5s              ║\n" "${DASHBOARD_PORT}"
echo "║    User:     admin                               ║"
printf  "║    Password: %-36s║\n" "${DASHBOARD_PASSWORD}"
echo "╠══════════════════════════════════════════════════╣"
printf  "║  S3 / RGW   http://localhost:%-5s              ║\n" "${RGW_PORT}"
printf  "║    User:     %-36s║\n" "${S3_USER}"
printf  "║    Access:   %-36s║\n" "${S3_ACCESS_KEY}"
printf  "║    Secret:   %-36s║\n" "${S3_SECRET_KEY}"
echo "╠══════════════════════════════════════════════════╣"
echo "║  IAM Admin                                       ║"
printf  "║    Access:   %-36s║\n" "${IAM_ACCESS_KEY}"
printf  "║    Secret:   %-36s║\n" "${IAM_SECRET_KEY}"
echo "╠══════════════════════════════════════════════════╣"
echo "║  IAM Role:  demo-role                            ║"
echo "╚══════════════════════════════════════════════════╝"
