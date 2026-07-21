#!/usr/bin/env bash
#
# ton-vpn one-command installer (Mysterium-style).
#
#   Exit node (anyone can run one, earns for serving traffic):
#     curl -fsSL https://raw.githubusercontent.com/Kurilchanin/quickvpn/main/install.sh | sudo bash
#
#   Payment hub (owner only, installed once):
#     curl -fsSL https://raw.githubusercontent.com/Kurilchanin/quickvpn/main/install.sh | sudo bash -s -- --role hub
#
# It auto-detects arch / public IP / WAN interface, downloads the prebuilt
# binary (with the payment fix + web panel baked in), generates keys on first
# run, opens the firewall, installs a systemd service, starts it, and prints the
# web-panel URL + token. An exit operator brings NO money: the node earns, and
# withdrawal gas comes out of earnings.
set -euo pipefail

# ---- config (override via env or flags) ------------------------------------
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/Kurilchanin/quickvpn/releases/latest/download}"  # prebuilt binaries (GitHub release)
HUB_REGISTRY="${HUB_REGISTRY:-}"  # hub registry ADNL id (hex) — exit auto-registers with it; filled once the hub is deployed
ROLE="exit"
EXTERNAL_IP=""            # auto-detect if empty
WEB_PORT="8088"
PRICE_PER_PACKET="1000"   # nano-TON per forwarded packet (exit only)
COUNTRY=""                # display label advertised to clients, e.g. NL
ENABLE_WEB=1

info()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --role)          ROLE="${2:?}"; shift 2 ;;
    --external-ip)   EXTERNAL_IP="${2:?}"; shift 2 ;;
    --web-port)      WEB_PORT="${2:?}"; shift 2 ;;
    --price)         PRICE_PER_PACKET="${2:?}"; shift 2 ;;
    --country)       COUNTRY="${2:?}"; shift 2 ;;
    --hub)           HUB_REGISTRY="${2:?}"; shift 2 ;;
    --download-base) DOWNLOAD_BASE="${2:?}"; shift 2 ;;
    --no-web)        ENABLE_WEB=0; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ "$ROLE" = "exit" ] || [ "$ROLE" = "hub" ] || die "--role must be 'exit' or 'hub'"
[ "$(id -u)" = "0" ] || die "run as root (use sudo)"
command -v curl >/dev/null 2>&1 || die "curl is required"

# ---- detect arch -----------------------------------------------------------
case "$(uname -m)" in
  x86_64|amd64)      ARCH="amd64" ;;
  aarch64|arm64)     ARCH="arm64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
ok "architecture: $ARCH"

# ---- detect public IP ------------------------------------------------------
if [ -z "$EXTERNAL_IP" ]; then
  for u in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    EXTERNAL_IP="$(curl -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$EXTERNAL_IP" in *.*.*.*) break ;; *) EXTERNAL_IP="" ;; esac
  done
fi
[ -n "$EXTERNAL_IP" ] || die "could not auto-detect public IP; pass --external-ip <ip>"
ok "public IP: $EXTERNAL_IP"

# ---- download binary -------------------------------------------------------
if [ "$ROLE" = "exit" ]; then BIN="ton-vpn-node"; else BIN="ton-vpn-hub"; fi
URL="$DOWNLOAD_BASE/${BIN}-${ARCH}"
info "downloading $BIN ($ARCH) from $URL"
tmp="$(mktemp)"
curl -fSL --retry 3 -o "$tmp" "$URL" || die "download failed from $URL (is DOWNLOAD_BASE reachable / binary published?)"
install -m 0755 "$tmp" "/usr/local/bin/$BIN"
rm -f "$tmp"
ok "installed /usr/local/bin/$BIN"

STATE_DIR="/var/lib/$BIN"
mkdir -p "$STATE_DIR"

# ---- firewall --------------------------------------------------------------
open_port() { # proto port
  if command -v ufw >/dev/null 2>&1; then ufw allow "$2/$1" >/dev/null 2>&1 || true; fi
}
if [ "$ROLE" = "exit" ]; then
  open_port udp 9058   # data-plane ADNL
  open_port udp 9059   # payment gateway (external-port + 1)
else
  open_port udp 9060   # hub payment gateway
  open_port udp 9061   # node registry gateway (exits auto-register here)
fi
[ "$ENABLE_WEB" = "1" ] && open_port tcp "$WEB_PORT"
ok "firewall rules applied (ufw, if present)"

WEB_ARGS=""
[ "$ENABLE_WEB" = "1" ] && WEB_ARGS="-web-addr 0.0.0.0:$WEB_PORT"

REG_ARGS=""
if [ "$ROLE" = "exit" ] && [ -n "$HUB_REGISTRY" ]; then
  REG_ARGS="-hub $HUB_REGISTRY"
  [ -n "$COUNTRY" ] && REG_ARGS="$REG_ARGS -country $COUNTRY"
fi

# ---- systemd unit ----------------------------------------------------------
UNIT="/etc/systemd/system/$BIN.service"
if [ "$ROLE" = "exit" ]; then
  cat > "$UNIT" <<EOF
[Unit]
Description=ton-vpn exit node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ton-vpn-node \\
  -external-ip $EXTERNAL_IP \\
  -external-port 9058 \\
  -listen 0.0.0.0:9058 \\
  -key $STATE_DIR/node.key \\
  -payments \\
  -price-per-packet $PRICE_PER_PACKET \\
  $REG_ARGS \\
  $WEB_ARGS
# Persist forwarding across restarts (ufw FORWARD policy is often DROP).
ExecStartPost=/bin/sh -c "iptables -C FORWARD -i ton0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ton0 -j ACCEPT"
ExecStartPost=/bin/sh -c "iptables -C FORWARD -o ton0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -o ton0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
StateDirectory=$BIN

[Install]
WantedBy=multi-user.target
EOF
else
  cat > "$UNIT" <<EOF
[Unit]
Description=ton-vpn payment hub (master node)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ton-vpn-hub \\
  -external-ip $EXTERNAL_IP \\
  -payments-port 9060 \\
  -payments-db $STATE_DIR/payments-db \\
  -payments-keys $STATE_DIR/payments.keys.json \\
  -proxy-max-capacity 5 \\
  $WEB_ARGS
Restart=on-failure
RestartSec=3
StateDirectory=$BIN

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable "$BIN" >/dev/null 2>&1 || true
systemctl restart "$BIN"
ok "service $BIN started"

# ---- summary ---------------------------------------------------------------
sleep 3
KEYS="$STATE_DIR/payments.keys.json"
TOKEN_FILE="$STATE_DIR/web.token"
WALLET="$(journalctl -u "$BIN" -n 200 --no-pager 2>/dev/null | grep 'FUND THIS' | tail -1 | awk '{print $NF}')"
PUBKEY="$(journalctl -u "$BIN" -n 200 --no-pager 2>/dev/null | grep -oE 'payment pubkey[^:]*: \S+' | tail -1 | awk '{print $NF}')"
TOKEN=""; [ -f "$TOKEN_FILE" ] && TOKEN="$(cat "$TOKEN_FILE")"

echo
printf '\033[1;32m========================================================\033[0m\n'
printf '  ton-vpn %s installed and running\n' "$ROLE"
printf '\033[1;32m========================================================\033[0m\n'
if [ "$ENABLE_WEB" = "1" ]; then
  echo   "  Web panel:  http://$EXTERNAL_IP:$WEB_PORT/?token=$TOKEN"
  echo   "  (open it to see status, set price, and withdraw earnings)"
fi
[ -n "$WALLET" ] && echo "  Wallet:     $WALLET"
[ -n "$PUBKEY" ] && echo "  Pubkey:     $PUBKEY"
if [ "$ROLE" = "exit" ]; then
  echo "  You bring no money — the node earns as it serves traffic."
  echo "  It auto-registers with the hub and joins the network."
else
  REGID="$(journalctl -u "$BIN" -n 200 --no-pager 2>/dev/null | grep -oE 'register with: -hub \S+' | tail -1 | awk '{print $NF}')"
  echo "  Fund the hub wallet (liquidity + gas) from the web panel."
  [ -n "$REGID" ] && echo "  Registry ID: $REGID"
  [ -n "$REGID" ] && echo "  (exits join with:  ... | sudo bash -s -- --hub $REGID)"
fi
echo   "  Logs:       journalctl -u $BIN -f"
echo
