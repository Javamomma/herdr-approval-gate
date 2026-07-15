#!/usr/bin/env bash
# approval-gate — human sign-off gate for agent actions, with an audit trail.
#
# A gated task runs in a dedicated herdr pane. After the task finishes, a
# separately configured CHECKER command runs against the task transcript;
# the checker's stdout verdict line ALONE decides pass/block — the task's
# self-assessment is never trusted. Anything other than a clean PASS
# (including a missing or garbled verdict — FAIL CLOSED) blocks the pane
# until a human types `APPROVE <initials>` or `ABORT <initials>`. Every
# terminal outcome appends one attributed line to an append-only audit log.
#
# The gate never auto-executes the guarded action. Approval means
# "cleared for the human to act" — nothing more.
#
# Targets bash 3.2+ (macOS stock bash) — no ${var@Q}, no ${var^^}.
set -euo pipefail

PLUGIN_ID="javamomma.approval-gate"
HERDR="${GATE_HERDR_BIN:-herdr}"

# Absolute path to this script (embedded into the pane-side run script).
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PLUGIN_ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# --- directory resolution ---------------------------------------------------
# Precedence: explicit GATE_* env > herdr plugin env > `herdr plugin
# config-dir` (when the plugin is registered and herdr is reachable) > XDG
# fallback. The pane-side script always receives explicit GATE_CONFIG_DIR /
# GATE_STATE_DIR exports, so both halves of a run agree on one location.
config_dir() {
  if [ -n "${GATE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$GATE_CONFIG_DIR"
  elif [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$HERDR_PLUGIN_CONFIG_DIR"
  else
    local d
    d="$("$HERDR" plugin config-dir "$PLUGIN_ID" 2>/dev/null | head -n1 || true)"
    case "$d" in
      /*) printf '%s\n' "$d" ;;
      *)  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/herdr-approval-gate" ;;
    esac
  fi
}

state_dir() {
  if [ -n "${GATE_STATE_DIR:-}" ]; then
    printf '%s\n' "$GATE_STATE_DIR"
  elif [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
    printf '%s\n' "$HERDR_PLUGIN_STATE_DIR"
  else
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-approval-gate"
  fi
}

# --- config -----------------------------------------------------------------
# $CONFIG_DIR/config is shell-sourceable KEY=value, seeded from
# config.example on first use. GATE_* environment variables take precedence
# over the file (that is also how the tests drive the pure functions).
load_config() {
  local cfg_dir cfg
  cfg_dir="$(config_dir)"
  cfg="$cfg_dir/config"

  if [ ! -f "$cfg" ] && [ -f "$PLUGIN_ROOT/config.example" ]; then
    mkdir -p "$cfg_dir"
    cp "$PLUGIN_ROOT/config.example" "$cfg"
    echo "approval-gate: seeded config at $cfg (edit it, at minimum GATE_CHECKER)" >&2
  fi

  # Snapshot env so it wins over the file.
  local e_checker e_regex e_log e_auto
  e_checker="${GATE_CHECKER-__gate_unset__}"
  e_regex="${GATE_VERDICT_REGEX-__gate_unset__}"
  e_log="${GATE_LOG-__gate_unset__}"
  e_auto="${GATE_AUTO_RELEASE-__gate_unset__}"

  if [ -f "$cfg" ]; then
    # shellcheck disable=SC1090  # user-owned config, sourced by design
    . "$cfg"
  fi

  [ "$e_checker" != "__gate_unset__" ] && GATE_CHECKER="$e_checker"
  [ "$e_regex" != "__gate_unset__" ] && GATE_VERDICT_REGEX="$e_regex"
  [ "$e_log" != "__gate_unset__" ] && GATE_LOG="$e_log"
  [ "$e_auto" != "__gate_unset__" ] && GATE_AUTO_RELEASE="$e_auto"

  GATE_CHECKER="${GATE_CHECKER:-}"
  GATE_VERDICT_REGEX="${GATE_VERDICT_REGEX:-^GATE: (PASS|BLOCK|CAUTION)$}"
  GATE_LOG="${GATE_LOG:-$(state_dir)/audit-log.md}"
  GATE_AUTO_RELEASE="${GATE_AUTO_RELEASE:-true}"
}

# --- pure helpers (no herdr required; exposed as subcommands for tests) -----

# classify: reads the CHECKER's stdout on stdin; prints the verdict token.
# The first line matching GATE_VERDICT_REGEX is the verdict line; the
# regex's single capture group extracts the token. No matching line, an
# empty extraction, or a regex without a capture group all print UNREADABLE
# — the fail-closed band. Only the literal token PASS can ever release.
classify_verdict() {
  local line verdict d
  line="$(grep -m1 -E "$GATE_VERDICT_REGEX" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    echo "UNREADABLE"
    return 0
  fi
  # \001 as the sed delimiter: the regex itself may contain / | @ etc.
  # A regex with no capture group makes sed error on \1 → empty → fail closed.
  d="$(printf '\001')"
  verdict="$(printf '%s\n' "$line" | sed -nE "s${d}${GATE_VERDICT_REGEX}${d}\\1${d}p" 2>/dev/null | head -n1 || true)"
  if [ -z "$verdict" ]; then
    echo "UNREADABLE"
  else
    printf '%s\n' "$verdict"
  fi
}

# validate_initials: 2-4 ASCII letters, nothing else. Exit 0/1.
validate_initials() {
  printf '%s' "${1:-}" | grep -Eq '^[A-Za-z]{2,4}$'
}

# format_audit_line EVENT ACTOR DOC KIND BAND — one append-only line.
# Format: - <EVENT> by <initials> at <ISO> · <doc> · <kind>-check: <BAND>
# ACTOR "-" means "no human actor" (auto-release / no-decision).
format_audit_line() {
  local event="$1" actor="$2" doc="$3" kind="$4" band="$5"
  local ts
  ts="${GATE_AUDIT_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  if [ "$actor" = "-" ]; then
    printf -- '- %s at %s · %s · %s-check: %s\n' "$event" "$ts" "$doc" "$kind" "$band"
  else
    printf -- '- %s by %s at %s · %s · %s-check: %s\n' "$event" "$actor" "$ts" "$doc" "$kind" "$band"
  fi
}

log_audit() {
  mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true
  format_audit_line "$@" >> "$GATE_LOG"
}

# shquote STR — portable single-quote shell escaping (bash 3.2 has no @Q).
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --- checker invocation ------------------------------------------------------
# run_checker TRANSCRIPT_FILE — runs GATE_CHECKER with the transcript piped
# on stdin AND its path as $1; prints whatever the checker prints. A
# missing checker or a crashing checker yields no verdict line, which the
# classifier fails closed on. The checker is deliberately a separate,
# independently configured command: the gate never asks the task to grade
# itself.
run_checker() {
  local transcript="$1"
  if [ -z "$GATE_CHECKER" ]; then
    echo "approval-gate: GATE_CHECKER is not configured — failing closed" >&2
    return 0
  fi
  if [ ! -r "$transcript" ]; then
    echo "approval-gate: transcript not readable: $transcript — failing closed" >&2
    return 0
  fi
  # $0 is a label; the transcript path is $1 inside the checker command.
  # shellcheck disable=SC2094  # the transcript is read twice, never written
  sh -c "$GATE_CHECKER" approval-gate-checker "$transcript" < "$transcript" \
    || echo "approval-gate: checker exited non-zero — verdict, if any, still governs; otherwise fail closed" >&2
}

# --- the blocking / approval primitive ---------------------------------------
# SAFETY INVARIANT: the gate releases only on (a) band PASS with
# GATE_AUTO_RELEASE=true, or (b) a human typing `APPROVE <initials>` with
# valid initials. Bare APPROVE/ABORT is rejected and re-prompted. The block
# is a plain `read` loop — durable, zero-cost, never times out, never
# defaults. stdin closing without a decision is logged and treated as abort.
await_approval() {
  local band="" doc="" kind="gate"
  while [ $# -gt 0 ]; do
    case "$1" in
      --band) band="$2"; shift 2 ;;
      --doc)  doc="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  band="${band:-UNREADABLE}"
  doc="${doc:-n/a}"

  if [ "$band" = "PASS" ] && [ "$GATE_AUTO_RELEASE" = "true" ]; then
    echo "APPROVAL-GATE: AUTO-RELEASED (verdict=PASS)"
    log_audit "AUTO-RELEASED" "-" "$doc" "$kind" "$band"
    return 0
  fi

  local why
  if [ "$band" = "PASS" ]; then
    why="checker passed, but GATE_AUTO_RELEASE=false — human sign-off required"
  elif [ "$band" = "UNREADABLE" ]; then
    why="no readable verdict from the checker — failing closed"
  else
    why="checker verdict: $band"
  fi

  # Best-effort notification; never load-bearing for the block itself.
  "$HERDR" notification show "Approval Gate: $band" --body "$why — $doc" --sound request >/dev/null 2>&1 \
    || echo "APPROVAL-GATE: notification unavailable — on-screen prompt still active"

  cat <<EOF

============================================================
  APPROVAL GATE — BLOCKED (verdict: $band)
  $why
  Gated: $doc
  Review the transcript above, then type:
    APPROVE <initials>   to release (e.g. APPROVE AJ)
    ABORT <initials>     to reject
============================================================

EOF

  local ans verb initials extra
  while true; do
    if ! read -r -p "APPROVAL-GATE ($band): APPROVE <initials> or ABORT <initials>? " ans; then
      echo ""
      echo "APPROVAL-GATE: NO DECISION (stdin closed) — treated as abort"
      log_audit "NO-DECISION (stdin closed)" "-" "$doc" "$kind" "$band"
      return 1
    fi
    # shellcheck disable=SC2086  # word-splitting the reply is the point
    set -- $ans
    verb="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
    initials="${2:-}"
    extra="${3:-}"
    case "$verb" in
      APPROVE)
        if [ -n "$extra" ]; then
          echo "APPROVAL-GATE: too many words — type exactly: APPROVE <initials>"
        elif validate_initials "$initials"; then
          echo "APPROVAL-GATE: RELEASED — cleared for you to act (nothing was auto-executed)"
          log_audit "APPROVED" "$initials" "$doc" "$kind" "$band"
          return 0
        else
          echo "APPROVAL-GATE: approve requires 2-4 letter initials — bare APPROVE is rejected"
        fi
        ;;
      ABORT)
        if [ -n "$extra" ]; then
          echo "APPROVAL-GATE: too many words — type exactly: ABORT <initials>"
        elif validate_initials "$initials"; then
          echo "APPROVAL-GATE: ABORTED"
          log_audit "ABORTED" "$initials" "$doc" "$kind" "$band"
          return 1
        else
          echo "APPROVAL-GATE: abort requires 2-4 letter initials — bare ABORT is rejected"
        fi
        ;;
      *)
        echo "APPROVAL-GATE: unrecognized input '$ans' — type APPROVE <initials> or ABORT <initials>"
        ;;
    esac
  done
}

# --- herdr plumbing ----------------------------------------------------------
require_herdr() {
  if [ -z "${HERDR_ENV:-}" ]; then
    echo "approval-gate: run inside a herdr session (HERDR_ENV unset)" >&2
    exit 1
  fi
  if ! "$HERDR" status server >/dev/null 2>&1; then
    echo "approval-gate: herdr server not running" >&2
    exit 1
  fi
}

# json_first_field KEY — heuristic string-field extraction from herdr's
# JSON (jq-free by design). Good enough for herdr's flat id/label/status
# fields; not a general JSON parser.
json_first_field() {
  sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

# split_objects — one '{'-delimited segment per line, so fields of the same
# flat object land on one greppable line.
split_objects() {
  tr '{' '\n'
}

sanitize_label() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64
}

# --- run ---------------------------------------------------------------------
compose_run_script() {
  # Everything the pane needs is baked in: dirs, self path, task command,
  # and the RESOLVED gate config. Baking the config in makes each run a
  # snapshot — editing the config file cannot change the semantics of a
  # gate that is already pending, and env-only configuration reaches the
  # pane too.
  local label="$1" task_cmd="$2" doc="$3"
  local qself qcfg qstate qtask qdoc
  qself="$(shquote "$SELF")"
  qcfg="$(shquote "$(config_dir)")"
  qstate="$(shquote "$(state_dir)")"
  qtask="$(shquote "$task_cmd")"
  qdoc="$(shquote "$doc")"
  cat <<EOF
#!/usr/bin/env bash
# approval-gate pane-side run script: ${label}
set -u
export GATE_CONFIG_DIR=${qcfg}
export GATE_STATE_DIR=${qstate}
export GATE_CHECKER=$(shquote "$GATE_CHECKER")
export GATE_VERDICT_REGEX=$(shquote "$GATE_VERDICT_REGEX")
export GATE_LOG=$(shquote "$GATE_LOG")
export GATE_AUTO_RELEASE=$(shquote "$GATE_AUTO_RELEASE")
SELF=${qself}
TRANSCRIPT=${qstate}/transcripts/${label}.log
mkdir -p "\$(dirname "\$TRANSCRIPT")"
echo "APPROVAL-GATE: STARTED ${label}"
printf 'APPROVAL-GATE: TASK %s\n' ${qtask}

# 1. The gated task. Its transcript is captured verbatim for the checker.
bash -c ${qtask} </dev/null 2>&1 | tee "\$TRANSCRIPT"
TASK_EXIT=\${PIPESTATUS[0]}
echo "APPROVAL-GATE: TASK-EXIT=\$TASK_EXIT"

# 2. The independent checker. Its verdict line ALONE decides pass/block —
#    the task is never asked to grade itself.
CHECKER_OUT="\$("\$SELF" check "\$TRANSCRIPT")"
printf '%s\n' "\$CHECKER_OUT"
VERDICT="\$(printf '%s\n' "\$CHECKER_OUT" | "\$SELF" classify)"
echo "APPROVAL-GATE: VERDICT=\$VERDICT"

# 3. The gate. Blocks (zero-cost, indefinitely) unless PASS auto-releases.
"\$SELF" await-approval --band "\$VERDICT" --doc ${qdoc}
RC=\$?
if [ "\$RC" -eq 0 ]; then
  echo "APPROVAL-GATE: DONE released (task-exit=\$TASK_EXIT)"
else
  echo "APPROVAL-GATE: DONE aborted (task-exit=\$TASK_EXIT)"
fi
exit \$RC
EOF
}

do_run() {
  local label="" dry_run=0
  local task_cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --) shift; task_cmd="$*"; break ;;
      -*) echo "approval-gate: unknown flag for run: $1" >&2; exit 64 ;;
      *) task_cmd="$*"; break ;;
    esac
  done
  if [ -z "$task_cmd" ]; then
    echo "approval-gate: run requires a task command: approval-gate run \"<command>\"" >&2
    exit 64
  fi

  load_config
  if [ -z "$GATE_CHECKER" ]; then
    echo "approval-gate: GATE_CHECKER is not configured — set it in $(config_dir)/config before gating anything" >&2
    exit 64
  fi

  if [ -z "$label" ]; then
    label="gate-$(date +%Y%m%d-%H%M%S)-$$"
  fi
  label="$(sanitize_label "$label")"

  local doc
  doc="$label: $(printf '%s' "$task_cmd" | head -c 80 | tr '\n' ' ')"

  local script
  script="$(compose_run_script "$label" "$task_cmd" "$doc")"

  if [ "$dry_run" -eq 1 ]; then
    echo "PLAN label=$label"
    echo "PLAN checker=$GATE_CHECKER"
    echo "PLAN verdict-regex=$GATE_VERDICT_REGEX"
    echo "PLAN auto-release=$GATE_AUTO_RELEASE"
    echo "PLAN audit-log=$GATE_LOG"
    echo "--- pane-side run script (would be written and run in a new pane) ---"
    printf '%s\n' "$script"
    return 0
  fi

  require_herdr
  echo "approval-gate: opening 1 gated pane for: $task_cmd"

  local run_file
  run_file="$(state_dir)/runs/$label.sh"
  mkdir -p "$(dirname "$run_file")"
  printf '%s\n' "$script" > "$run_file"
  chmod +x "$run_file"

  local pane
  pane="$("$HERDR" workspace create --label "Approval Gate: $label" --no-focus | json_first_field pane_id)"
  if [ -z "$pane" ]; then
    echo "approval-gate: could not create a workspace/pane (no pane_id in response)" >&2
    exit 1
  fi
  "$HERDR" pane rename "$pane" "gate:$label" >/dev/null 2>&1 || true
  "$HERDR" pane run "$pane" "exec bash $(shquote "$run_file")"
  "$HERDR" wait output "$pane" --match "APPROVAL-GATE: STARTED" --timeout 15000 >/dev/null 2>&1 \
    || echo "approval-gate: pane started but did not confirm within 15s (it may still be running)" >&2

  echo "approval-gate: pane $pane opened (workspace 'Approval Gate: $label')."
  echo "approval-gate: it will block and notify unless the checker prints a clean PASS."
  echo "approval-gate: check later with: approval-gate status | approve $pane <initials> | abort $pane <initials>"
}

# --- approve / abort / status / nudge ----------------------------------------
send_token() {
  # Sends the SAME audited token a human would type at the pane prompt.
  # Initials are validated here too — the remote path is not a bypass.
  local pane="$1" verb="$2" initials="$3" lverb
  lverb="$(printf '%s' "$verb" | tr '[:upper:]' '[:lower:]')"
  if ! validate_initials "$initials"; then
    echo "approval-gate: $lverb requires 2-4 letter initials (bare $verb is rejected): approval-gate $lverb <pane-id> <initials>" >&2
    exit 64
  fi
  require_herdr
  "$HERDR" pane send-text "$pane" "$verb $initials" >/dev/null 2>&1 || true
  "$HERDR" pane send-keys "$pane" Enter >/dev/null 2>&1 || true
  echo "approval-gate: sent '$verb $initials' to $pane"
}

gate_workspaces() {
  "$HERDR" workspace list 2>/dev/null | split_objects \
    | grep '"label":"Approval Gate:' \
    | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p'
}

do_status() {
  require_herdr
  local wss
  wss="$(gate_workspaces || true)"
  if [ -z "$wss" ]; then
    echo "approval-gate: no pending approval gates"
    return 0
  fi
  local ws line pane label astatus
  printf '%-10s %-28s %-10s %s\n' "PANE" "LABEL" "STATUS" "WORKSPACE"
  while IFS= read -r ws; do
    [ -z "$ws" ] && continue
    "$HERDR" pane list --workspace "$ws" 2>/dev/null | split_objects | grep '"pane_id"' \
      | while IFS= read -r line; do
          pane="$(printf '%s\n' "$line" | json_first_field pane_id)"
          label="$(printf '%s\n' "$line" | json_first_field label)"
          astatus="$(printf '%s\n' "$line" | json_first_field agent_status)"
          printf '%-10s %-28s %-10s %s\n' "$pane" "${label:--}" "${astatus:-unknown}" "$ws"
        done || true
  done <<EOF
$wss
EOF
}

do_nudge() {
  # Backing script for the "approve-prompt" convenience action: point the
  # human at any pending gates. Never approves anything by itself.
  require_herdr
  local n
  n="$(gate_workspaces | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    "$HERDR" notification show "Approval Gate" --body "No pending approval gates." >/dev/null 2>&1 || true
    echo "approval-gate: no pending approval gates"
    return 0
  fi
  "$HERDR" notification show "Approval Gate: $n pending" \
    --body "Attach to the gate pane and type APPROVE <initials>, or run: approval-gate approve <pane> <initials>" \
    --sound request >/dev/null 2>&1 || true
  do_status
}

usage() {
  cat <<'EOF'
approval-gate — human sign-off gate for agent actions, with an audit trail.

Usage:
  approval-gate run [--label <name>] [--dry-run] "<task command>"
      Run the task in a dedicated herdr pane, run the configured GATE_CHECKER
      on its transcript, and gate on the checker's verdict line. Non-PASS
      (or no readable verdict — fail closed) blocks the pane until a human
      types APPROVE <initials> or ABORT <initials>. Fire-and-forget: returns
      immediately after spawning the pane.
  approval-gate approve <pane-id> <initials>
  approval-gate abort <pane-id> <initials>
      Send the same audited token a human would type at the pane prompt.
      Initials (2-4 letters) are required; bare APPROVE/ABORT is rejected.
  approval-gate status
      List pending gate panes and their agent status.
  approval-gate nudge
      Notify about pending gates (backs the plugin's approve-prompt action).

Internal / test entry points (no herdr required):
  approval-gate classify            verdict token from checker output (stdin)
  approval-gate check <transcript>  run GATE_CHECKER against a transcript
  approval-gate validate-initials <str>
  approval-gate await-approval --band <verdict> --doc <label>
  approval-gate audit-line <event> <actor> <doc> <kind> <band>

Config: $CONFIG_DIR/config (shell-sourceable KEY=value; seeded from
config.example on first run). Keys: GATE_CHECKER, GATE_VERDICT_REGEX,
GATE_LOG, GATE_AUTO_RELEASE. GATE_* environment variables override the file.

The gate never auto-executes the guarded action — approval means "cleared
for the human to act".
EOF
}

# --- dispatch ----------------------------------------------------------------
case "${1:-}" in
  run)
    shift
    do_run "$@"
    ;;
  approve)
    [ -n "${2:-}" ] || { echo "approval-gate: approve requires a pane id" >&2; exit 64; }
    send_token "$2" "APPROVE" "${3:-}"
    ;;
  abort)
    [ -n "${2:-}" ] || { echo "approval-gate: abort requires a pane id" >&2; exit 64; }
    send_token "$2" "ABORT" "${3:-}"
    ;;
  status)
    do_status
    ;;
  nudge)
    do_nudge
    ;;
  classify)
    load_config
    classify_verdict
    ;;
  check)
    [ -n "${2:-}" ] || { echo "approval-gate: check requires a transcript path" >&2; exit 64; }
    load_config
    run_checker "$2"
    ;;
  validate-initials)
    validate_initials "${2:-}"
    ;;
  await-approval)
    shift
    load_config
    await_approval "$@"
    ;;
  audit-line)
    shift
    load_config
    format_audit_line "$@"
    ;;
  --help|-h|help|"")
    usage
    ;;
  *)
    echo "approval-gate: unknown subcommand: $1 (see --help)" >&2
    exit 64
    ;;
esac
