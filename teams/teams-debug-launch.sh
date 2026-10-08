#!/bin/bash
# Launches Microsoft Teams with a localhost-only DevTools (CDP) port. Refuses while Teams is running unless --restart.
# Usage: teams-debug-launch.sh [--dry-run] [--restart]
# Port: TEAMS_DEBUG_PORT (default 9333). Exit codes: 0 ok, 1 error/refused, 3 port not up after launch.
set -euo pipefail

TEAMS_APPLICATION_NAME="Microsoft Teams"
TEAMS_PROCESS_NAME="MSTeams"
TEAMS_EXECUTABLE_PATH="/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams"
DEFAULT_DEBUG_PORT=9333
PORT_WAIT_ATTEMPTS=30
PORT_WAIT_INTERVAL_SECONDS=0.5
QUIT_WAIT_ATTEMPTS=30
QUIT_WAIT_INTERVAL_SECONDS=0.5

print_usage() {
  echo 'usage: teams-debug-launch.sh [--dry-run] [--restart]' >&2
  echo '  --dry-run  print the exact command and change nothing' >&2
  echo '  --restart  gracefully quit a running Teams first, then relaunch it with the debug port' >&2
}

is_teams_running() {
  pgrep -x "${TEAMS_PROCESS_NAME}" >/dev/null
}

# Prints the listening addresses (one per line) of the TCP port, empty when nothing listens.
list_listeners() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' || true
}

is_port_answering() {
  curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$1/json/version"
}

# A listener is loopback-only when every address starts with 127.0.0.1 or [::1].
verify_loopback_only() {
  local port="$1"
  local listenerAddress
  while IFS= read -r listenerAddress; do
    [[ -z "${listenerAddress}" ]] && continue
    if [[ "${listenerAddress}" != 127.0.0.1:* && "${listenerAddress}" != "[::1]:"* ]]; then
      echo "teams-debug-launch: port ${port} is listening on ${listenerAddress}, not loopback only. Quit Teams now." >&2
      return 1
    fi
  done < <(list_listeners "${port}")
}

quit_teams_gracefully() {
  osascript -e "tell application \"${TEAMS_APPLICATION_NAME}\" to quit"
  local attempt
  for ((attempt = 0; attempt < QUIT_WAIT_ATTEMPTS; attempt++)); do
    is_teams_running || return 0
    sleep "${QUIT_WAIT_INTERVAL_SECONDS}"
  done
  echo "teams-debug-launch: Teams did not quit within the wait; not launching a second instance." >&2
  return 1
}

wait_for_port() {
  local port="$1"
  local attempt
  for ((attempt = 0; attempt < PORT_WAIT_ATTEMPTS; attempt++)); do
    is_port_answering "${port}" && return 0
    sleep "${PORT_WAIT_INTERVAL_SECONDS}"
  done
  return 1
}

dryRun=false
restart=false
for argument in "$@"; do
  case "${argument}" in
    --dry-run) dryRun=true ;;
    --restart) restart=true ;;
    -h|--help) print_usage; exit 0 ;;
    *) print_usage; exit 1 ;;
  esac
done

debugPort="${TEAMS_DEBUG_PORT:-${DEFAULT_DEBUG_PORT}}"
if ! [[ "${debugPort}" =~ ^[0-9]+$ ]] || ((debugPort < 1024 || debugPort > 65535)); then
  echo "teams-debug-launch: TEAMS_DEBUG_PORT must be a number from 1024 to 65535, got '${debugPort}'" >&2
  exit 1
fi

# Verified in the cliui research (theboxstuff/cliui/daemon/docs/teams-debug-port-approach.md): Teams' WebView2 reads this env var
# and opens a loopback-only DevTools port. --remote-allow-origins=* is needed there for non-browser clients.
# #SUGGEST_VERIFY: after a real launch run `lsof -nP -iTCP:PORT -sTCP:LISTEN`; this script also checks the bind address
webviewArguments="--remote-debugging-port=${debugPort} --remote-allow-origins=*"
launchCommand=(env "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=${webviewArguments}" "${TEAMS_EXECUTABLE_PATH}")

if [[ "${dryRun}" == true ]]; then
  if is_teams_running; then
    echo "teams-debug-launch: Teams is running; a real run would refuse without --restart." >&2
  fi
  if [[ "${restart}" == true ]]; then
    printf 'osascript -e %q\n' "tell application \"${TEAMS_APPLICATION_NAME}\" to quit"
  fi
  printf '%q ' "${launchCommand[@]}"
  printf '&\n'
  exit 0
fi

if is_teams_running; then
  if [[ "${restart}" == false ]]; then
    echo "teams-debug-launch: Teams is already running; the debug flag only applies at launch. Re-run with --restart (this quits Teams; do not do it during a meeting)." >&2
    exit 1
  fi
  quit_teams_gracefully
fi

if [[ -n "$(list_listeners "${debugPort}")" ]]; then
  echo "teams-debug-launch: something already listens on port ${debugPort}; choose another TEAMS_DEBUG_PORT." >&2
  exit 1
fi

nohup "${launchCommand[@]}" >/dev/null 2>&1 &
disown

if ! wait_for_port "${debugPort}"; then
  echo "teams-debug-launch: nothing answered on 127.0.0.1:${debugPort}; this Teams build may ignore the flag (see README)." >&2
  exit 3
fi
verify_loopback_only "${debugPort}"
echo "Teams debug port up on 127.0.0.1:${debugPort}"
