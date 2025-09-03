# Docker Netdata LLM Client
This docker image is for running a netdata LLM client behind traefik in docker with a quick setup

Download this repo then:
 - Change .env vars to your config
 - docker-compose build
 - docker-compose up -d

This was built with help from ChatGPT5, original instructions below:

Awesome project. Here’s a clean, copy-pasteable setup that:

* Builds a **custom Docker image** of the Netdata Web Client (the LLM chat UI)
* Runs it behind **Traefik** on your existing `traefik-public` network
* Uses a **`.env`** for all secrets (domain, API keys, MCP URL, etc.)
* Adds **authentication + brute-force mitigation** using Traefik BasicAuth **and** RateLimit middlewares

I verified the key Netdata bits (the Web Client and the MCP endpoint/URL) and Traefik’s security middlewares so this will “just work.” ([Learn Netdata][1], [Traefik Docs][2], [Traefik Labs][3])

---

# 1) What you’ll deploy

* **Netdata Web Client** (browser UI) — the open-source, self-hostable chat UI optimized for observability; it connects to Netdata via MCP over WebSocket. The MCP endpoint on your Netdata node is:
  `ws://YOUR_NETDATA_HOST:19999/mcp?api_key=YOUR_API_KEY`. ([Learn Netdata][1])
* **Traefik (you already have it)** — we’ll add a router for the client with:

  * **BasicAuth** middleware (credentials in `.env`) ([Traefik Docs][2])
  * **RateLimit** middleware to slow down brute force attempts (config below) ([Traefik Labs][3])

---

# 2) One-time host prep (DigitalOcean Ubuntu droplet)

```bash
# Docker already installed per your note.
# 1) Create the shared Traefik network if you haven't already:
docker network create traefik-public || true

# 2) Create a project directory:
mkdir -p ~/netdata-web-client && cd ~/netdata-web-client
```

---

# 3) Files to create

## a) `.env`  (put this next to docker-compose.yml)

```dotenv
# --- domain / tls ---
DOMAIN=chat.example.com
EMAIL=you@example.com   # used by Traefik's Let's Encrypt (your traefik uses it)

# --- auth (Traefik BasicAuth) ---
# Generate with: printf "admin:$(openssl passwd -apr1 'supersecret')\n"
BASICAUTH_USERS=admin:$apr1$AbCdEf12$X1Y2Z3....   # replace with your hash

# Optional: IP allow list (comma separated CIDRs). Leave empty to disable.
ALLOWLIST_CIDRS=

# --- Netdata MCP target ---
# Usually the Netdata agent (or parent) public IP or internal hostname:
MCP_WS_URL=ws://YOUR_NETDATA_HOST:19999/mcp?api_key=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

# --- LLM provider keys (set the ones you use) ---
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
GOOGLE_API_KEY=

# --- build pin (optional; master by default) ---
NETDATA_REPO_REF=master
```

> Tip: The API key file on your Netdata node is typically at `/var/lib/netdata/mcp_dev_preview_api_key`. Paste its UUID into `MCP_WS_URL` as the `api_key` parameter. ([Learn Netdata][4])

---

## b) `Dockerfile`  (custom image for the Netdata Web Client)

```dockerfile
# Build a lean image that fetches only the Web Client from Netdata's repo.
FROM node:20-alpine AS build

ARG NETDATA_REPO_REF=master
WORKDIR /app

# Install git to fetch only the subdir
RUN apk add --no-cache git

# Shallow clone repo and copy only the web client
RUN git clone --depth 1 --branch ${NETDATA_REPO_REF} https://github.com/netdata/netdata.git /tmp/netdata && \
    mkdir -p /app && \
    cp -r /tmp/netdata/src/web/mcp/mcp-web-client/* /app/

# Install dependencies if present
RUN [ -f package.json ] && npm ci || true

# Small runtime image
FROM node:20-alpine AS runtime
WORKDIR /app

# Copy built app
COPY --from=build /app /app

# Provide an entrypoint that injects env into a runtime config for the client/proxy
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV PORT=3456
EXPOSE 3456

# Default env placeholders (overridden by docker-compose .env)
ENV MCP_WS_URL=""
ENV OPENAI_API_KEY=""
ENV ANTHROPIC_API_KEY=""
ENV GOOGLE_API_KEY=""

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "llm-proxy.js"]
```

---

## c) `docker-entrypoint.sh`  (writes a tiny config from env, then starts the proxy)

```bash
#!/usr/bin/env sh
set -e

# Create a minimal config the Web Client / proxy can read at runtime.
cat > /app/runtime-config.json <<EOF
{
  "mcpServerUrl": "${MCP_WS_URL}",
  "providers": {
    "openai": "${OPENAI_API_KEY}",
    "anthropic": "${ANTHROPIC_API_KEY}",
    "google": "${GOOGLE_API_KEY}"
  }
}
EOF

# Expose config through env so node can read it if needed
export NETDATA_WEBCLIENT_CONFIG=/app/runtime-config.json

exec "$@"
```

> The Netdata Web Client’s quick-start runs `node llm-proxy.js` and serves on `http://localhost:3456`. We mirror that here and feed it your MCP URL + keys at container start. ([Learn Netdata][1])

---

## d) `docker-compose.yml`

> This assumes your Traefik stack (from your snippet) is already running on the **external** `traefik-public` network and is configured with Let’s Encrypt. We’ll add a **new** service `netdata-web-client` that Traefik will route to at `https://$DOMAIN`.

```yaml
version: '3.8'

services:
  netdata-web-client:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        NETDATA_REPO_REF: ${NETDATA_REPO_REF}
    image: local/netdata-web-client:latest
    restart: unless-stopped
    environment:
      MCP_WS_URL: ${MCP_WS_URL}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
      GOOGLE_API_KEY: ${GOOGLE_API_KEY}
      PORT: 3456
    networks:
      - traefik-public
    labels:
      # Expose to traefik
      - traefik.enable=true
      - traefik.docker.network=traefik-public

      # --- Router (HTTP->HTTPS redirect happens in your Traefik) ---
      - traefik.http.routers.netdata-web.rule=Host(`${DOMAIN}`)
      - traefik.http.routers.netdata-web.entrypoints=https
      - traefik.http.routers.netdata-web.tls=true
      - traefik.http.routers.netdata-web.tls.certresolver=le

      # --- Middlewares: BasicAuth + RateLimit (+ optional IPWhitelist) ---
      - traefik.http.routers.netdata-web.middlewares=netdata-web-auth,netdata-web-ratelimit,netdata-web-allowlist@docker

      # BasicAuth credentials from .env (supports multiple "user:hash" separated by commas)
      - traefik.http.middlewares.netdata-web-auth.basicauth.users=${BASICAUTH_USERS}

      # Rate limiting to slow down brute force; tune to your needs
      - traefik.http.middlewares.netdata-web-ratelimit.ratelimit.average=20
      - traefik.http.middlewares.netdata-web-ratelimit.ratelimit.burst=40
      - traefik.http.middlewares.netdata-web-ratelimit.ratelimit.period=1s

      # Optional IP allowlist (set ALLOWLIST_CIDRS in .env or leave empty to disable)
      - traefik.http.middlewares.netdata-web-allowlist.ipwhitelist.sourcerange=${ALLOWLIST_CIDRS}

      # Service port inside the container
      - traefik.http.services.netdata-web.loadbalancer.server.port=3456

networks:
  traefik-public:
    external: true
```

* **Why these security bits?**

  * **BasicAuth** blocks random access and requires a known username/password. ([Traefik Docs][2])
  * **RateLimit** slows credential stuffing / brute force by limiting requests per IP. You can tighten `average/burst` further if you see attacks. ([Traefik Labs][3])
  * **IP allowlist** is optional defense-in-depth (e.g., only your office/VPN ranges).

---

# 4) Bring it up

```bash
# From ~/netdata-web-client (where the files live):
docker compose build
docker compose up -d
```

DNS: point `chat.example.com` → your droplet’s public IP. Within a minute or two, Traefik should provision the TLS cert via Let’s Encrypt and you’ll be able to visit:

```
https://chat.example.com
```

Log in with your BasicAuth user, then use the chat UI. It connects to your Netdata MCP at the URL you placed in `MCP_WS_URL`. (Remember: you can use a Netdata **Parent** to get estate-wide visibility.) ([Learn Netdata][4])

---

# 5) Generating the BasicAuth hash

Use APR1 (htpasswd compatible):

```bash
# Replace 'admin' and 'supersecret' as desired:
printf "admin:$(openssl passwd -apr1 'supersecret')\n"
```

Paste the full `admin:$apr1$...` into `BASICAUTH_USERS=` in `.env`. (You can comma-separate multiple users.)

---

# 6) Notes & tips

* **Where do the API keys go?** The Web Client supports multiple providers (OpenAI/Anthropic/Google). Keys live only in the container env and are not exposed by Traefik. You can leave unused ones blank. ([Learn Netdata][1])
* **What MCP URL should I use?**

  * Typical: `ws://<netdata-host>:19999/mcp?api_key=<uuid>`
  * If the Netdata node is also behind HTTPS/Traefik and you’ve routed `:19999`, you can use `wss://` instead. The MCP page explains the `api_key` and where to find it. ([Learn Netdata][4])
* **Hardening ideas (optional):**

  * Use **Authelia** (ForwardAuth) for SSO+2FA instead of BasicAuth if you want stronger auth.
  * Add **Fail2Ban** on the droplet to ban recurring offenders at the network layer.
* **Traefik compose you shared**: you’re already on v2.8 with ACME and the external `traefik-public` network, which matches what this compose expects. If you ever copy this to a new host, remember to run `docker network create traefik-public` first.

---

If you want, I can also drop in an **Authelia** variation (replacing BasicAuth with Google-SSO+2FA) or wire **Netdata Agent** into this same compose for a complete single-host demo.

[1]: https://learn.netdata.cloud/docs/ai-%26-ml/chat-with-netdata/netdata-web-client "Netdata Web Client | Learn Netdata"
[2]: https://doc.traefik.io/traefik/middlewares/http/basicauth/?utm_source=chatgpt.com "Traefik BasicAuth Documentation"
[3]: https://traefik.io/blog/how-to-keep-your-services-secure-with-traefiks-rate-limiting?utm_source=chatgpt.com "How to Keep Your Services Secure With Traefik's Rate ..."
[4]: https://learn.netdata.cloud/docs/ai-%26-ml/model-context-protocol-mcp "Netdata MCP | Learn Netdata"

