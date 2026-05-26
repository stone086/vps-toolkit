# win-vps-toolkit

A Windows PowerShell script for bootstrapping fresh Linux VPS servers and managing ongoing SSH maintenance — all from your local Windows machine.

## Requirements

- Windows PowerShell 5.1+
- [Posh-SSH](https://github.com/darkoperator/Posh-SSH) module (auto-installed if missing)
- OpenSSH client (`ssh.exe`, `ssh-keygen.exe`) — included in Windows 10/11
- Target VPS: Debian, Ubuntu, CentOS, RHEL, Rocky Linux, AlmaLinux, or Fedora

## Quick Start

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\vps_first_bootstrap.ps1
```

## Modes

### 1. First Bootstrap

For freshly provisioned VPS servers. Connects via root password on port 22 and performs full setup.

**Steps performed:**
1. Detects the Linux distribution
2. Updates the system and installs common tools
3. Sets the VPS hostname
4. Configures a green-colored root username in the shell prompt
5. Uploads your selected SSH public key to `/root/.ssh/authorized_keys`
6. Configures SSHD — listens on both port 22 and the new port during transition
7. Tests key login on the new port before closing port 22
8. Closes port 22 after successful verification
9. Writes an SSH shortcut to `~/.ssh/config` for one-command login

**After bootstrap:**
```powershell
ssh <your-alias>
```

**Installed packages:**

| Category | Packages |
|----------|----------|
| Editors | vim, nano |
| Network | curl, wget, net-tools, iproute2, dnsutils, mtr-tiny |
| Dev tools | git, build-essential, rsync |
| Archives | unzip, zip, tar |
| Monitoring | htop, iotop, ncdu, sysstat |
| Security | ufw / firewalld, fail2ban |
| Utilities | tmux, jq, lsof, ca-certificates, gnupg |

### 2. Maintenance

For managing existing VPS servers already configured with SSH key login.

**Available tasks:**

| # | Task | Description |
|---|------|-------------|
| 1 | Rotate SSH keys only | Generates a new ED25519 key pair, uploads it, verifies login, removes the old key, updates `~/.ssh/config` |
| 2 | Change SSH port only | Switches to a new SSH port with dual-listen transition and automatic verification |
| 3 | Rotate keys AND change port | Performs key rotation first, then port change using the new key |
| 4 | Add new device public key | Adds another device's public key to selected VPS servers — no password auth required |
| 5 | Generate new key pair (local only) | Creates a new ED25519 key pair locally and displays the public key for copying |

You can select which VPS hosts to apply the operation to — by number or `all`.

## Security Design

- **No passwords written to disk** — root password is held in `SecureString` and zeroed after use
- **Dual-port transition** — new SSH port is tested before port 22 is closed; script aborts if the test fails
- **`sshd -t` validation** — every config change is syntax-checked before restarting SSHD
- **Idempotent key upload** — duplicate keys are never added to `authorized_keys`
- **Key rotation safety** — new key is uploaded and tested before the old key is removed; reverts automatically on failure
- **Password authentication disabled** after first bootstrap (`PasswordAuthentication no`)

## SSH Config Example

After bootstrap, `~/.ssh/config` will contain:

```
Host myserver
    HostName 1.2.3.4
    User root
    Port 22222
    IdentityFile ~/.ssh/id_ed25519_vps
    IdentitiesOnly yes
```

## Notes

- If your VPS provider has an external firewall or security group, manually allow the new SSH port there as well.
- Do not close your current SSH session until the script completes successfully.
- If something goes wrong, use your VPS provider's console or VNC/rescue panel to recover — port 22 is kept open until the new port is confirmed working.
