#!/usr/bin/env bash
# Lifecycle for the Orca server sandbox. Subcommands:
#   up       create (or reuse) the sandbox, start serve + the local forward
#   link     print a desktop pairing link (asks the running serve via orca pair)
#   stop     stop the sandbox (workspace preserved) and the forward
#   start    restart a stopped sandbox and the forward
#   destroy  delete the sandbox and the forward (pairing state is lost)
#
# Required for `up`: ORCA_SERVER_IMAGE=<registry ref you pushed>
# Optional:
#   ORCA_SERVER_SANDBOX     sandbox name        (default: orca-server)
#   ORCA_SERVER_PORT         serve port in the sandbox (default: 6768, Orca's
#                           default)
#   ORCA_SERVER_FORWARD_PORT local forward port (default: 6769 — NOT 6768: the
#                           local Orca desktop's own runtime claims 6768)
#   ORCA_SERVER_PROVIDERS    space-separated provider names to attach
#   ORCA_SERVER_POLICY       path to a custom sandbox policy YAML
set -euo pipefail

OPENSHELL="${OPENSHELL_BIN:-$HOME/.local/bin/openshell}"
SANDBOX_NAME="${ORCA_SERVER_SANDBOX:-orca-server}"
PORT="${ORCA_SERVER_PORT:-6768}"
FORWARD_PORT="${ORCA_SERVER_FORWARD_PORT:-6769}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/orca-poc"
FORWARD_PID="${STATE_DIR}/forward.pid"
FORWARD_LOG="${STATE_DIR}/forward.log"

serve_cmd=(orca serve --port "${PORT}" --pairing-address localhost)

create_args=(--name "${SANDBOX_NAME}" --detach --restart-policy always)
for provider in ${ORCA_SERVER_PROVIDERS:-}; do
  create_args+=(--provider "${provider}")
done
if [ -n "${ORCA_SERVER_POLICY:-}" ]; then
  create_args+=(--policy "${ORCA_SERVER_POLICY}")
fi

start_forward() {
  mkdir -p "${STATE_DIR}"
  if [ -f "${FORWARD_PID}" ] && kill -0 "$(cat "${FORWARD_PID}")" 2>/dev/null; then
    echo ">> forward already running (pid $(cat "${FORWARD_PID}"))"
    return
  fi
  # No background flag on `forward service`; nohup a supervisor and keep its pid.
  # Local port differs from the sandbox serve port: the local Orca desktop's
  # own runtime listens on 6768, so the forward must not compete for it.
  # The supervisor restarts the forward when it exits: `forward service` does
  # not renew its gateway token while running, and the OIDC access token is
  # short-lived (~5 min, hypershell Keycloak), so an unattended forward
  # eventually dies with "invalid token: ExpiredSignature". Each restart
  # re-authenticates with the stored refresh token. (When the refresh token
  # itself expires, re-login: openshell gateway login.)
  nohup bash -c '
    child=0
    shutdown() { [ "${child}" -gt 0 ] && kill "${child}" 2>/dev/null; exit 0; }
    trap shutdown TERM INT
    while true; do
      "$1" forward service --target-port "$2" --local "$3" "$4" &
      child=$!
      wait "${child}"; rc=$?
      echo "[$(date +%FT%T)] forward exited (rc=${rc}); restarting in 5s" >&2
      sleep 5
    done
  ' _ "${OPENSHELL}" "${PORT}" "${FORWARD_PORT}" "${SANDBOX_NAME}" \
    >"${FORWARD_LOG}" 2>&1 &
  echo $! >"${FORWARD_PID}"
  echo ">> forward supervised: localhost:${FORWARD_PORT} -> sandbox loopback:${PORT} (pid $(cat "${FORWARD_PID}"), log ${FORWARD_LOG})"
}

stop_forward() {
  if [ -f "${FORWARD_PID}" ]; then
    pid="$(cat "${FORWARD_PID}")"
    if kill -0 "${pid}" 2>/dev/null; then
      # TERM the supervisor; its trap kills the child forward. Wait for the
      # local port to be released before returning.
      kill "${pid}" && echo ">> forward stopped (pid ${pid})"
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        ss -tln 2>/dev/null | grep -q "127.0.0.1:${FORWARD_PORT}" || break
        sleep 0.5
      done
    fi
    rm -f "${FORWARD_PID}"
  fi
}

sandbox_phase() {
  "${OPENSHELL}" sandbox get "${SANDBOX_NAME}" 2>/dev/null | awk '/Phase:/ {print $2}'
}

cmd_up() {
  local image="${ORCA_SERVER_IMAGE:?Set ORCA_SERVER_IMAGE to the registry ref you pushed (see build.sh)}"
  local phase
  phase="$(sandbox_phase || true)"
  if [ "${phase}" = "Ready" ]; then
    echo ">> sandbox ${SANDBOX_NAME} already Ready; leaving it as is"
  elif [ -n "${phase}" ]; then
    echo ">> sandbox exists (${phase}); starting it"
    "${OPENSHELL}" sandbox start "${SANDBOX_NAME}"
  else
    echo ">> creating sandbox ${SANDBOX_NAME} from ${image}"
    "${OPENSHELL}" sandbox create "${create_args[@]}" --from "${image}" -- "${serve_cmd[@]}"
  fi
  start_forward
  cat <<EOF

>> next: print the desktop pairing link
     ./server.sh link
   then in Orca desktop: Settings -> Remote Orca Servers -> Add Server ->
   paste the access link, and enable the SSH-tunnel option in the dialog
   (the link advertises localhost, reached through the forward).
   The desktop connects via localhost:${FORWARD_PORT}.
EOF
}

cmd_link() {
  # Detached serve output isn't captured by `openshell logs`, so ask the
  # running serve for a pairing link instead. Advertise localhost:FORWARD_PORT:
  # the default advertises the sandbox's internal IP, unreachable from the
  # desktop, and 6768 would collide with the local Orca desktop's runtime.
  # The forward can die (e.g. gateway token expiry shows up as
  # "invalid token: ExpiredSignature" in forward.log), so bring it up first.
  start_forward
  if "${OPENSHELL}" sandbox exec "${SANDBOX_NAME}" -- \
      /sandbox/.config/orca/cli/bin/orca pair \
      --address "localhost:${FORWARD_PORT}" --rotate; then
    return 0
  fi
  echo ">> could not get a pairing link (is serve running in ${SANDBOX_NAME}?)" >&2
  echo ">> recent sandbox logs:" >&2
  "${OPENSHELL}" logs -n 100 "${SANDBOX_NAME}"
  return 1
}

cmd_stop() {
  stop_forward
  "${OPENSHELL}" sandbox stop "${SANDBOX_NAME}"
  echo ">> stopped (workspace preserved; restart with ./server.sh start)"
}

cmd_start() {
  "${OPENSHELL}" sandbox start "${SANDBOX_NAME}"
  start_forward
}

cmd_destroy() {
  stop_forward
  "${OPENSHELL}" sandbox delete "${SANDBOX_NAME}"
  echo ">> deleted. Pairing identity lived in /sandbox and is gone; re-pair after recreating."
}

case "${1:-}" in
  up) cmd_up ;;
  link) cmd_link ;;
  stop) cmd_stop ;;
  start) cmd_start ;;
  destroy) cmd_destroy ;;
  *) echo "usage: $0 {up|link|stop|start|destroy}" >&2; exit 64 ;;
esac
