#!/bin/bash
set -euo pipefail

WG_SERVER_SUBNET="${WG_SERVER_SUBNET:-10.8.0.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.8.0.1}"
DOMAINS_FILE="/etc/pbr/domains.txt"
DNSMASQ_CONF="/etc/pbr/dnsmasq.conf"
WG0_CONF="/etc/wireguard/wg0.conf"
WG1_CONF="/etc/wireguard/wg1.conf"
PBR_TABLE=100
FWMARK=0x1
IPSET_NAME="surfshark_ips"

log() { echo "[pbr] $*"; }
die() { echo "[pbr] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Load WireGuard kernel module
# ---------------------------------------------------------------------------
log "Loading wireguard kernel module..."
modprobe wireguard 2>/dev/null || log "modprobe failed (module may already be built-in)"

# ---------------------------------------------------------------------------
# 2. Parse Surfshark (wg1) config
# ---------------------------------------------------------------------------
log "Parsing Surfshark config..."
[[ -f "$WG1_CONF" ]] || die "Surfshark config not found at $WG1_CONF"

WG1_PRIVKEY=$(awk '/^\[Interface\]/,/^\[Peer\]/' "$WG1_CONF" | grep '^PrivateKey' | awk '{print $3}' || true)
WG1_ADDRESS=$(awk '/^\[Interface\]/,/^\[Peer\]/' "$WG1_CONF" | grep '^Address' | awk '{print $3}' || true)
WG1_PUBKEY=$(awk '/^\[Peer\]/,0' "$WG1_CONF" | grep '^PublicKey' | awk '{print $3}' || true)
WG1_ENDPOINT=$(awk '/^\[Peer\]/,0' "$WG1_CONF" | grep '^Endpoint' | awk '{print $3}' || true)
WG1_KEEPALIVE=$(awk '/^\[Peer\]/,0' "$WG1_CONF" | grep '^PersistentKeepalive' | awk '{print $3}' || true)

[[ -n "$WG1_PRIVKEY" ]] || die "Could not parse PrivateKey from Surfshark config"
[[ -n "$WG1_ADDRESS" ]] || die "Could not parse Address from Surfshark config"
[[ -n "$WG1_PUBKEY" ]] || die "Could not parse Peer PublicKey from Surfshark config"
[[ -n "$WG1_ENDPOINT" ]] || die "Could not parse Endpoint from Surfshark config"

WG1_ENDPOINT_HOST="${WG1_ENDPOINT%:*}"
WG1_ENDPOINT_PORT="${WG1_ENDPOINT##*:}"
WG1_IP="${WG1_ADDRESS%%/*}"

# Resolve endpoint hostname to IP (needed to add static route to avoid loop)
log "Resolving Surfshark endpoint: $WG1_ENDPOINT_HOST"
WG1_ENDPOINT_IP=$(dig +short "$WG1_ENDPOINT_HOST" | grep -E '^[0-9]+\.' | head -1 || true)
[[ -n "$WG1_ENDPOINT_IP" ]] || die "Could not resolve Surfshark endpoint: $WG1_ENDPOINT_HOST"
log "Surfshark endpoint IP: $WG1_ENDPOINT_IP"

# ---------------------------------------------------------------------------
# 3. Detect default gateway (host LAN interface)
# ---------------------------------------------------------------------------
DEFAULT_GW=$(ip route show default | awk '/default/ {print $3; exit}')
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n "$DEFAULT_GW" ]] || die "Could not detect default gateway"
log "Default gateway: $DEFAULT_GW via $DEFAULT_IFACE"

# ---------------------------------------------------------------------------
# 4. Bring up wg0 (WireGuard server for clients)
# ---------------------------------------------------------------------------
log "Bringing up wg0 (server)..."
ip link add dev wg0 type wireguard
wg setconf wg0 "$WG0_CONF"
ip addr add "${WG_SERVER_IP}/${WG_SERVER_SUBNET##*/}" dev wg0
ip link set wg0 up
log "wg0 up: $WG_SERVER_IP"

# ---------------------------------------------------------------------------
# 5. Bring up wg1 (Surfshark client)
# ---------------------------------------------------------------------------
log "Bringing up wg1 (Surfshark)..."
ip link add dev wg1 type wireguard

# Write a clean wg config (strip DNS line which wg-quick would handle, we don't need it)
wg set wg1 \
    private-key <(echo "$WG1_PRIVKEY") \
    peer "$WG1_PUBKEY" \
    endpoint "$WG1_ENDPOINT_IP:$WG1_ENDPOINT_PORT" \
    allowed-ips "0.0.0.0/0" \
    ${WG1_KEEPALIVE:+persistent-keepalive "$WG1_KEEPALIVE"}

ip addr add "$WG1_ADDRESS" dev wg1
ip link set wg1 up

# Static route to Surfshark endpoint via host gateway (avoids routing loop)
ip route add "$WG1_ENDPOINT_IP/32" via "$DEFAULT_GW" dev "$DEFAULT_IFACE"
log "wg1 up: $WG1_IP"

# ---------------------------------------------------------------------------
# 6. Create ipset for allowlisted domain IPs
# ---------------------------------------------------------------------------
log "Creating ipset: $IPSET_NAME"
ipset create "$IPSET_NAME" hash:ip -exist

# ---------------------------------------------------------------------------
# 7. Build dnsmasq config from template + domains list
# ---------------------------------------------------------------------------
build_dnsmasq_conf() {
    cp /etc/pbr/dnsmasq.conf.tpl "$DNSMASQ_CONF"
    if [[ -f "$DOMAINS_FILE" ]]; then
        while IFS= read -r domain || [[ -n "$domain" ]]; do
            domain="${domain// /}"
            [[ -z "$domain" ]] && continue
            [[ "$domain" == \#* ]] && continue
            echo "ipset=/${domain}/${IPSET_NAME}" >> "$DNSMASQ_CONF"
            log "  routing via Surfshark: $domain"
        done < "$DOMAINS_FILE"
    else
        log "WARNING: $DOMAINS_FILE not found — no domains will be routed via Surfshark"
    fi
}

log "Building dnsmasq config..."
build_dnsmasq_conf

# ---------------------------------------------------------------------------
# 8. Policy-Based Routing
# ---------------------------------------------------------------------------
log "Configuring PBR..."

# Routing table 100: exit via Surfshark
ip route add default dev wg1 table $PBR_TABLE

# Route marked packets through table 100
ip rule add fwmark $FWMARK table $PBR_TABLE priority 100

# ---------------------------------------------------------------------------
# 9. iptables rules
# ---------------------------------------------------------------------------
log "Configuring iptables..."

# Mark packets destined for allowlisted IPs (populated by dnsmasq)
iptables -t mangle -A PREROUTING  -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark $FWMARK
iptables -t mangle -A OUTPUT      -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark $FWMARK

# NAT: Surfshark tunnel
iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE

# NAT: home IP (LAN) for non-marked traffic
iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" ! -d "$WG_SERVER_SUBNET" -j MASQUERADE

# Allow forwarding for both paths
iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT
iptables -A FORWARD -i wg0 -o "$DEFAULT_IFACE" -j ACCEPT
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# ---------------------------------------------------------------------------
# 10. Start dnsmasq
# ---------------------------------------------------------------------------

# Visitor logger: filters dnsmasq output and emits a [pbr] VISIT line when
# a client queries a domain that is tracked in domains.txt.
visit_logger() {
    while IFS= read -r line; do
        if echo "$line" | grep -qE 'query\[AA?\]'; then
            domain=$(echo "$line" | grep -oE 'query\[AA?\] [^ ]+' | awk '{print $2}' || true)
            client=$(echo "$line" | grep -oE 'from [0-9.]+' | awk '{print $2}' || true)
            if [[ -n "$domain" && -f "$DOMAINS_FILE" ]]; then
                while IFS= read -r tracked || [[ -n "$tracked" ]]; do
                    tracked="${tracked// /}"
                    [[ -z "$tracked" || "$tracked" == \#* ]] && continue
                    if [[ "$domain" == "$tracked" || "$domain" == *."$tracked" ]]; then
                        echo "[pbr] VISIT ${client:-unknown} → $domain (via Surfshark)"
                        break
                    fi
                done < "$DOMAINS_FILE"
            fi
        fi
    done
}

# Starts dnsmasq piped through visit_logger; sets global DNSMASQ_PID.
# Must be called directly (not via $()) — command substitution would wait
# for the background dnsmasq pipe to exit, blocking forever.
start_dnsmasq() {
    dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --no-daemon \
        --log-facility=- \
        --log-queries=extra 2>&1 | visit_logger &
    sleep 1
    DNSMASQ_PID=$(pgrep -n dnsmasq || true)
}

log "Starting dnsmasq..."
start_dnsmasq

log "=== Stack is up ==="
log "  WireGuard server : wg0 ($WG_SERVER_IP) — listen :${WG_SERVER_PORT:-51822}"
log "  Surfshark client : wg1 ($WG1_IP) → $WG1_ENDPOINT"
log "  PBR fwmark       : $FWMARK → table $PBR_TABLE"
log "  dnsmasq PID      : $DNSMASQ_PID"
log ""
log "Allowlisted domains will be routed through Surfshark."
log "All other traffic exits via home IP ($DEFAULT_GW)."

# ---------------------------------------------------------------------------
# Main loop: keepalive + domain watcher.
# SIGHUP does NOT reload ipset directives in dnsmasq — a full restart is
# required for new domains to take effect.
# ---------------------------------------------------------------------------
DOMAINS_HASH=$(md5sum "$DOMAINS_FILE" 2>/dev/null | awk '{print $1}' || true)
log "Domain watcher started (polling every 30s)..."
while true; do
    sleep 30

    # Exit container if dnsmasq died unexpectedly
    if ! pgrep -x dnsmasq > /dev/null 2>&1; then
        log "ERROR: dnsmasq died unexpectedly — exiting"
        exit 1
    fi

    # Check for changes to domains.txt
    current_hash=$(md5sum "$DOMAINS_FILE" 2>/dev/null | awk '{print $1}' || true)
    [[ -z "$current_hash" || "$current_hash" == "$DOMAINS_HASH" ]] && continue
    DOMAINS_HASH="$current_hash"

    log "domains.txt changed — rebuilding config and restarting dnsmasq..."
    build_dnsmasq_conf
    ipset flush "$IPSET_NAME"
    kill "$(pgrep -n dnsmasq)" 2>/dev/null || true
    sleep 1
    start_dnsmasq
    log "dnsmasq restarted (PID $DNSMASQ_PID) — new domains are active."
done
