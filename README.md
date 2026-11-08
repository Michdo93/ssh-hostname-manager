# SSH Hostname Manager

An interactive Bash utility that scans an IPv4 range for SSH services and lets you change the hostname on selected devices. It supports Linux systems with `hostnamectl`, Linux systems using `/etc/hostname`, and Windows hosts that expose PowerShell through OpenSSH.

## Requirements

- Bash 4 or newer.
- OpenSSH client (`ssh`).
- `timeout`, `xargs` and `base64` (included on most Linux distributions and available in WSL).
- Each target must run an SSH server and allow connections on TCP port 22.
- A remote account with permission to change the hostname. On Linux, this usually means root or `sudo` access. On Windows, the SSH account must be an administrator and the SSH default shell must be PowerShell.

The script does not require `nmap`: it checks SSH reachability directly, which also works when ICMP ping is blocked. The first connection may ask you to trust the host key; verify the fingerprint before accepting it.

## Preparation

### Linux targets

Install and enable an SSH server (package names vary; common packages are `openssh-server` or `openssh`). Make sure TCP port 22 is allowed through the host firewall. For password-based changes requiring `sudo`, the account must be allowed to run the required command with `sudo` and enter its password interactively. Root login is not required.

On systems without `hostnamectl` (or where it is refused, e.g. without systemd), the script writes `/etc/hostname` and applies the running hostname. In `/etc/hosts` only the Debian-style `127.0.1.1` line is updated (or added if the new name is not listed), so `sudo` keeps resolving the host name; all other entries stay untouched.

### Windows targets

Install and enable the Windows OpenSSH Server optional feature, allow inbound TCP port 22, and configure the SSH server's default shell as PowerShell. Use an administrator account. Windows OpenSSH does not reliably provide an elevation prompt over SSH, so the account/session must already have the rights required by `Rename-Computer`.

> Windows hostname changes may require a reboot to take full effect. This tool reports the result and does not reboot devices automatically.

### Credentials

The script prompts for an SSH username; OpenSSH handles password authentication and prompts for the password when needed. Passwords are not saved by the script. SSH keys are recommended for repeated use. If a Linux command needs `sudo`, the remote sudo prompt may request the same account password again.

## Run

From a Bash shell (Linux, macOS with `timeout` installed, or WSL):

```bash
chmod +x rename-hostnames.sh
./rename-hostnames.sh
```

Enter the first and last IPv4 addresses, for example `192.168.0.1` and `192.168.0.254`, and confirm the range. The tool scans the range, lists the number of SSH-reachable devices, and asks whether to handle each device. Yes accepts `y`, `Y`, `yes`, or `Yes`; Enter uses the displayed default. No accepts `n`, `N`, `no`, or `No`.

For each selected device, enter the SSH username and authenticate. SSH login is attempted up to three times. After login, the remote session displays the current hostname and asks for a replacement. Press Enter to leave it unchanged. A requested change is applied and verified before the script reports the outcome. A failed login skips that device and continues with the next one.

## Notes

- Only IPv4 ranges are accepted; ranges larger than 65,536 addresses are refused.
- Host key checking is enabled. Accepted keys are stored in `~/.ssh/known_hosts`.
- SSH port 22 by default; set `SSH_PORT=2222` for another port. `SCAN_PARALLEL` (32) and `CONNECT_TIMEOUT` (4 s) tune the scan.
- The remote script is sent base64-encoded as the remote command of `ssh -tt`, not on stdin: the remote terminal stays connected to your keyboard (hostname question, sudo password) and the script is never echoed back. Result markers are hidden on screen.
- The Windows PowerShell rename flow is planned for systems configured with PowerShell as the SSH shell; the current script's remote payload is POSIX shell and therefore does not yet implement Windows renaming.
