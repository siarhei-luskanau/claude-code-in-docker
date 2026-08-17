#!/bin/bash
set -euo pipefail

TOOLS=/opt/claude-tools
export PATH="$TOOLS/bin:$PATH"

mkdir -p "$TOOLS" /var/cache/apt/archives/partial /var/lib/apt/lists/partial
chown node:node "$TOOLS" /home/node/.claude /home/node/.claude.json 2>/dev/null || true

rm -f /etc/apt/apt.conf.d/docker-clean
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/99keep-cache

if [ "${SKIP_APT:-0}" != "1" ]; then
  export DEBIAN_FRONTEND=noninteractive
  PKGS="git ca-certificates ${EXTRA_APT_PACKAGES:-}"
  apt_install() { apt-get install -y -qq --no-install-recommends $PKGS >/dev/null; }
  ok=0
  for attempt in 1 2 3 4 5; do
    if ! ls /var/lib/apt/lists/*_Packages* >/dev/null 2>&1; then
      apt-get update -qq || { echo "apt busy or offline (attempt $attempt), retrying in 3s..." >&2; sleep 3; continue; }
    fi
    if apt_install || { apt-get update -qq && apt_install; }; then
      ok=1
      break
    fi
    echo "apt busy (attempt $attempt), retrying in 3s..." >&2
    sleep 3
  done
  [ "$ok" = "1" ] || { echo "ERROR: apt-get install failed after 5 attempts" >&2; exit 1; }
fi

command -v git >/dev/null 2>&1 && git config --system --add safe.directory '*'

run_as_node() {
  runuser -u node -- env HOME=/home/node USER=node LOGNAME=node \
    PATH="$TOOLS/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    NPM_CONFIG_PREFIX="$TOOLS" \
    CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    "$@"
}

if [ "${CLAUDE_DOCKER_UPDATE:-0}" = "1" ]; then
  echo "Updating Claude Code in the shared tools directory..."
  (
    flock -w 600 9
    run_as_node npm install -g @anthropic-ai/claude-code@latest
  ) 9>"$TOOLS/.install.lock"
  run_as_node claude --version
  exit 0
fi

if [ ! -x "$TOOLS/bin/claude" ]; then
  echo "Installing Claude Code into the shared tools directory (first run, may take a minute)..."
  (
    flock -w 600 9
    if [ ! -x "$TOOLS/bin/claude" ]; then
      run_as_node npm install -g @anthropic-ai/claude-code
    fi
  ) 9>"$TOOLS/.install.lock"
fi

cd /workspace
exec runuser -u node -- env HOME=/home/node USER=node LOGNAME=node \
  PATH="$TOOLS/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  NPM_CONFIG_PREFIX="$TOOLS" \
  CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  claude --dangerously-skip-permissions "$@"
