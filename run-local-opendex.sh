#!/usr/bin/env bash

# FILE: run-local-opendex.sh
# Purpose: Starts a local relay plus the public bridge for OSS and self-host workflows.
# Layer: developer utility
# Exports: none
# Depends on: node, bun, curl, relay/server.js, phodex-bridge/bin/opendex.js

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="${ROOT_DIR}/phodex-bridge"
RELAY_DIR="${ROOT_DIR}/relay"
RELAY_SERVER_MODULE="${RELAY_DIR}/server.js"

RELAY_BIND_HOST="${RELAY_BIND_HOST:-0.0.0.0}"
RELAY_PORT="${RELAY_PORT:-9000}"
RELAY_HOSTNAME="${RELAY_HOSTNAME:-}"
EXTERNAL_RELAY_URL="${OPENDEX_RELAY:-${REMODEX_RELAY:-${PHODEX_RELAY:-}}}"
RELAY_BRIDGE_HOST=""
RELAY_PID=""
BRIDGE_SERVICE_STARTED="false"
STOP_BRIDGE_ON_EXIT="false"

log() {
  echo "[run-local-opendex] $*"
}

die() {
  echo "[run-local-opendex] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./run-local-opendex.sh [options]

Options:
  --hostname HOSTNAME   Hostname or IP the iPhone should use to reach the relay
  --relay-url URL       Use an existing ws:// or wss:// relay instead of starting a LAN relay
  --bind-host HOST      Interface/address the local relay should listen on
  --port PORT           Relay port to listen on
  --help                Show this help text

Defaults:
  --bind-host           0.0.0.0
  --port                9000
  --hostname            macOS LocalHostName.local, then hostname, then localhost
  --relay-url           reuse OPENDEX_RELAY / REMODEX_RELAY / PHODEX_RELAY when set
EOF
}

require_value() {
  local flag_name="$1"
  local remaining_args="$2"
  [[ "${remaining_args}" -ge 2 ]] || die "${flag_name} requires a value."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)
        require_value "--hostname" "$#"
        RELAY_HOSTNAME="$2"
        shift 2
        ;;
      --bind-host)
        require_value "--bind-host" "$#"
        RELAY_BIND_HOST="$2"
        shift 2
        ;;
      --relay-url)
        require_value "--relay-url" "$#"
        EXTERNAL_RELAY_URL="$2"
        shift 2
        ;;
      --port)
        require_value "--port" "$#"
        RELAY_PORT="$2"
        shift 2
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown argument: $1"
        ;;
    esac
  done
}

default_hostname() {
  if [[ -n "${RELAY_HOSTNAME}" ]]; then
    printf '%s\n' "${RELAY_HOSTNAME}"
    return
  fi

  if command -v scutil >/dev/null 2>&1; then
    local local_host_name
    local_host_name="$(scutil --get LocalHostName 2>/dev/null || true)"
    local_host_name="${local_host_name//[$'\r\n']}"
    if [[ -n "${local_host_name}" ]]; then
      printf '%s.local\n' "${local_host_name}"
      return
    fi
  fi

  local host_name
  host_name="$(hostname 2>/dev/null || true)"
  host_name="${host_name//[$'\r\n']}"
  if [[ -n "${host_name}" ]]; then
    printf '%s\n' "${host_name}"
    return
  fi

  printf 'localhost\n'
}

healthcheck_host() {
  case "${RELAY_BIND_HOST}" in
    ""|"0.0.0.0")
      printf '127.0.0.1\n'
      ;;
    "::")
      printf '[::1]\n'
      ;;
    *)
      printf '%s\n' "${RELAY_BIND_HOST}"
      ;;
  esac
}

cleanup() {
  if [[ "${BRIDGE_SERVICE_STARTED}" == "true" && "${STOP_BRIDGE_ON_EXIT}" == "true" ]]; then
    (
      cd "${BRIDGE_DIR}"
      node ./bin/opendex.js stop >/dev/null 2>&1 || true
    )
  fi

  if [[ -n "${RELAY_PID}" ]] && kill -0 "${RELAY_PID}" 2>/dev/null; then
    kill "${RELAY_PID}" 2>/dev/null || true
    wait "${RELAY_PID}" 2>/dev/null || true
  fi
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "Missing required command: ${command_name}"
}

ensure_node_version() {
  local node_version
  local node_major

  node_version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  [[ -n "${node_version}" ]] || die "Unable to determine the installed Node.js version."

  node_major="${node_version%%.*}"
  [[ "${node_major}" =~ ^[0-9]+$ ]] || die "Unable to parse the installed Node.js version: ${node_version}"
  (( node_major >= 18 )) || die "Please use Node.js 18 or newer."
}

ensure_prerequisites() {
  require_command node
  require_command bun
  require_command curl
  ensure_node_version
}

ensure_hostname_belongs_to_this_mac() {
  node -e '
const dns = require("node:dns");
const os = require("node:os");

const hostname = process.argv[1];
const localAddresses = new Set(["127.0.0.1", "::1"]);
for (const addresses of Object.values(os.networkInterfaces())) {
  for (const address of addresses || []) {
    if (address && typeof address.address === "string" && address.address) {
      localAddresses.add(address.address);
    }
  }
}

dns.lookup(hostname, { all: true }, (error, records) => {
  if (error || !Array.isArray(records) || records.length === 0) {
    process.exit(1);
    return;
  }

  const isLocal = records.some((record) => localAddresses.has(record.address));
  process.exit(isLocal ? 0 : 1);
});
' "${RELAY_HOSTNAME}" || die "The advertised hostname '${RELAY_HOSTNAME}' does not resolve back to this Mac.
Pass --hostname with a LAN hostname or IP address that points to this machine so the iPhone can connect."
}

package_dependencies_installed() {
  local package_dir="$1"

  node -e '
const { createRequire } = require("node:module");
const fs = require("node:fs");
const path = require("node:path");

const packageDir = process.argv[1];
const packageJsonPath = path.join(packageDir, "package.json");
if (!fs.existsSync(packageJsonPath)) {
  process.exit(1);
}

const pkg = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
const dependencyNames = Object.keys(pkg.dependencies || {});
const requireFromPackage = createRequire(packageJsonPath);

for (const dependencyName of dependencyNames) {
  try {
    requireFromPackage.resolve(`${dependencyName}/package.json`);
  } catch {
    process.exit(1);
  }
}

process.exit(0);
' "${package_dir}"
}

ensure_package_dependencies() {
  local package_dir="$1"
  if package_dependencies_installed "${package_dir}"; then
    return
  fi

  log "Installing dependencies in ${package_dir}"
  (cd "${package_dir}" && bun install)
}

has_external_relay() {
  [[ -n "${EXTERNAL_RELAY_URL}" ]]
}

bridge_relay_url() {
  if has_external_relay; then
    printf '%s\n' "${EXTERNAL_RELAY_URL}"
    return
  fi

  printf 'ws://%s:%s/relay\n' "${RELAY_HOSTNAME}" "${RELAY_PORT}"
}

validate_external_relay_url() {
  [[ "${EXTERNAL_RELAY_URL}" =~ ^wss?://.+$ ]] || die "External relay URL must start with ws:// or wss://"
}

ensure_port_available() {
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"${RELAY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port ${RELAY_PORT} is already in use. Stop the existing listener or rerun with --port."
  fi
}

wait_for_relay() {
  local attempt
  local probe_host

  probe_host="$(healthcheck_host)"
  for attempt in {1..20}; do
    if [[ -n "${RELAY_PID}" ]] && ! kill -0 "${RELAY_PID}" 2>/dev/null; then
      die "Relay process exited before becoming healthy."
    fi
    if curl --silent --fail "http://${probe_host}:${RELAY_PORT}/health" >/dev/null 2>&1; then
      return
    fi
    sleep 0.5
  done

  die "Relay did not become healthy on port ${RELAY_PORT}."
}

start_embedded_relay() {
  log "Starting relay on ${RELAY_BIND_HOST}:${RELAY_PORT}"

  RELAY_BIND_HOST="${RELAY_BIND_HOST}" \
  RELAY_PORT="${RELAY_PORT}" \
  RELAY_SERVER_MODULE="${RELAY_SERVER_MODULE}" \
  node <<'NODE' &
const { createRelayServer } = require(process.env.RELAY_SERVER_MODULE);

const host = process.env.RELAY_BIND_HOST || "0.0.0.0";
const port = Number.parseInt(process.env.RELAY_PORT || "9000", 10);
const { server } = createRelayServer();

server.listen(port, host, () => {
  console.log(`[relay] listening on http://${host}:${port}`);
});

function shutdown(signal) {
  console.log(`[relay] shutting down (${signal})`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5_000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
NODE

  RELAY_PID=$!
}

print_summary() {
  local relay_url
  relay_url="$(bridge_relay_url)"

  if has_external_relay; then
    cat <<EOF
[run-local-opendex] Configuration
  Relay mode      : external
  Relay URL       : ${relay_url}
  Bridge service  : launchd managed
EOF
    return
  fi

  cat <<EOF
[run-local-opendex] Configuration
  Relay bind host : ${RELAY_BIND_HOST}
  Relay port      : ${RELAY_PORT}
  Relay hostname  : ${RELAY_HOSTNAME}
  Bridge host     : ${RELAY_BRIDGE_HOST}
  Relay URL       : ${relay_url}
EOF
}

start_bridge() {
  local relay_url
  relay_url="$(bridge_relay_url)"
  log "Starting bridge"
  cd "${BRIDGE_DIR}"
  OPENDEX_RELAY="${relay_url}" node ./bin/opendex.js up
  BRIDGE_SERVICE_STARTED="true"
  STOP_BRIDGE_ON_EXIT="$([[ -n "${RELAY_PID}" ]] && printf 'true' || printf 'false')"
}

hold_open() {
  if has_external_relay; then
    log "Bridge service is running against $(bridge_relay_url)."
    log "You only need the QR above the first time this iPhone pairs with this Mac + relay."
    log "Later reconnects can reuse the saved trusted pairing over the same relay."
    return
  fi

  log "Local relay is ready. Keep this terminal open while testing."
  log "Press Ctrl+C to stop both the local relay and the Opendex bridge service."
  wait "${RELAY_PID}"
}

trap cleanup EXIT INT TERM

parse_args "$@"

ensure_prerequisites
ensure_package_dependencies "${BRIDGE_DIR}"
ensure_package_dependencies "${RELAY_DIR}"

if has_external_relay; then
  validate_external_relay_url
else
  RELAY_HOSTNAME="$(default_hostname)"
  RELAY_BRIDGE_HOST="$(healthcheck_host)"
  ensure_hostname_belongs_to_this_mac
  ensure_port_available
fi

print_summary
if ! has_external_relay; then
  start_embedded_relay
  wait_for_relay
fi
start_bridge
hold_open
