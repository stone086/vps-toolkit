#!/usr/bin/env bash
# Generate a new ED25519 SSH key pair for VPS login.
# Works on Linux and Android Termux.

set -e

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

while true; do
    read -rp "Enter key name suffix: " suffix
    if [ -n "$suffix" ]; then break; fi
    echo "[WARN] Input cannot be empty."
done

KEY_BASE="$SSH_DIR/id_ed25519_${suffix}"
if [ -f "$KEY_BASE" ]; then
    KEY_BASE="${KEY_BASE}_$(date +%Y%m%d%H%M%S)"
fi

ssh-keygen -t ed25519 -f "$KEY_BASE" -C "device-${suffix}" -N ""

echo ""
echo "Private key : $KEY_BASE"
echo "Public key  : $KEY_BASE.pub"
echo ""
echo "Public key content (copy and add to VPS via win-vps-toolkit option 4):"
echo ""
cat "$KEY_BASE.pub"
