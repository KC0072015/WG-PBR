# NAS PBR VPN

A single Docker container that runs on **TrueNAS Scale** providing:

- **WireGuard server** — your devices connect to the NAS as a VPN endpoint
- **Surfshark WireGuard client** — NAS connects outbound to Surfshark
- **Policy-Based Routing (PBR)** — per-domain split routing:
  - Domains in `config/domains.txt` → exit via **Surfshark**
  - Everything else → exit via **home IP**

```
[Your Device]
     │ WireGuard (UDP 51820)
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
| `wg0-server.conf` (WireGuard server + peer keys) | NAS filesystem only | ❌ No |
| `surfshark.conf` (Surfshark private key) | NAS filesystem only | ❌ No |

Portainer is told where the secrets live via the `SECRETS_PATH` environment variable.

---

## Prerequisites

- TrueNAS Scale with Docker + Portainer
- Port **51820/UDP** forwarded on your router → TrueNAS IP
- A DDNS hostname pointing to your public IP (e.g. `myhome.duckdns.org`)
- A Surfshark account
- `wireguard-tools` installed locally (to generate key pairs)

---

## One-time setup on TrueNAS (SSH)

### Step 1 — Create the secrets directory

```bash
mkdir -p /opt/pbr-vpn-secrets
```

### Step 2 — Generate WireGuard server keys

```bash
# On your Mac/PC (with wireguard-tools), or inside any Alpine container
wg genkey | tee server_private.key | wg pubkey > server_public.key
```

Generate a key pair for each client device:

```bash
wg genkey | tee client1_private.key | wg pubkey > client1_public.key
```

### Step 3 — Create wg0-server.conf

```bash
cat > /opt/pbr-vpn-secrets/wg0-server.conf << 'EOF'
[Interface]
PrivateKey = <SERVER_PRIVATE_KEY>
ListenPort = 51820

[Peer]
# Client 1 — e.g. laptop
PublicKey  = <CLIENT1_PUBLIC_KEY>
AllowedIPs = 10.8.0.2/32
EOF
```

Add more `[Peer]` blocks for additional devices (10.8.0.3/32, 10.8.0.4/32, …).

### Step 4 — Get Surfshark WireGuard config

1. Log in at [my.surfshark.com](https://my.surfshark.com)
2. Go to **VPN → Manual setup → Router → WireGuard**
3. Pick a server location and download the `.conf` file
4. Copy it to the NAS:

```bash
# From your Mac
scp surfshark-download.conf root@<truenas-ip>:/opt/pbr-vpn-secrets/surfshark.conf
```

---

## Deploy with Portainer

### Step 1 — Add the stack

In Portainer: **Stacks → Add Stack → Repository**

| Field | Value |
|---|---|
| Name | `pbr-vpn` |
| Repository URL | `https://github.com/YOUR_USERNAME/nas-pbr-vpn` |
| Repository reference | `refs/heads/main` |
| Compose path | `docker-compose.yml` |
| Authentication | (only needed for private repos) |

### Step 2 — Set environment variables

In the **Environment variables** section of the stack, add:

| Variable | Value |
|---|---|
| `SECRETS_PATH` | `/opt/pbr-vpn-secrets` |
| `WG_PORT` | `51820` |
| `WG_SERVER_SUBNET` | `10.8.0.0/24` |
| `WG_SERVER_IP` | `10.8.0.1` |

### Step 3 — Enable auto-update (optional but recommended)

Enable **"GitOps updates"** / **"Auto update"** in Portainer. With this on, pushing to the `main` branch (e.g. updating `domains.txt`) will automatically redeploy the stack.

### Step 4 — Deploy

Click **Deploy the stack**. Portainer will clone the repo, build the image, and start the container.

Check logs in Portainer → Containers → `pbr-vpn` → Logs.

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
Endpoint            = myhome.duckdns.org:51820
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
```

Import this into the WireGuard app on your device and connect.

---

## Managing domains

Edit [config/domains.txt](config/domains.txt) in this repo — one domain per line:

```
claude.ai
netflix.com
youtube.com
```

Commit and push. If auto-update is enabled in Portainer, it redeploys automatically. Otherwise, click **Pull and redeploy** in Portainer.

Subdomains are included automatically (`netflix.com` covers `www.netflix.com`, etc.).

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

**Test exit IPs while connected:**
- Browse to `ifconfig.me` — should show your **home IP**
- Browse to a site in `domains.txt` then check `ifconfig.me` again — the exit IP should be a **Surfshark IP**

---

## Adding a new client device

1. Generate a key pair for the new device (Step 2 above)
2. SSH into TrueNAS and append a `[Peer]` block to `/opt/pbr-vpn-secrets/wg0-server.conf`
3. In Portainer, click **Pull and redeploy** (or restart the container — WireGuard peers are read at startup)
4. Configure the WireGuard app on the new device

---

## TrueNAS Scale notes

- If the container logs show a WireGuard error, SSH in and run `modprobe wireguard`, then redeploy.
- The stack requires `NET_ADMIN` + `SYS_MODULE` capabilities — standard for VPN containers.
- Port 51820/UDP must be forwarded on your home router to the TrueNAS IP.

---

## File structure

```
.
├── docker-compose.yml            ← Portainer deploys this
├── .env.example                  ← reference for env vars to set in Portainer
├── .gitignore                    ← excludes secret configs
├── router/
│   ├── Dockerfile
│   ├── entrypoint.sh             ← tunnel setup, PBR, dnsmasq
│   └── dnsmasq.conf.tpl
└── config/
    ├── domains.txt               ← edit this to control routing
    └── wg0-server.conf.example   ← reference only, real file lives on NAS
```

Secrets (NOT in this repo):
```
/opt/pbr-vpn-secrets/
├── wg0-server.conf   ← WireGuard server config + peer keys
└── surfshark.conf    ← Surfshark WireGuard config
```
