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

