# dnsmasq base config — entrypoint.sh appends ipset directives at runtime

# Listen on the WireGuard server interface only
listen-address=10.8.0.1
bind-interfaces

# Don't read /etc/resolv.conf (we set upstreams explicitly)
no-resolv

# Upstream DNS server — IP substituted at runtime from INTERNAL_DNS_IP
server=%%INTERNAL_DNS_IP%%

# Cache settings
cache-size=1000
neg-ttl=60

# Security: don't pass short names upstream
domain-needed
bogus-priv

# Log to stdout (captured by Docker)
log-facility=-

# ipset directives are appended here by entrypoint.sh:
# ipset=/claude.ai/surfshark_ips
# ipset=/netflix.com/surfshark_ips
# ...
