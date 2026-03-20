FROM alpine:3.20

RUN apk add --no-cache \
    wireguard-tools \
    dnsmasq \
    ipset \
    iptables \
    ip6tables \
    iproute2 \
    bash \
    curl \
    bind-tools

COPY entrypoint.sh /entrypoint.sh
COPY dnsmasq.conf.tpl /etc/pbr/dnsmasq.conf.tpl

RUN chmod +x /entrypoint.sh && \
    mkdir -p /etc/wireguard /etc/pbr /var/run/dnsmasq

ENTRYPOINT ["/entrypoint.sh"]
