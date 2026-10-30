#!/usr/bin/env bash
# Interactively discover SSH-reachable IPv4 hosts and optionally rename them.
set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SSH_PORT=22
readonly CONNECT_TIMEOUT=4

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer="${answer,,}"
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
  [[ "$a$b$c$d" =~ ^[0-9]+$ ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  printf '%u' "$(( (a<<24) | (b<<16) | (c<<8) | d ))"
}
int_to_ipv4() {
  local n=$1
  printf '%d.%d.%d.%d' "$(( (n>>24)&255 ))" "$(( (n>>16)&255 ))" "$(( (n>>8)&255 ))" "$(( n&255 ))"
}
valid_hostname() {
  local name=$1
  [[ ${#name} -le 253 && "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$name" != *..* ]]
}

command -v ssh >/dev/null || die "OpenSSH client (ssh) is required."
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."

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

printf '\nScanning for hosts with SSH reachable on TCP port %d...\n' "$SSH_PORT"
declare -a reachable=()
for ((ip_n=first_n; ip_n<=last_n; ip_n++)); do
  ip=$(int_to_ipv4 "$ip_n")
  # The SSH handshake is the definitive check; ping is deliberately not required.
  if timeout "$CONNECT_TIMEOUT" ssh -F /dev/null -p "$SSH_PORT" \
      -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
      "invalid-user@$ip" true >/dev/null 2>&1; then
    reachable+=("$ip")
  else
    # An authentication failure still proves that the SSH service answered.
    probe=$(timeout "$CONNECT_TIMEOUT" ssh -F /dev/null -p "$SSH_PORT" \
      -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
      "invalid-user@$ip" true 2>&1 || true)
    if [[ "$probe" == *"Permission denied"* || "$probe" == *"no mutual signature"* || "$probe" == *"Too many authentication failures"* ]]; then
      reachable+=("$ip")
    fi
  fi
done

if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"

for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no "Connect and change this device's hostname?" y || { printf 'Skipped %s.\n' "$ip"; continue; }
  read -r -p 'SSH username: ' username
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; continue; }
  success=false
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    if output=$(ssh -tt -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,password,keyboard-interactive \
      -o StrictHostKeyChecking=accept-new "$username@$ip" 'sh -s' 2>&1 <<'REMOTE_SCRIPT'
set +e
if command -v hostnamectl >/dev/null 2>&1; then
  current=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null)
else
  current=$(hostname 2>/dev/null)
fi
printf '\nCURRENT_HOSTNAME:%s\n' "$current"
printf 'Enter the new hostname, or press Enter to keep it: '
IFS= read -r desired
[ -n "$desired" ] || exit 10
case "$desired" in *[!A-Za-z0-9.-]*|.*|*.) echo 'RESULT:INVALID_HOSTNAME'; exit 11;; esac
[ "${#desired}" -le 253 ] || { echo 'RESULT:INVALID_HOSTNAME'; exit 11; }
if command -v hostnamectl >/dev/null 2>&1; then
  if [ "$(id -u 2>/dev/null)" = 0 ]; then
    hostnamectl set-hostname "$desired"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -v && sudo hostnamectl set-hostname "$desired"
  else
    echo 'RESULT:INSUFFICIENT_PRIVILEGES'; exit 12
  fi
  rc=$?
else
  if [ "$(id -u 2>/dev/null)" = 0 ]; then
    printf '%s\n' "$desired" > /etc/hostname && hostname "$desired"
    rc=$?
  elif command -v sudo >/dev/null 2>&1; then
    sudo sh -c 'printf "%s\n" "$1" > /etc/hostname && hostname "$1"' sh "$desired"
    rc=$?
  else
    echo 'RESULT:INSUFFICIENT_PRIVILEGES'; exit 12
  fi
fi
[ "$rc" -eq 0 ] || { echo 'RESULT:CHANGE_FAILED'; exit 13; }
actual=$(hostname 2>/dev/null)
[ "$actual" = "$desired" ] || { echo 'RESULT:VERIFY_FAILED'; exit 14; }
echo 'RESULT:SUCCESS'
REMOTE_SCRIPT
    ); then
      success=true
      break
    fi
    # Keep host-specific OS and privilege details private; show only a generic summary.
    if [[ "$output" == *"CURRENT_HOSTNAME:"* ]]; then
      printf '%s\n' "$output" | sed -n 's/^.*CURRENT_HOSTNAME:/Current hostname: /p' | tail -n 1
      if [[ "$output" == *"RESULT:SUCCESS"* ]]; then printf 'Hostname changed and verified on %s.\n' "$ip"
      elif [[ "$output" == *"RESULT:INVALID_HOSTNAME"* ]]; then printf 'Invalid hostname. Use letters, numbers, dots, and hyphens; try this device again in a new run.\n'
      elif [[ "$output" == *"RESULT:INSUFFICIENT_PRIVILEGES"* ]]; then printf 'Could not change hostname: administrator privileges are unavailable.\n'
      elif [[ "$output" == *"RESULT:VERIFY_FAILED"* ]]; then printf 'Change command completed, but hostname verification failed.\n'
      elif [[ "$output" == *"RESULT:CHANGE_FAILED"* ]]; then printf 'Could not change hostname. Check administrator permissions and the remote system configuration.\n'
      else printf 'No hostname change was requested.\n'; fi
      success=true
      break
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  [[ "$success" == true ]] || continue
done
printf '\nFinished.\n'
