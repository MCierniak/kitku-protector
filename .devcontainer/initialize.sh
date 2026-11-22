#!/usr/bin/env bash
# Runs on the host before the containers are built (devcontainer "initializeCommand").
#
# Writes .devcontainer/.env so that the containers use the same user, the same home
# directory and the same workspace path as the host, and so that the development
# container gets this repository's PRP store.
#
# Optional per-machine settings go into .devcontainer/local.env (not tracked):
#   KITKU_ISO_DIR=/mnt/d/ISO     directory with installation media, mounted at /iso
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(cd "$here/.." && pwd -P)"

# Read KEY=VALUE overrides without executing the file.
iso_dir="${KITKU_ISO_DIR:-}"
if [ -f "$here/local.env" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            KITKU_ISO_DIR) iso_dir="$value" ;;
        esac
    done < "$here/local.env"
fi
iso_dir="${iso_dir:-$workspace/lab/iso}"

# The PRP store of this repository: adopt the store that already records this path,
# otherwise use the name the PRP tools would give it.
prp_home="${PRP_HOME:-$HOME/.prp}"
store="$(grep -lsF "\"path\": \"$workspace\"" "$prp_home"/*/project.json 2>/dev/null | head -1 || true)"
store="${store%/project.json}"
if [ -z "$store" ]; then
    name="$(basename "$workspace" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
    store="$prp_home/${name:-project}-$(printf %s "$workspace" | git hash-object --stdin | cut -c1-8)"
fi

# Create the mount sources as the current user; Docker would create them as root.
mkdir -p "$HOME/.claude" "$store" "$iso_dir"

# Claude Code keeps one state file beside its directory (~/.claude.json). Inside the
# container that file lives in the mounted directory instead (CLAUDE_CONFIG_DIR), so it
# survives a rebuild of the container without a second, single-file mount. Seed the
# container's copy once, so the first start there does not repeat the onboarding.
if [ -f "$HOME/.claude.json" ] && [ ! -e "$HOME/.claude/.claude.json" ]; then
    cp -p "$HOME/.claude.json" "$HOME/.claude/.claude.json"
    echo "initialize.sh: seeded $HOME/.claude/.claude.json from $HOME/.claude.json"
fi

if [ ! -e /dev/kvm ]; then
    echo "initialize.sh: /dev/kvm does not exist. The lab container needs KVM and will not start." >&2
    echo "initialize.sh: on WSL2, nested virtualisation has to be enabled (Windows 11)." >&2
fi

tmp="$(mktemp "$here/.env.XXXXXX")"
cat > "$tmp" <<EOF
# Written by initialize.sh on every start. Do not edit; use local.env for overrides.
KITKU_USER=$(id -un)
KITKU_UID=$(id -u)
KITKU_GID=$(id -g)
KITKU_HOME=$HOME
KITKU_WORKSPACE=$workspace
KITKU_PRP_STORE=$store
KITKU_ISO_DIR=$iso_dir
EOF
mv "$tmp" "$here/.env"
echo "initialize.sh: wrote $here/.env"
