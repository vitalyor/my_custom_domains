#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Vitalyor VPN VPS Test Script
# -----------------------------

SCRIPT_NAME="vitalyor-vpn-test.sh"
VERSION="1.0.0"

# Defaults
LANG_OUT="en"                  # for IP.Check.Place / Check.Place
DO_INSTALL_DEPS=1
RUN_IPREGION=1
RUN_CENSOR_GEO=1
RUN_CENSOR_DPI=1
RUN_RU_IPERF=1
RUN_YABS=1
RUN_IPBLOCK=1                  # "Проверка IP сервера на блокировки зарубежными сервисами" (IP.Check.Place -l en)
RUN_BENCHSH=1
RUN_IPQUALITY_EI=1
RUN_SYSBENCH=1

# Extra
OUTDIR_BASE="${PWD}"
TAG=""
TIMEOUT_SEC="25"               # curl/wget per request
CURL_BIN="curl"
WGET_BIN="wget"

usage() {
  cat <<EOF
$SCRIPT_NAME v$VERSION

Usage:
  sudo bash $SCRIPT_NAME [options]

Options:
  --outdir DIR           Base output directory (default: current dir)
  --tag TAG              Add tag to result folder name (e.g. "th-de-01")
  --lang en|ru           Output language hint (default: en)
  --no-install           Do not install dependencies
  --timeout SEC          Network timeout per request (default: 25)

  --skip-ipregion        Skip ipregion test
  --skip-censor-geoblock Skip censorcheck geoblock mode
  --skip-censor-dpi      Skip censorcheck dpi mode
  --skip-ru-iperf        Skip russian-iperf3-servers test
  --skip-yabs            Skip yabs
  --skip-ipblock         Skip IP.Check.Place -l en
  --skip-bench           Skip bench.sh
  --skip-ipquality        Skip Check.Place -EI
  --skip-sysbench        Skip sysbench cpu run

Examples:
  sudo bash $SCRIPT_NAME --tag th-de-01
  sudo bash $SCRIPT_NAME --outdir /root/tests --tag cs-nl-01 --timeout 35 --lang en
EOF
}

log() { echo "[$(date -Is)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTDIR_BASE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --lang) LANG_OUT="$2"; shift 2 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --no-install) DO_INSTALL_DEPS=0; shift ;;
    --skip-ipregion) RUN_IPREGION=0; shift ;;
    --skip-censor-geoblock) RUN_CENSOR_GEO=0; shift ;;
    --skip-censor-dpi) RUN_CENSOR_DPI=0; shift ;;
    --skip-ru-iperf) RUN_RU_IPERF=0; shift ;;
    --skip-yabs) RUN_YABS=0; shift ;;
    --skip-ipblock) RUN_IPBLOCK=0; shift ;;
    --skip-bench) RUN_BENCHSH=0; shift ;;
    --skip-ipquality) RUN_IPQUALITY_EI=0; shift ;;
    --skip-sysbench) RUN_SYSBENCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$LANG_OUT" == "en" || "$LANG_OUT" == "ru" ]] || die "--lang must be en|ru"

# Need root for installs + some tests
if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root (use: sudo bash $SCRIPT_NAME ...)"
fi

TS="$(date +%Y%m%d-%H%M%S)"
SAFE_TAG=""
if [[ -n "$TAG" ]]; then
  SAFE_TAG="$(echo "$TAG" | tr ' /' '__' | tr -cd '[:alnum:]_.-')"
fi

RUN_NAME="vpn-test_${TS}${SAFE_TAG:+_${SAFE_TAG}}"
OUTDIR="${OUTDIR_BASE%/}/${RUN_NAME}"
mkdir -p "$OUTDIR"

SUMMARY="$OUTDIR/summary.txt"
META="$OUTDIR/meta.txt"

{
  echo "script=$SCRIPT_NAME"
  echo "version=$VERSION"
  echo "timestamp=$TS"
  echo "tag=$SAFE_TAG"
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  echo "kernel=$(uname -r)"
  echo "os=$( (grep -E '^PRETTY_NAME=' /etc/os-release || true) | head -n1 )"
  echo "arch=$(uname -m)"
  echo "lang=$LANG_OUT"
} > "$META"

log "Output directory: $OUTDIR"
log "Writing meta: $META"

# Dependencies
install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget dnsutils ca-certificates jq sysbench mtr-tiny iproute2 netcat-openbsd
}

if [[ "$DO_INSTALL_DEPS" -eq 1 ]]; then
  if have apt-get; then
    log "Installing deps (apt-get)..."
    install_deps_debian |& tee "$OUTDIR/00-install-deps.log"
  else
    log "No apt-get found. Skipping auto-install. Ensure curl/wget/dig/sysbench are installed."
  fi
else
  log "Skipping dependency install (--no-install)."
fi

# Choose curl/wget
have curl || die "curl not found"
have wget || die "wget not found"

# Helper: run command to file with header
run_to_file() {
  local name="$1"; shift
  local file="$OUTDIR/$name"
  {
    echo "===== $name ====="
    echo "date: $(date -Is)"
    echo "cmd: $*"
    echo
    "$@"
    echo
  } |& tee "$file"
}

# Helper: fetch+exec remote script safely-ish (still remote code)
run_remote_bash() {
  local name="$1"
  local url="$2"
  shift 2
  local file="$OUTDIR/$name"
  {
    echo "===== $name ====="
    echo "date: $(date -Is)"
    echo "url: $url"
    echo "args: $*"
    echo
    # Using curl with timeouts; fallback to wget if needed
    if "$CURL_BIN" -fsSL --connect-timeout "$TIMEOUT_SEC" --max-time "$((TIMEOUT_SEC*2))" "$url" | bash -s -- "$@"; then
      true
    else
      echo "Remote run failed for $url"
      exit 1
    fi
    echo
  } |& tee "$file"
}

# Summary init
{
  echo "=== VPN VPS Test Summary ==="
  echo "Run: $RUN_NAME"
  echo "Time: $(date -Is)"
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo
} > "$SUMMARY"

append_summary() {
  echo "$*" >> "$SUMMARY"
}

# Basic sanity: IP, DNS
run_to_file "01-ip-a.txt" bash -lc 'ip -4 addr show; echo; ip -4 route show; echo; echo "resolver:"; cat /etc/resolv.conf || true'
run_to_file "02-public-ip.txt" bash -lc 'echo "ifconfig.me:"; curl -fsS --connect-timeout 10 --max-time 20 https://ifconfig.me || true; echo; echo "ipinfo.io/ip:"; curl -fsS --connect-timeout 10 --max-time 20 https://ipinfo.io/ip || true; echo'

# sysbench cpu (local CPU slice hint)
if [[ "$RUN_SYSBENCH" -eq 1 ]]; then
  if have sysbench; then
    run_to_file "03-sysbench-cpu.txt" sysbench cpu run --threads=1
    # Extract events/sec
    EPS="$(grep -E 'events per second:' "$OUTDIR/03-sysbench-cpu.txt" | awk '{print $4}' | tail -n1 || true)"
    append_summary "sysbench.events_per_second=${EPS:-n/a}"
  else
    append_summary "sysbench=missing"
  fi
fi

# ipregion
if [[ "$RUN_IPREGION" -eq 1 ]]; then
  run_remote_bash "10-ipregion.txt" "https://ipregion.vrnt.xyz"
  # Quick parse: IPv4/ASN line (best effort)
  IPV4_LINE="$(grep -E 'IPv4:' "$OUTDIR/10-ipregion.txt" | head -n1 || true)"
  ASN_LINE="$(grep -E 'ASN:' "$OUTDIR/10-ipregion.txt" | head -n1 || true)"
  append_summary "ipregion.ipv4=${IPV4_LINE:-n/a}"
  append_summary "ipregion.asn=${ASN_LINE:-n/a}"
fi

# censorcheck geoblock / dpi
# Note: You previously used "bash <(wget -qO- ... ) --mode ..."
CENSOR_URL="https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh"
if [[ "$RUN_CENSOR_GEO" -eq 1 ]]; then
  run_remote_bash "11-censorcheck-geoblock.txt" "$CENSOR_URL" --mode geoblock
  # Best-effort: count "Denied/Blocked" strings
  GEO_BAD="$(grep -Ei 'Denied|Blocked|timeout|fail' "$OUTDIR/11-censorcheck-geoblock.txt" | wc -l | tr -d ' ' || true)"
  append_summary "censorcheck.geoblock.bad_lines=${GEO_BAD:-n/a}"
fi
if [[ "$RUN_CENSOR_DPI" -eq 1 ]]; then
  run_remote_bash "12-censorcheck-dpi.txt" "$CENSOR_URL" --mode dpi
  DPI_BAD="$(grep -Ei 'Denied|Blocked|timeout|fail' "$OUTDIR/12-censorcheck-dpi.txt" | wc -l | tr -d ' ' || true)"
  append_summary "censorcheck.dpi.bad_lines=${DPI_BAD:-n/a}"
fi

# Russian iperf3 community test script
RU_IPERF_URL="https://raw.githubusercontent.com/itdoginfo/russian-iperf3-servers/main/speedtest.sh"
if [[ "$RUN_RU_IPERF" -eq 1 ]]; then
  run_remote_bash "20-ru-iperf3.txt" "$RU_IPERF_URL"
  # Extract ping lines if table exists (best effort)
  # Example row: Moscow 4296.3 Mbps 4298.7 Mbps 42 ms
  MOSCOW_PING="$(grep -E '^Moscow' "$OUTDIR/20-ru-iperf3.txt" | awk '{print $NF}' | tail -n1 || true)"
  append_summary "ru-iperf3.moscow.ping=${MOSCOW_PING:-n/a}"
fi

# YABS
if [[ "$RUN_YABS" -eq 1 ]]; then
  # yabs supports args; you used: curl -sL yabs.sh | bash -s -- -4
  run_remote_bash "30-yabs.txt" "https://yabs.sh" -4
  # Extract TCP CC if present
  TCPCC="$(grep -E 'TCP CC' "$OUTDIR/30-yabs.txt" | head -n1 | awk -F: '{print $2}' | xargs || true)"
  append_summary "yabs.tcp_cc=${TCPCC:-n/a}"
fi

# IP block check (your line: bash <(curl -Ls IP.Check.Place) -l en)
if [[ "$RUN_IPBLOCK" -eq 1 ]]; then
  run_remote_bash "40-ip-check-place.txt" "https://IP.Check.Place" -l "$LANG_OUT"
  # Best-effort: find "Report Link" line
  RLINK="$(grep -E 'Report Link:' "$OUTDIR/40-ip-check-place.txt" | tail -n1 || true)"
  append_summary "ip.check.place.report=${RLINK:-n/a}"
fi

# bench.sh (your line: wget -qO- bench.sh | bash)
if [[ "$RUN_BENCHSH" -eq 1 ]]; then
  run_remote_bash "50-benchsh.txt" "https://bench.sh"
  # Extract I/O avg if present
  IOAVG="$(grep -E 'I/O Speed\(average\)' "$OUTDIR/50-benchsh.txt" | tail -n1 | awk -F: '{print $2}' | xargs || true)"
  append_summary "bench.io_avg=${IOAVG:-n/a}"
fi

# IPQuality EI (your line: bash <(curl -Ls https://Check.Place) -EI)
if [[ "$RUN_IPQUALITY_EI" -eq 1 ]]; then
  run_remote_bash "60-check-place-EI.txt" "https://Check.Place" -EI
  # Extract Geo-consistent/discrepant if present
  GEOSTAT="$(grep -E 'IP Type:' "$OUTDIR/60-check-place-EI.txt" | head -n1 | awk -F: '{print $2}' | xargs || true)"
  append_summary "check.place.ip_type=${GEOSTAT:-n/a}"
fi

# Helpful: quick DNS sanity for your current node name if provided as tag
if [[ -n "$SAFE_TAG" && "$SAFE_TAG" == *".nolim.cloud"* ]]; then
  run_to_file "90-dns-dig-${SAFE_TAG}.txt" bash -lc "dig +short A $SAFE_TAG; dig +short AAAA $SAFE_TAG; dig $SAFE_TAG"
fi

# Final pointers
{
  echo
  echo "=== Files generated ==="
  ls -1 "$OUTDIR" | sed 's/^/ - /'
  echo
  echo "Summary: $SUMMARY"
} | tee -a "$SUMMARY" >/dev/null

log "Done. Summary: $SUMMARY"
exit 0
