#!/usr/bin/env bash
# ==============================================================
# deploy-service.sh
# Deploy a new Podman container service into the secure admin stack.
#
# Creates two files per service:
#   /etc/containers/systemd/<name>.container  — Quadlet unit
#   /etc/traefik/config/<name>.yaml           — Traefik route
#
# Usage:
#   sudo ./deploy-service.sh [OPTIONS]
#
# Options:
#   -n, --name     <name>     Service name (used for filenames and container name)
#   -i, --image    <image>    Container image (e.g. myapp:latest)
#   -p, --port     <port>     Internal container port (e.g. 8080)
#   -d, --domain   <domain>   Full hostname for this service (e.g. app.example.com)
#   -e, --env      <KEY=VAL>  Environment variable (repeatable)
#   -v, --volume   <src:dst>  Volume mount — src must be under /data/containers/
#                             (repeatable; :Z SELinux label added automatically)
#   --admin                   Restrict to VPN + Authelia (applies admin-chain middleware)
#   --dry-run                 Print generated files without writing them
#   -h, --help                Show this help
#
# Examples:
#   # Public web app on app.example.com
#   sudo ./deploy-service.sh \
#     --name myapp \
#     --image myapp:latest \
#     --port 8080 \
#     --domain app.example.com
#
#   # VPN-restricted admin tool with persistent data and env var
#   sudo ./deploy-service.sh \
#     --name mytool \
#     --image mytool:latest \
#     --port 3000 \
#     --domain tool.example.com \
#     --admin \
#     --volume /data/containers/mytool:/app/data \
#     --env DATABASE_URL=sqlite:///app/data/db.sqlite3
#
# ==============================================================

set -euo pipefail

# --------------------------------------------------------------
# Defaults
# --------------------------------------------------------------
NAME=""
IMAGE=""
PORT=""
DOMAIN=""
ADMIN=false
DRY_RUN=false
ENV_VARS=()
VOLUMES=()

TRAEFIK_CONFIG_DIR="/etc/traefik/config"
QUADLET_DIR="/etc/containers/systemd"
DATA_DIR="/data/containers"

# --------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------
usage() {
  sed -n '/^# Usage:/,/^# ==/p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)    NAME="$2";   shift 2 ;;
    -i|--image)   IMAGE="$2";  shift 2 ;;
    -p|--port)    PORT="$2";   shift 2 ;;
    -d|--domain)  DOMAIN="$2"; shift 2 ;;
    -e|--env)     ENV_VARS+=("$2"); shift 2 ;;
    -v|--volume)  VOLUMES+=("$2");  shift 2 ;;
    --admin)      ADMIN=true;  shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------
# Validation
# --------------------------------------------------------------
errors=()
[[ -z "$NAME" ]]   && errors+=("--name is required")
[[ -z "$IMAGE" ]]  && errors+=("--image is required")
[[ -z "$PORT" ]]   && errors+=("--port is required")
[[ -z "$DOMAIN" ]] && errors+=("--domain is required")

if [[ ${#errors[@]} -gt 0 ]]; then
  for err in "${errors[@]}"; do echo "Error: $err" >&2; done
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Error: --port must be a number between 1 and 65535" >&2
  exit 1
fi

# --------------------------------------------------------------
# Build file contents
# --------------------------------------------------------------

# Quadlet .container file
QUADLET_CONTENT="[Unit]
Description=${NAME} container service
After=local-fs.target network-online.target
Requires=local-fs.target

[Container]
Image=${IMAGE}
PublishPort=127.0.0.1:${PORT}:${PORT}
"

for env_var in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
  QUADLET_CONTENT+="Environment=${env_var}
"
done

for vol in "${VOLUMES[@]+"${VOLUMES[@]}"}"; do
  # Append :Z for SELinux label if not already present
  [[ "$vol" != *:Z* ]] && vol="${vol}:Z"
  QUADLET_CONTENT+="Volume=${vol}
"
done

QUADLET_CONTENT+="
[Service]
Restart=always

[Install]
WantedBy=multi-user.target"

# Traefik route file
if [[ "$ADMIN" == true ]]; then
  MIDDLEWARE_BLOCK="      middlewares:
        - admin-chain   # VPN (ipAllowList) + Authelia forwardAuth"
else
  MIDDLEWARE_BLOCK="      # No middleware — public service"
fi

TRAEFIK_CONTENT="http:
  routers:
    ${NAME}:
      rule: \"Host(\`${DOMAIN}\`)\"
      entryPoints:
        - websecure
      service: ${NAME}-svc
${MIDDLEWARE_BLOCK}
      tls:
        certResolver: cloudflare

  services:
    ${NAME}-svc:
      loadBalancer:
        servers:
          - url: \"http://127.0.0.1:${PORT}\""

# --------------------------------------------------------------
# Output
# --------------------------------------------------------------
QUADLET_FILE="${QUADLET_DIR}/${NAME}.container"
TRAEFIK_FILE="${TRAEFIK_CONFIG_DIR}/${NAME}.yaml"
DATA_PATH="${DATA_DIR}/${NAME}"

echo ""
echo "=== Quadlet unit: ${QUADLET_FILE} ==="
echo "$QUADLET_CONTENT"
echo ""
echo "=== Traefik route: ${TRAEFIK_FILE} ==="
echo "$TRAEFIK_CONTENT"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run — no files written."
  exit 0
fi

# --------------------------------------------------------------
# Write files
# --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root (use sudo)" >&2
  exit 1
fi

# Create persistent data directory on block volume
mkdir -p "$DATA_PATH"
echo "Created data directory: ${DATA_PATH}"

# Write Quadlet unit
echo "$QUADLET_CONTENT" > "$QUADLET_FILE"
echo "Written: ${QUADLET_FILE}"

# Write Traefik route
echo "$TRAEFIK_CONTENT" > "$TRAEFIK_FILE"
echo "Written: ${TRAEFIK_FILE}"

# Reload systemd to pick up the new Quadlet unit
systemctl daemon-reload
systemctl enable --now "$NAME"
echo "Service enabled and started: ${NAME}"

echo ""
echo "Traefik will pick up ${TRAEFIK_FILE} within seconds."
echo "Verify: systemctl status ${NAME}"

# Save deployment manifest to /data/apps/ so this service is automatically
# reconstructed on VM replacement (see app-integration-guide.md Section 15.2)
MANIFEST_DIR="/data/apps"
MANIFEST_FILE="${MANIFEST_DIR}/${NAME}.sh"

mkdir -p "$MANIFEST_DIR"

{
  echo "#!/usr/bin/env bash"
  echo "# Auto-generated deployment manifest for ${NAME}"
  echo "# Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Re-run this script to restore Quadlet and Traefik config after VM replacement."
  echo "$(realpath "$0") \\"
  echo "  --name ${NAME} \\"
  echo "  --image ${IMAGE} \\"
  echo "  --port ${PORT} \\"
  echo "  --domain ${DOMAIN} \\"
  for vol in "${VOLUMES[@]+"${VOLUMES[@]}"}"; do
    echo "  --volume ${vol} \\"
  done
  for env_var in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    echo "  --env ${env_var} \\"
  done
  [[ "$ADMIN" == "true" ]] && echo "  --admin \\"
  echo '  "$@"'
} > "$MANIFEST_FILE"
chmod 755 "$MANIFEST_FILE"
echo "Deployment manifest saved: ${MANIFEST_FILE}"
