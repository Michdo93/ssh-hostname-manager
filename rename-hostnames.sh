#!/usr/bin/env bash
# Interactively discover SSH-reachable IPv4 hosts and optionally rename them.
set -uo pipefail

readonly SSH_PORT="${SSH_PORT:-22}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"
readonly SCAN_PARALLEL="${SCAN_PARALLEL:-32}"

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      '') [[ "$default" == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }

# Prints the address if an SSH server answers. An authentication failure for a user that
# does not exist still proves that sshd is there. No host keys are stored while scanning.
probe_ssh() {
  local ip=$1 out
  out=$(timeout "$((CONNECT_TIMEOUT + 3))" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ssh-scan@$ip" true 2>&1) && { printf '%s\n' "$ip"; return; }
  case "$out" in
    *'Permission denied'*|*'Too many authentication failures'*|*'no mutual signature'*) printf '%s\n' "$ip" ;;
  esac
}

ask_range() {
  while true; do
    printf '\nEnter the first and last IPv4 address in the range.\n'
    read -r -p 'First address: ' first || exit 0
    read -r -p 'Last address:  ' last || exit 0
    first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
    last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
    (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
    (( last_n - first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
    if ask_yes_no "Scan ${first} through ${last}?" y; then break; fi
  done
}

# Fills the array "reachable" (sorted) with all addresses of the range that run sshd.
scan_range() {
  local n
  printf '\nScanning for SSH services on TCP port %d (%d parallel probes)...\n' "$SSH_PORT" "$SCAN_PARALLEL"
  export -f probe_ssh
  export SSH_PORT CONNECT_TIMEOUT
  mapfile -t reachable < <(
    for ((n=first_n; n<=last_n; n++)); do int_to_ipv4 "$n"; printf '\n'; done |
      xargs -P "$SCAN_PARALLEL" -I{} bash -c 'probe_ssh "$1"' _ {} |
      sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
  if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
  printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"
}

# run_remote USER IP SCRIPT [ARG...]
# The POSIX-sh script is sent base64-encoded as the remote command, NOT on stdin. That way
# the remote terminal (-tt) is connected to the local keyboard: password prompts of sudo and
# questions of the script work, and the script text is never echoed back (an echoed script
# would contain its own result markers). Output is shown live and copied to $LOG.
# Returns the exit code of ssh (255 = connection/authentication failed).
run_remote() {
  local user=$1 ip=$2 script=$3 b64 cmd arg q="'"
  shift 3
  b64=$(printf '%s' "$script" | base64 | tr -d '\n')
  cmd="sh -c \"\$(echo $b64 | base64 -d)\" remote"
  for arg in "$@"; do cmd+=" '${arg//$q/$q\\$q$q}'"; done
  ssh -tt -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=15 \
    -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,keyboard-interactive,password \
    -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd" 2>&1 | tee "$LOG"
  return "${PIPESTATUS[0]}"
}

# Last result marker the remote script printed ("" if none).
remote_result() { grep -ao '@@RESULT:[A-Z_]*@@' "$LOG" | tail -n 1 | sed 's/^@@RESULT://; s/@@$//'; }

# with_login IP REMOTE_SCRIPT [ARG...] - asks for the user name and tries up to three
# logins. Sets "result" to the marker of the remote script, or LOGIN_FAILED / NO_RESULT.
with_login() {
  local ip=$1 rc attempt
  shift
  result=LOGIN_FAILED
  read -r -p 'SSH username: ' username || return 1
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; result=SKIPPED; return 1; }
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    run_remote "$username" "$ip" "$@"; rc=$?
    result=$(remote_result)
    [[ -n "$result" ]] && return 0
    if (( rc != 255 )); then result=NO_RESULT; return 0; fi
    if grep -aq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$LOG"; then
      printf 'The host key of %s has changed. Verify the device, then remove the old key with: ssh-keygen -R %s\n' "$ip" "$ip"
      return 1
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  return 1
}

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."
command -v base64 >/dev/null || die "The 'base64' command is required."
command -v xargs >/dev/null || die "The 'xargs' command is required."


# Remote part (POSIX sh). Runs in the remote terminal: the question and a possible sudo
# password prompt are answered on the local keyboard. Result markers are hidden on screen.
read -r -d '' REMOTE_SCRIPT <<'REMOTE'
mark() { printf '@@RESULT:%s@@\r\033[K' "$1"; }
if command -v hostnamectl >/dev/null 2>&1; then
  current=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null)
else
  current=$(hostname 2>/dev/null)
fi
printf 'Current hostname: %s\n' "$current"
printf 'Enter the new hostname, or press Enter to keep it: '
IFS= read -r desired
desired=$(printf '%s' "$desired" | tr -d '\r')
[ -n "$desired" ] && [ "$desired" != "$current" ] || { mark UNCHANGED; exit 0; }
case "$desired" in *[!A-Za-z0-9.-]*|.*|*.|-*|*-|*..*) mark INVALID_HOSTNAME; exit 0;; esac
[ "${#desired}" -le 253 ] || { mark INVALID_HOSTNAME; exit 0; }
if [ "$(id -u)" = 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else mark INSUFFICIENT_PRIVILEGES; exit 0; fi
if command -v hostnamectl >/dev/null 2>&1 && $SUDO hostnamectl set-hostname "$desired" 2>/dev/null; then
  rc=0
else
  # no systemd (or hostnamectl refused): classic files
  $SUDO sh -c 'printf "%s\n" "$1" > /etc/hostname && hostname "$1"' sh "$desired"
  rc=$?
fi
[ "$rc" -eq 0 ] || { mark CHANGE_FAILED; exit 0; }
# keep 127.0.1.1 in /etc/hosts in sync (Debian convention), otherwise sudo warns
# "unable to resolve host"
if grep -q "^127\.0\.1\.1[[:space:]]" /etc/hosts 2>/dev/null; then
  $SUDO sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$desired/" /etc/hosts
elif ! grep -Eq "[[:space:]]$desired([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
  printf '127.0.1.1\t%s\n' "$desired" | $SUDO sh -c 'cat >> /etc/hosts'
fi
[ "$(hostname 2>/dev/null)" = "$desired" ] || { mark VERIFY_FAILED; exit 0; }
mark SUCCESS
REMOTE

ask_range
scan_range

for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no "Connect and change this device's hostname?" y || { printf 'Skipped %s.\n' "$ip"; continue; }
  with_login "$ip" "$REMOTE_SCRIPT" || continue
  case "$result" in
    SUCCESS) printf 'Hostname changed and verified on %s.\n' "$ip" ;;
    UNCHANGED) printf 'No hostname change was requested.\n' ;;
    INVALID_HOSTNAME) printf 'Invalid hostname. Use letters, numbers, dots, and hyphens; try this device again in a new run.\n' ;;
    INSUFFICIENT_PRIVILEGES) printf 'Could not change hostname: administrator privileges are unavailable.\n' ;;
    VERIFY_FAILED) printf 'Change command completed, but hostname verification failed.\n' ;;
    CHANGE_FAILED) printf 'Could not change hostname. Check administrator permissions and the remote system configuration.\n' ;;
    *) printf 'The remote session ended without a result (unsupported shell or interrupted).\n' ;;
  esac
done
printf '\nFinished.\n'
