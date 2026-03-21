# NAS PBR VPN

A single Docker container that runs on **TrueNAS Scale** providing:

- **WireGuard server** — your devices connect to the NAS as a VPN endpoint
- **Surfshark WireGuard client** — NAS connects outbound to Surfshark
- **Policy-Based Routing (PBR)** — per-domain split routing:
  - Domains in `config/domains.txt` → exit via **Surfshark**
  - Everything else → exit via **home IP**
- **AdGuard Home integration** — DNS forwarded to your AdGuard instance
- **Live domain updates** — edit `domains.txt` and routing updates automatically within 30 seconds, no restart needed
- **Visit logging** — logs every time a connected client queries a Surfshark-routed domain

```
[Your Device]
     │ WireGuard (UDP 51822)
     ▼
┌─────────────────────────────────┐
│         pbr-vpn container       │
│                                 │
│  wg0 (server) → PBR (ipset)     │
│                   │        │    │
│              Surfshark   Home   │
│              domains     IP     │
└─────────────────────────────────┘
```

---

## How secrets are handled

| What | Where | In Git? |
|---|---|---|
| `router/` code, `domains.txt` | This repo | ✅ Yes |
| `wg0-server.conf` (WireGuard server + peer keys) | `secrets/` on NAS only | ❌ No |
| `surfshark.conf` (Surfshark private key) | `secrets/` on NAS only | ❌ No |

---

## Prerequisites

- TrueNAS Scale with Docker
- Port **51822/UDP** forwarded on your router → TrueNAS IP
- A Surfshark account with WireGuard config downloaded
- `wireguard-tools` installed locally (to generate key pairs)

---

## One-time setup

### Step 1 — Clone the repo on TrueNAS (SSH)

```bash
cd /mnt/<your-pool>/appdata
git clone https://github.com/YOUR_USERNAME/nas-pbr-vpn
cd nas-pbr-vpn
```

### Step 2 — Create the secrets directory

```bash
mkdir -p secrets
```

### Step 3 — Generate WireGuard server keys

```bash
# Run on any machine with wireguard-tools, or inside any Alpine container
wg genkey | tee secrets/server_private.key | wg pubkey > secrets/server_public.key
```

Generate a key pair for each client device:

```bash
wg genkey | tee client1_private.key | wg pubkey > client1_public.key
```

### Step 4 — Create secrets/wg0-server.conf

```ini
[Interface]
PrivateKey = <SERVER_PRIVATE_KEY>
ListenPort = 51822

[Peer]
# Client 1 — e.g. laptop
PublicKey  = <CLIENT1_PUBLIC_KEY>
AllowedIPs = 10.8.0.2/32

[Peer]
# Client 2 — e.g. phone
PublicKey  = <CLIENT2_PUBLIC_KEY>
AllowedIPs = 10.8.0.3/32
```

Add more `[Peer]` blocks for additional devices (10.8.0.4/32, …).
See `config/wg0-server.conf.example` for reference.

### Step 5 — Get Surfshark WireGuard config

1. Log in at [my.surfshark.com](https://my.surfshark.com)
2. Go to **VPN → Manual setup → Router → WireGuard**
3. Pick a server location and download the `.conf` file
4. Copy it to the secrets folder:

```bash
cp surfshark-download.conf secrets/surfshark.conf
```

### Step 6 — Configure environment

```bash
cp .env.example .env
# Edit .env and set SECRETS_PATH to the absolute path of your secrets/ folder
```

### Step 7 — Deploy

```bash
docker compose up --build -d
docker compose logs -f
```

---

## Configure WireGuard clients

For each device, create a WireGuard client config:

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address    = 10.8.0.2/24
DNS        = 10.8.0.1

[Peer]
PublicKey           = <SERVER_PUBLIC_KEY>
Endpoint            = <YOUR-NAS-IP-OR-DDNS>:51822
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
```

> **Important:** `DNS = 10.8.0.1` is required. This points the client at the container's dnsmasq, which is what populates the ipset and triggers PBR routing. Without it, domain-based routing will not work.

---

## Managing domains

Edit [config/domains.txt](config/domains.txt) — one domain per line, comments with `#`:

```
# Streaming
netflix.com

# AI
claude.ai
anthropic.com
```

The container polls for changes every 30 seconds. When a change is detected it automatically rebuilds the dnsmasq config and restarts dnsmasq — **no redeploy needed**. You will see in the logs:

```
[pbr] domains.txt changed — rebuilding config and restarting dnsmasq...
[pbr] dnsmasq restarted (PID 123) — new domains are active.
```

Subdomains are covered automatically (`netflix.com` matches `www.netflix.com`, etc.).

---

## Visit logging

Whenever a connected client queries a Surfshark-routed domain, the container logs it:

```
[pbr] VISIT 10.8.0.2 → netflix.com (via Surfshark)
```

Watch live:

```bash
docker compose logs -f
```

---

## Verification

```bash
# Both WireGuard interfaces should show a recent handshake
docker exec pbr-vpn wg show

# After browsing to an allowlisted domain, its IPs appear here
docker exec pbr-vpn ipset list surfshark_ips

# Routing rules — fwmark 0x1 → table 100 should be present
docker exec pbr-vpn ip rule show

# Routing table 100 (Surfshark exit)
docker exec pbr-vpn ip route show table 100
```

**Test exit IPs while connected via WireGuard:**
- `curl https://ipinfo.io/ip` — should show your **home IP**
- Browse to a domain in `domains.txt`, then check again — should show a **Surfshark IP**

---

## Adding a new client device

1. Generate a key pair for the new device (Step 3 above)
2. Append a `[Peer]` block to `secrets/wg0-server.conf`
3. Restart the container: `docker compose restart`
4. Configure the WireGuard app on the new device

---

## TrueNAS Scale notes

- WireGuard is built into the TrueNAS kernel — `modprobe wireguard` may print a warning but the module is available.
- The container requires `NET_ADMIN` + `SYS_MODULE` capabilities — standard for VPN containers.
- Port 51822/UDP must be forwarded on your home router to the TrueNAS IP.

---

## File structure

```
.
├── docker-compose.yml
├── .env.example                  ← copy to .env and fill in SECRETS_PATH
├── .gitignore
├── router/
│   ├── Dockerfile
│   ├── entrypoint.sh             ← tunnel setup, PBR, dnsmasq, domain watcher
│   └── dnsmasq.conf.tpl          ← dnsmasq base config (upstream DNS etc.)
└── config/
    ├── domains.txt               ← edit this to control routing
    └── wg0-server.conf.example   ← reference only, real file lives in secrets/
```

Secrets (NOT in this repo — lives on your NAS):
```
secrets/
├── wg0-server.conf        ← WireGuard server config + peer public keys
├── surfshark.conf         ← Surfshark WireGuard config
├── server_private.key     ← server private key
└── server_public.key      ← server public key
```
