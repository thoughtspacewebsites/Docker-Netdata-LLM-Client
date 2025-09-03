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

