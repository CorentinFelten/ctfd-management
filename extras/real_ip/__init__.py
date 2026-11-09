"""Trust Cloudflare edge hops so CTFd stores the real client IP.

Behind Cloudflare (proxied DNS), the TCP peer of the origin is a Cloudflare
edge. CTFd's get_ip() walks X-Forwarded-For and skips TRUSTED_PROXIES, which
by default only covers private ranges, so Tracking, logs and rate limits all
record Cloudflare IPs. This plugin appends Cloudflare's published ranges to
TRUSTED_PROXIES at load time.

Only mount it when CTFd is really behind Cloudflare, and make Traefik trust
the same ranges (entryPoints.<name>.forwardedHeaders.trustedIPs), otherwise
Traefik overwrites X-Forwarded-For with the edge address. Keep the list in
sync with https://www.cloudflare.com/ips/.
"""

CLOUDFLARE_TRUSTED_PROXIES = [
    r"^173\.245\.",
    r"^103\.21\.244\.",
    r"^103\.22\.200\.",
    r"^103\.31\.4\.",
    r"^141\.101\.",
    r"^108\.162\.",
    r"^190\.93\.(24[0-9]|25[0-5])\.",
    r"^188\.114\.(9[6-9]|1[01][0-9])\.",
    r"^197\.234\.24[0-3]\.",
    r"^198\.41\.(1[2-9][0-9]|2[0-5][0-9])\.",
    r"^162\.15[89]\.",
    r"^104\.(1[6-9]|2[0-7])\.",
    r"^172\.(6[4-9]|7[01])\.",
    r"^131\.0\.72\.",
    r"^2400:cb00:",
    r"^2606:4700:",
    r"^2803:f800:",
    r"^2405:b500:",
    r"^2405:8100:",
    r"^2a06:98c0:",
    r"^2c0f:f248:",
]


def load(app):
    current = list(app.config.get("TRUSTED_PROXIES") or [])
    for pattern in CLOUDFLARE_TRUSTED_PROXIES:
        if pattern not in current:
            current.append(pattern)
    app.config["TRUSTED_PROXIES"] = current
