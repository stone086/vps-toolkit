<#
Generic VPS first-bootstrap script for Windows PowerShell.

What it does:
1. Connects to a fresh Debian/Ubuntu VPS as root using the current root password.
2. Updates the system and installs common tools.
3. Makes only the username part of the root shell prompt green permanently.
4. Adds your selected SSH public key to /root/.ssh/authorized_keys.
5. Changes the SSH login port.
6. Tests new-port key login automatically before disabling the old SSH port.
7. Stores VPS IP/password only in the current PowerShell process variables. It does not write them to disk.

Run on Windows PowerShell:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\vps_first_bootstrap.ps1

Notes:
- Target OS: Debian/Ubuntu.
- Initial login user: root with password.
- Requires internet on the local PC to install the Posh-SSH module if missing.
- If your VPS provider has a firewall/security group, allow the new SSH port there too.
- Do not close your current working SSH/VPS console until the script finishes successfully.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[FAIL] $Text" -ForegroundColor Red
}

function Read-Required {
    param([string]$Prompt)
    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Warn "Input cannot be empty."
    }
}

function Read-Port {
    param([string]$Prompt)
    while ($true) {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warn "Input cannot be empty."
            continue
        }
        $port = 0
        if ([int]::TryParse($raw, [ref]$port) -and $port -ge 1024 -and $port -le 65535) {
            if ($port -eq 22) {
                Write-Warn "Do not use 22 as the new SSH port."
                continue
            }
            return $port
        }
        Write-Warn "Please enter a number between 1024 and 65535."
    }
}

function Select-ItemByNumber {
    param(
        [string]$Title,
        [array]$Items,
        [scriptblock]$Display
    )
    Write-Title $Title
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $line = & $Display $Items[$i]
        Write-Host ("{0}. {1}" -f ($i + 1), $line)
    }
    while ($true) {
        $choice = Read-Host "Select number"
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            return $Items[$n - 1]
        }
        Write-Warn "Invalid selection."
    }
}

function Ensure-PoshSsh {
    Write-Title "Checking Posh-SSH module"
    $module = Get-Module -ListAvailable -Name Posh-SSH | Select-Object -First 1
    if ($null -eq $module) {
        Write-Warn "Posh-SSH is not installed. Installing it for current user..."
        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        } catch {}
        Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Posh-SSH -Force
    Write-Ok "Posh-SSH is ready."
}

function Invoke-Remote {
    param(
        [object]$Session,
        [string]$Command,
        [int]$TimeoutSec = 600
    )
    $result = Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut $TimeoutSec
    if ($result.ExitStatus -ne 0) {
        Write-Fail "Remote command failed with exit status $($result.ExitStatus)."
        if ($result.Output) { Write-Host ($result.Output -join "`n") }
        if ($result.Error) { Write-Host ($result.Error -join "`n") -ForegroundColor Red }
        throw "Remote command failed."
    }
    return $result
}

function Get-PublicKeyFiles {
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir | Out-Null
    }
    return @(Get-ChildItem -Path $sshDir -Filter "*.pub" -File -ErrorAction SilentlyContinue)
}

function New-Ed25519KeyPair {
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    $keyBase = Join-Path $sshDir "id_ed25519_vps"
    if (Test-Path $keyBase) {
        $suffix = Get-Date -Format "yyyyMMddHHmmss"
        $keyBase = Join-Path $sshDir "id_ed25519_vps_$suffix"
    }
    Write-Title "Generating new ED25519 key pair"
    & ssh-keygen.exe -t ed25519 -f $keyBase -C "vps-root-login" -N ""
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
    return Get-Item "$keyBase.pub"
}

function Add-OrUpdateSshConfigHost {
    param(
        [string]$HostAlias,
        [string]$HostName,
        [int]$Port,
        [string]$IdentityFile
    )

    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    $configPath = Join-Path $sshDir "config"
    if (-not (Test-Path $configPath)) {
        New-Item -ItemType File -Path $configPath | Out-Null
    }

    $identityForConfig = $IdentityFile.Replace($env:USERPROFILE, "~").Replace("\", "/")
    $newBlock = @"
Host $HostAlias
    HostName $HostName
    User root
    Port $Port
    IdentityFile $identityForConfig
    IdentitiesOnly yes
"@

    $old = Get-Content -Path $configPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $old) { $old = "" }

    $pattern = "(?ms)^Host\s+$([regex]::Escape($HostAlias))\s*\r?\n.*?(?=^Host\s+|\z)"
    if ([regex]::IsMatch($old, $pattern)) {
        $updated = [regex]::Replace($old, $pattern, $newBlock.TrimEnd() + "`r`n")
    } else {
        $updated = $old.TrimEnd() + "`r`n`r`n" + $newBlock.TrimEnd() + "`r`n"
    }
    Set-Content -Path $configPath -Value $updated -Encoding ascii
    Write-Ok "SSH config updated: Host $HostAlias"
}

function Test-KeyLogin {
    param(
        [string]$Ip,
        [int]$Port,
        [string]$PrivateKeyPath
    )

    Write-Title "Testing key login on new SSH port"
    $args = @(
        "-p", "$Port",
        "-i", $PrivateKeyPath,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        "root@$Ip",
        "echo KEY_LOGIN_OK"
    )

    $output = & ssh.exe @args 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0 -and ($output -join "`n") -match "KEY_LOGIN_OK") {
        Write-Ok "New-port key login works: root@$Ip -p $Port"
        return $true
    }

    Write-Fail "New-port key login failed."
    Write-Host ($output -join "`n") -ForegroundColor Yellow
    return $false
}

function Open-ManualTestWindow {
    param(
        [string]$Ip,
        [int]$Port,
        [string]$PrivateKeyPath
    )
    Write-Title "Opening a separate PowerShell window for visual login test"
    $cmd = "ssh -p $Port -i `"$PrivateKeyPath`" root@$Ip"
    Start-Process powershell.exe -ArgumentList @("-NoExit", "-Command", $cmd)
    Write-Ok "A new PowerShell window has been opened for manual verification."
}

function Read-MultiSelect {
    param([int]$Count)
    while ($true) {
        $raw = Read-Host "Enter numbers to select (e.g. 1 3), or 'all'"
        if ($raw.Trim().ToLower() -eq 'all') { return 1..$Count }
        $nums = $raw -split '[\s,]+' | Where-Object { $_ -ne '' } | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_, [ref]$n)) { $n } else { -1 }
        }
        $invalid = @($nums | Where-Object { $_ -lt 1 -or $_ -gt $Count })
        if ($nums -contains -1 -or $invalid.Count -gt 0) {
            Write-Warn "Invalid input. Enter numbers between 1 and $Count."
            continue
        }
        if ($nums.Count -eq 0) {
            Write-Warn "Please select at least one host."
            continue
        }
        return $nums | Select-Object -Unique | Sort-Object
    }
}

function Get-SshConfigHosts {
    $configPath = Join-Path $env:USERPROFILE ".ssh" "config"
    if (-not (Test-Path $configPath)) { return @() }
    $lines = Get-Content $configPath -ErrorAction SilentlyContinue
    $hosts = [System.Collections.Generic.List[psobject]]::new()
    $cur = $null
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^Host\s+(\S+)$') {
            if ($null -ne $cur -and $null -ne $cur.HostName) { $hosts.Add($cur) }
            $cur = [pscustomobject]@{ Alias = $matches[1]; HostName = $null; Port = 22; User = "root"; IdentityFile = $null }
        } elseif ($null -ne $cur) {
            if      ($line -match '^HostName\s+(.+)$')     { $cur.HostName     = $matches[1].Trim() }
            elseif  ($line -match '^Port\s+(\d+)$')        { $cur.Port         = [int]$matches[1] }
            elseif  ($line -match '^User\s+(.+)$')         { $cur.User         = $matches[1].Trim() }
            elseif  ($line -match '^IdentityFile\s+(.+)$') {
                $cur.IdentityFile = ($matches[1].Trim() -replace '^~', $env:USERPROFILE) -replace '/', '\'
            }
        }
    }
    if ($null -ne $cur -and $null -ne $cur.HostName) { $hosts.Add($cur) }
    return $hosts.ToArray()
}

function Invoke-KeyRotation {
    param([object]$HostEntry)
    $alias  = $HostEntry.Alias
    $ip     = $HostEntry.HostName
    $port   = $HostEntry.Port
    $oldKey = $HostEntry.IdentityFile
    $oldPub = "$oldKey.pub"

    Write-Title "[$alias] Rotating SSH key"
    if ([string]::IsNullOrWhiteSpace($oldKey) -or -not (Test-Path $oldKey)) {
        Write-Fail "Private key not found: $oldKey — skipping."
        return $false
    }

    $sshDir  = Join-Path $env:USERPROFILE ".ssh"
    $newBase = Join-Path $sshDir "id_ed25519_${alias}_$(Get-Date -Format 'yyyyMMddHHmmss')"
    & ssh-keygen.exe -t ed25519 -f $newBase -C "vps-root-$alias" -N ""
    if ($LASTEXITCODE -ne 0) { Write-Fail "ssh-keygen failed."; return $false }

    $newPubText = (Get-Content "$newBase.pub" -Raw).Trim()
    $newPubB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newPubText + "`n"))
    $oldPubText = if (Test-Path $oldPub) { (Get-Content $oldPub -Raw).Trim() } else { "" }
    $oldPubB64  = if ($oldPubText) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($oldPubText + "`n")) } else { "" }

    $emptyCred = New-Object System.Management.Automation.PSCredential("root", (New-Object System.Security.SecureString))
    $sess = $null
    try {
        $sess = New-SSHSession -ComputerName $ip -Port $port -Credential $emptyCred -KeyFile $oldKey -AcceptKey -ConnectionTimeout 20
    } catch {
        Write-Fail "Cannot connect to $alias (${ip}:${port}) — skipping."
        return $false
    }

    $success = $false
    try {
        $addNewKey = "printf '%s' '$newPubB64' | base64 -d > /tmp/nk.pub && grep -qxF -f /tmp/nk.pub /root/.ssh/authorized_keys 2>/dev/null || cat /tmp/nk.pub >> /root/.ssh/authorized_keys; rm -f /tmp/nk.pub"
        Invoke-Remote -Session $sess -Command $addNewKey | Out-Null
        Write-Ok "New public key uploaded to $alias."

        if (-not (Test-KeyLogin -Ip $ip -Port $port -PrivateKeyPath $newBase)) {
            Write-Fail "New key test failed for $alias — reverting."
            $revert = "printf '%s' '$newPubB64' | base64 -d > /tmp/nk.pub && grep -vxF -f /tmp/nk.pub /root/.ssh/authorized_keys > /tmp/ak && mv /tmp/ak /root/.ssh/authorized_keys; rm -f /tmp/nk.pub /tmp/ak"
            Invoke-Remote -Session $sess -Command $revert | Out-Null
            return $false
        }

        if ($oldPubB64) {
            $removeOld = "printf '%s' '$oldPubB64' | base64 -d > /tmp/ok.pub && grep -vxF -f /tmp/ok.pub /root/.ssh/authorized_keys > /tmp/ak && mv /tmp/ak /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys; rm -f /tmp/ok.pub /tmp/ak"
            Invoke-Remote -Session $sess -Command $removeOld | Out-Null
            Write-Ok "Old key removed from authorized_keys on $alias."
        }
        $success = $true
    } finally {
        if ($null -ne $sess) { try { Remove-SSHSession -SSHSession $sess | Out-Null } catch {} }
    }

    if ($success) {
        Add-OrUpdateSshConfigHost -HostAlias $alias -HostName $ip -Port $port -IdentityFile $newBase
        if (Test-Path $oldKey) { Rename-Item $oldKey "$oldKey.old" -ErrorAction SilentlyContinue }
        if (Test-Path $oldPub) { Rename-Item $oldPub "$oldPub.old" -ErrorAction SilentlyContinue }
        Write-Ok "Key rotation done for $alias. New key: $(Split-Path $newBase -Leaf)"
    }
    return $success
}

function Invoke-PortChange {
    param([object]$HostEntry, [int]$NewPort)
    $alias   = $HostEntry.Alias
    $ip      = $HostEntry.HostName
    $curPort = $HostEntry.Port
    $keyFile = $HostEntry.IdentityFile

    Write-Title "[$alias] Changing SSH port: $curPort -> $NewPort"
    if ([string]::IsNullOrWhiteSpace($keyFile) -or -not (Test-Path $keyFile)) {
        Write-Fail "Private key not found: $keyFile — skipping."
        return $false
    }
    if ($curPort -eq $NewPort) {
        Write-Warn "[$alias] Already on port $NewPort — skipping."
        return $true
    }

    $emptyCred = New-Object System.Management.Automation.PSCredential("root", (New-Object System.Security.SecureString))
    $sess = $null
    try {
        $sess = New-SSHSession -ComputerName $ip -Port $curPort -Credential $emptyCred -KeyFile $keyFile -AcceptKey -ConnectionTimeout 20
    } catch {
        Write-Fail "Cannot connect to $alias (${ip}:${curPort}) — skipping."
        return $false
    }

    try {
        $dualListen = @"
set -e
cat > /etc/ssh/sshd_config.d/99-custom-login.conf <<'EOF'
Port $curPort
Port $NewPort
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t
if command -v ufw >/dev/null 2>&1; then
  ufw allow $curPort/tcp >/dev/null 2>&1 || true
  ufw allow $NewPort/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=$curPort/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=$NewPort/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
systemctl restart ssh || systemctl restart sshd
"@
        Invoke-Remote -Session $sess -Command $dualListen | Out-Null
    } finally {
        if ($null -ne $sess) { try { Remove-SSHSession -SSHSession $sess | Out-Null } catch {} }
    }

    Start-Sleep -Seconds 3
    if (-not (Test-KeyLogin -Ip $ip -Port $NewPort -PrivateKeyPath $keyFile)) {
        Write-Fail "New port $NewPort test failed for $alias — old port $curPort kept."
        return $false
    }

    $sess2 = $null
    try {
        $sess2 = New-SSHSession -ComputerName $ip -Port $NewPort -Credential $emptyCred -KeyFile $keyFile -AcceptKey -ConnectionTimeout 20
        $closeOldPort = @"
set -e
cat > /etc/ssh/sshd_config.d/99-custom-login.conf <<'EOF'
Port $NewPort
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t
if command -v ufw >/dev/null 2>&1; then
  ufw allow $NewPort/tcp >/dev/null 2>&1 || true
  ufw delete allow $curPort/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=$NewPort/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --remove-port=$curPort/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
systemctl restart ssh || systemctl restart sshd
"@
        Invoke-Remote -Session $sess2 -Command $closeOldPort | Out-Null
        Write-Ok "Old port $curPort closed on $alias."
    } finally {
        if ($null -ne $sess2) { try { Remove-SSHSession -SSHSession $sess2 | Out-Null } catch {} }
    }

    Add-OrUpdateSshConfigHost -HostAlias $alias -HostName $ip -Port $NewPort -IdentityFile $keyFile
    Write-Ok "Port change done for $alias -> $NewPort"
    return $true
}

function Invoke-AddDeviceKey {
    param([object]$HostEntry, [string]$NewPubKeyB64)
    $alias   = $HostEntry.Alias
    $ip      = $HostEntry.HostName
    $port    = $HostEntry.Port
    $keyFile = $HostEntry.IdentityFile

    Write-Title "[$alias] Adding new device public key"
    if ([string]::IsNullOrWhiteSpace($keyFile) -or -not (Test-Path $keyFile)) {
        Write-Fail "Private key not found: $keyFile — skipping."
        return $false
    }

    $emptyCred = New-Object System.Management.Automation.PSCredential("root", (New-Object System.Security.SecureString))
    $sess = $null
    try {
        $sess = New-SSHSession -ComputerName $ip -Port $port -Credential $emptyCred -KeyFile $keyFile -AcceptKey -ConnectionTimeout 20
    } catch {
        Write-Fail "Cannot connect to $alias (${ip}:${port}) — skipping."
        return $false
    }

    try {
        $addKey = "printf '%s' '$NewPubKeyB64' | base64 -d > /tmp/dk.pub && grep -qxF -f /tmp/dk.pub /root/.ssh/authorized_keys 2>/dev/null || cat /tmp/dk.pub >> /root/.ssh/authorized_keys; rm -f /tmp/dk.pub"
        Invoke-Remote -Session $sess -Command $addKey | Out-Null
        Write-Ok "New device key added to $alias."
        return $true
    } finally {
        if ($null -ne $sess) { try { Remove-SSHSession -SSHSession $sess | Out-Null } catch {} }
    }
}

$plainPassword = $null
$session = $null

try {
    $modeItems = @(
        [pscustomobject]@{ Name = "First Bootstrap  (new VPS)" }
        [pscustomobject]@{ Name = "Maintenance      (rotate keys / change SSH port)" }
    )
    $mode = Select-ItemByNumber -Title "Select mode" -Items $modeItems -Display { param($x) $x.Name }

    if ($mode.Name -like "Maintenance*") {
        Ensure-PoshSsh

        $taskItems = @(
            [pscustomobject]@{ Name = "Rotate SSH keys only" }
            [pscustomobject]@{ Name = "Change SSH port only" }
            [pscustomobject]@{ Name = "Rotate keys AND change port" }
            [pscustomobject]@{ Name = "Add new device public key" }
            [pscustomobject]@{ Name = "Generate new key pair (local only)" }
        )
        $task = Select-ItemByNumber -Title "Select maintenance task" -Items $taskItems -Display { param($x) $x.Name }
        $doKeys   = $task.Name -match "Rotate"
        $doPort   = $task.Name -match "port"
        $doAddKey = $task.Name -match "device"
        $doGenKey = $task.Name -match "Generate"

        if ($doGenKey) {
            $keySuffix = Read-Required "Enter key name suffix"
            $sshDir  = Join-Path $env:USERPROFILE ".ssh"
            $keyBase = Join-Path $sshDir "id_ed25519_$keySuffix"
            if (Test-Path $keyBase) {
                $keyBase = Join-Path $sshDir "id_ed25519_${keySuffix}_$(Get-Date -Format 'yyyyMMddHHmmss')"
            }
            & ssh-keygen.exe -t ed25519 -f $keyBase -C "device-$keySuffix" -N ""
            if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
            $pubContent = (Get-Content "$keyBase.pub" -Raw).Trim()
            Write-Ok "Key pair generated."
            Write-Host ""
            Write-Host "Private key : $keyBase" -ForegroundColor Cyan
            Write-Host "Public key  : $keyBase.pub" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Public key content (copy and use with option 4 on the main device):" -ForegroundColor Cyan
            Write-Host $pubContent -ForegroundColor Green

        } else {
            $allHosts = Get-SshConfigHosts
            if ($allHosts.Count -eq 0) { throw "No VPS hosts found in ~/.ssh/config." }

            Write-Title "Configured VPS hosts"
            for ($i = 0; $i -lt $allHosts.Count; $i++) {
                Write-Host ("  {0}. {1,-20} {2}:{3}" -f ($i + 1), $allHosts[$i].Alias, $allHosts[$i].HostName, $allHosts[$i].Port)
            }
            $selectedIndices = Read-MultiSelect -Count $allHosts.Count
            $selectedHosts = @($selectedIndices | ForEach-Object { $allHosts[$_ - 1] })
            Write-Ok "Selected: $($selectedHosts.Alias -join ', ')"

            $maintNewPort = 0
            if ($doPort) { $maintNewPort = Read-Port "Enter new SSH port for all VPS" }

            $newDevicePubKeyB64 = ""
            if ($doAddKey) {
                Write-Title "New device public key input"
                $keyInputItems = @(
                    [pscustomobject]@{ Name = "Paste public key content" }
                    [pscustomobject]@{ Name = "Enter path to .pub file" }
                )
                $keyInputChoice = Select-ItemByNumber -Title "How to provide the new key" -Items $keyInputItems -Display { param($x) $x.Name }
                if ($keyInputChoice.Name -match "path") {
                    $pubFilePath = Read-Required "Enter full path to .pub file"
                    if (-not (Test-Path $pubFilePath)) { throw "File not found: $pubFilePath" }
                    $newDevicePubText = (Get-Content $pubFilePath -Raw).Trim()
                } else {
                    $newDevicePubText = Read-Required "Paste the public key"
                }
                if ($newDevicePubText -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)\s+') {
                    throw "Invalid public key format."
                }
                $newDevicePubKeyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newDevicePubText + "`n"))
            }

            $ok = 0; $fail = 0
            foreach ($h in $selectedHosts) {
                $curHost = $h
                if ($doKeys) {
                    if (Invoke-KeyRotation -HostEntry $curHost) {
                        $refreshed = Get-SshConfigHosts | Where-Object { $_.Alias -eq $curHost.Alias } | Select-Object -First 1
                        if ($null -ne $refreshed) { $curHost = $refreshed }
                        $ok++
                    } else { $fail++ }
                }
                if ($doPort) {
                    if (Invoke-PortChange -HostEntry $curHost -NewPort $maintNewPort) { $ok++ } else { $fail++ }
                }
                if ($doAddKey) {
                    if (Invoke-AddDeviceKey -HostEntry $curHost -NewPubKeyB64 $newDevicePubKeyB64) { $ok++ } else { $fail++ }
                }
            }
            Write-Title "Maintenance summary"
            Write-Ok "Succeeded: $ok   Failed: $fail"
        }

    } else {

    Write-Title "VPS first bootstrap"
    $vpsIp = Read-Required "Enter new VPS IP"
    $newPort = Read-Port "Enter new SSH port"
    $hostAlias = Read-Required "Enter local SSH alias"
    $newHostname = Read-Required "Enter new VPS hostname"

    Write-Title "SSH key selection"
    $pubKeys = Get-PublicKeyFiles
    if ($pubKeys.Count -eq 0) {
        Write-Warn "No public key found in ~/.ssh. A new key pair will be generated."
        $selectedPub = New-Ed25519KeyPair
    } else {
        $items = @($pubKeys) + @([pscustomobject]@{ FullName = "__GENERATE_NEW__"; Name = "Generate a new id_ed25519_vps key" })
        $selected = Select-ItemByNumber -Title "Select SSH public key" -Items $items -Display { param($x) $x.Name }
        if ($selected.FullName -eq "__GENERATE_NEW__") {
            $selectedPub = New-Ed25519KeyPair
        } else {
            $selectedPub = $selected
        }
    }

    $publicKeyPath = $selectedPub.FullName
    $privateKeyPath = $publicKeyPath -replace '\.pub$', ''
    if (-not (Test-Path $privateKeyPath)) {
        throw "Private key not found for selected public key: $privateKeyPath"
    }

    Write-Ok "Selected public key: $publicKeyPath"
    Write-Ok "Selected private key: $privateKeyPath"

    $securePassword = Read-Host "Enter current root password for VPS" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    Ensure-PoshSsh

    Write-Title "Connecting to VPS as root on port 22"
    $cred = New-Object System.Management.Automation.PSCredential("root", $securePassword)
    $session = New-SSHSession -ComputerName $vpsIp -Port 22 -Credential $cred -AcceptKey -ConnectionTimeout 20
    Write-Ok "Connected to $vpsIp."

    Write-Title "Detecting OS"
    $osDetect = @'
set -e
. /etc/os-release
echo "$ID|$VERSION_ID|$PRETTY_NAME"
'@
    $osResult = Invoke-Remote -Session $session -Command $osDetect
    $osParts = ($osResult.Output -join "").Trim().Split("|")
    $osId = $osParts[0]
    Write-Ok "Detected: $($osParts[2])"

    Write-Title "Installing common tools and updating system"
    $baseSetup = @'
set -e
. /etc/os-release
case "$ID" in
  debian|ubuntu)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y upgrade
    apt-get install -y curl wget vim nano git unzip zip tar htop ufw fail2ban \
      ca-certificates gnupg lsb-release software-properties-common net-tools \
      iproute2 dnsutils rsync jq tmux build-essential lsof mtr-tiny ncdu iotop sysstat
    ;;
  centos|rhel|rocky|almalinux|fedora)
    if command -v dnf >/dev/null 2>&1; then PKG=dnf; else PKG=yum; fi
    $PKG -y update
    $PKG -y install epel-release >/dev/null 2>&1 || true
    $PKG -y install curl wget vim nano git unzip zip tar htop fail2ban \
      ca-certificates net-tools iproute bind-utils rsync jq tmux \
      gcc make lsof mtr ncdu iotop sysstat firewalld
    ;;
  *)
    echo "Unsupported OS: $PRETTY_NAME" >&2
    exit 1
    ;;
esac
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban >/dev/null 2>&1 || true
'@
    Invoke-Remote -Session $session -Command $baseSetup -TimeoutSec 1800 | Out-Null
    Write-Ok "Base packages installed/updated."

    Write-Title "Setting VPS hostname"
    Invoke-Remote -Session $session -Command "hostnamectl set-hostname '$newHostname'" | Out-Null
    Write-Ok "Hostname set to: $newHostname"

    Write-Title "Configuring permanent green root username prompt"
    $promptSetup = @'
set -e
BASHRC="/root/.bashrc"
touch "$BASHRC"
START="# >>> custom root prompt color >>>"
END="# <<< custom root prompt color <<<"
TMP="$(mktemp)"
awk -v s="$START" -v e="$END" '
  $0 == s {skip=1; next}
  $0 == e {skip=0; next}
  skip != 1 {print}
' "$BASHRC" > "$TMP"
cat >> "$TMP" <<'EOF'
# >>> custom root prompt color >>>
# Only color the username part. Keep @, hostname, path, and prompt symbol unchanged/default.
if [ "$(id -u)" -eq 0 ]; then
    export PS1='\[\e[32m\]\u\[\e[0m\]@\h:\w\$ '
fi
# <<< custom root prompt color <<<
EOF
cat "$TMP" > "$BASHRC"
rm -f "$TMP"
'@
    Invoke-Remote -Session $session -Command $promptSetup | Out-Null
    Write-Ok "Root prompt configured."

    Write-Title "Installing selected SSH public key for root"
    $pubText = (Get-Content -Path $publicKeyPath -Raw).Trim()
    if ($pubText -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)\s+') {
        throw "Selected public key does not look like a valid OpenSSH public key."
    }
    $pubB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pubText + "`n"))
    $keySetup = @"
set -e
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
printf '%s' '$pubB64' | base64 -d > /tmp/new_root_key.pub
if ! grep -qxF -f /tmp/new_root_key.pub /root/.ssh/authorized_keys; then
  cat /tmp/new_root_key.pub >> /root/.ssh/authorized_keys
fi
rm -f /tmp/new_root_key.pub
chown -R root:root /root/.ssh
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
"@
    Invoke-Remote -Session $session -Command $keySetup | Out-Null
    Write-Ok "Public key added to /root/.ssh/authorized_keys."

    Write-Title "Configuring SSH daemon"
    $sshdSetup = @"
set -e
mkdir -p /etc/ssh/sshd_config.d
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.generic.4(date +%Y%m%d%H%M%S)
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
fi
cat > /etc/ssh/sshd_config.d/99-custom-login.conf <<'EOF'
Port 22
Port $newPort
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow $newPort/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port=$newPort/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
systemctl restart ssh || systemctl restart sshd
"@
    Invoke-Remote -Session $session -Command $sshdSetup | Out-Null
    Write-Ok "SSHD now listens on both 22 and $newPort. Password login is disabled."

    Start-Sleep -Seconds 3

    $keyOk = Test-KeyLogin -Ip $vpsIp -Port $newPort -PrivateKeyPath $privateKeyPath
    if (-not $keyOk) {
        Write-Fail "The script will NOT close port 22 because new-port key login failed."
        Write-Warn "You can still use the current root password session or provider console to fix SSH."
        throw "New-port key login test failed."
    }

    $manualRaw = Read-Host "Open a separate PowerShell window to visually test login? 1=Yes 2=No [2]"
    if ($manualRaw -eq "1") {
        Open-ManualTestWindow -Ip $vpsIp -Port $newPort -PrivateKeyPath $privateKeyPath
    }

    Write-Title "Closing old SSH port 22 after successful key login test"
    $closeOld = @"
set -e
cat > /etc/ssh/sshd_config.d/99-custom-login.conf <<'EOF'
Port $newPort
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t
if command -v ufw >/dev/null 2>&1; then
  ufw allow $newPort/tcp >/dev/null 2>&1 || true
  ufw delete allow 22/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=$newPort/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --remove-port=22/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
systemctl restart ssh || systemctl restart sshd
"@
    Invoke-Remote -Session $session -Command $closeOld | Out-Null
    Write-Ok "Old SSH port 22 removed from SSHD config and firewall."

    Add-OrUpdateSshConfigHost -HostAlias $hostAlias -HostName $vpsIp -Port $newPort -IdentityFile $privateKeyPath

    Write-Title "Final verification"
    if (-not (Test-KeyLogin -Ip $vpsIp -Port $newPort -PrivateKeyPath $privateKeyPath)) {
        throw "Final key-login verification failed. Check provider console/firewall."
    }

    Write-Ok "VPS bootstrap completed."
    Write-Host ""
    Write-Host "You can now log in with:" -ForegroundColor Cyan
    Write-Host "  ssh $hostAlias" -ForegroundColor Green
    Write-Host "or:" -ForegroundColor Cyan
    Write-Host "  ssh -p $newPort -i `"$privateKeyPath`" root@$vpsIp" -ForegroundColor Green
    Write-Host ""
    Write-Warn "Also check your VPS provider firewall/security group: TCP $newPort must be allowed there too."

    } # end else (bootstrap mode)
}
catch {
    Write-Fail $_.Exception.Message
    Write-Warn "If SSH is broken, use your VPS provider console/VNC/rescue panel. The script keeps port 22 until new-port key login succeeds."
}
finally {
    if ($null -ne $session) {
        try { Remove-SSHSession -SSHSession $session | Out-Null } catch {}
    }

    # Clear sensitive values from script variables as much as PowerShell allows.
    $plainPassword = $null
    $securePassword = $null
    $cred = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    Write-Title "Cleanup"
    Write-Ok "Temporary IP/password variables were not written to disk and are cleared from this script scope."
}
