#!/bin/bash
###############################################################################
# Bootstrap runner for whm_setup
#
# What this does every time you run it:
#   1) Clones the repo into /opt/whm-setup the first time, or
#   2) Resets any local changes + pulls the latest version on later runs
#   3) Executes whm_setup immediately
#
# Usage (run this exact command any time you want the LATEST script to run):
#   bash <(curl -sSL https://raw.githubusercontent.com/Samirlinux/whm/main/run.sh)
###############################################################################

set -euo pipefail

REPO_URL="https://github.com/Samirlinux/whm.git"
REPO_DIR="/opt/whm-setup"
SCRIPT_NAME="whm_setup"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Must be run as root." >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "git not found, installing..."
    yum install -y git 2>/dev/null || apt-get install -y git 2>/dev/null
fi

if [ -d "$REPO_DIR/.git" ]; then
    echo "== Existing checkout found at $REPO_DIR - resetting and pulling latest =="
    cd "$REPO_DIR"
    git fetch origin
    git reset --hard origin/main
    git pull
else
    echo "== No existing checkout - cloning fresh into $REPO_DIR =="
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi

chmod +x "$SCRIPT_NAME"

echo "== Running $SCRIPT_NAME (latest version) =="
exec bash "$REPO_DIR/$SCRIPT_NAME"
