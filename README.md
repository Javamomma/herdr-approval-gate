# herdr-approval-gate

A **human sign-off gate for agent actions, with an audit trail** — as a
[herdr](https://herdr.dev) plugin.

Agents are good at drafting outward-facing actions (emails, PRs, deploys,
filings, posts) and bad at knowing when those actions need a human. This
plugin gives any task a durable, attachable checkpoint: the task runs in its
own herdr pane, an **independent checker** command renders a verdict on the
task's transcript, and anything short of a clean pass **blocks the pane** —
badge lit, notification fired — until a human attaches and types
`APPROVE <initials>`. Every terminal outcome is one attributed line in an
append-only audit log.

The pane is the point: a headless subagent's "please confirm" moment is
invisible until you happen to read the transcript. A blocked herdr pane sits
there — visible in the sidebar, notifying, reachable from a phone SSH
session — for as long as the human review takes.

## Security model

These invariants are the product; everything else is plumbing.

1. **The gate never trusts the task's self-assessment.** After the task
   finishes, a *separately configured* checker command (`GATE_CHECKER`) runs
   against the task's captured transcript. Only the checker's stdout verdict
   line decides pass/block. A task that prints "all clear, ship it" changes
   nothing.
2. **Fail closed.** No verdict line, a garbled verdict, an empty checker
   output, a crashed checker, a misconfigured regex — all classify as
   `UNREADABLE` and block. There is no code path from "something went wrong"
   to "released".
3. **Release requires typed, attributed initials.** `APPROVE` alone is
   rejected and re-prompted; so is `ABORT`. The accepted form is
   `APPROVE <2-4 letters>` / `ABORT <2-4 letters>`. The remote convenience
   command (`approval-gate approve <pane> <initials>`) sends the *same*
   audited token and enforces the same validation — it is not a bypass.
4. **Append-only audit trail.** Every terminal outcome — auto-release,
   approve, abort, or stdin closing with no decision — appends exactly one
   attributed line to `GATE_LOG`.
5. **The gate never auto-executes the guarded action.** Approval means
   "cleared for the human to act". Nothing is sent, merged, deployed, or
   transmitted by this plugin — ever.
6. **Blocking costs nothing.** The block is a plain shell `read` loop in the
   pane: zero tokens, zero polling, no timeout, no default answer.

Known limitation (stated, not solved): approver identity is "whoever can
type into your herdr session". The initials are an audit attribution, not
authentication.

## Quickstart

```sh
# 1. Get the plugin (any local checkout works)
git clone <this-repo> ~/projects/herdr-approval-gate

# 2. Register it with herdr
herdr plugin link ~/projects/herdr-approval-gate

# 3. Configure the checker (config is seeded on first run)
"$(herdr plugin config-dir ajavaherian.approval-gate)"  # then edit config
#   GATE_CHECKER='./my-policy-check.sh "$1"'

# 4. Gate something (from any shell inside your herdr session)
~/projects/herdr-approval-gate/bin/approval-gate.sh run "make release-notes"

# 5. Later: see what's pending, release or reject
~/projects/herdr-approval-gate/bin/approval-gate.sh status
~/projects/herdr-approval-gate/bin/approval-gate.sh approve w3:p1 AJ
```

Tip: put `bin/` on your `PATH` or alias `approval-gate` — `run` is CLI-first
by design (it takes an arbitrary task command, which the action palette
can't supply). The manifest's actions cover the palette-friendly parts:
**status** and **approve-prompt** (a "where do I go to approve?" nudge).

### What a run looks like

```
$ approval-gate run --label foth-email "claude -p '/draft-email foth-followup'"
approval-gate: opening 1 gated pane for: claude -p '/draft-email foth-followup'
approval-gate: pane w3:p1 opened (workspace 'Approval Gate: foth-email').
approval-gate: it will block and notify unless the checker prints a clean PASS.
```

Inside the pane: the task runs and its transcript is captured; then the
checker runs; then either

```
APPROVAL-GATE: VERDICT=PASS
APPROVAL-GATE: AUTO-RELEASED (verdict=PASS)
```

or the block:

```
============================================================
  APPROVAL GATE — BLOCKED (verdict: BLOCK)
  checker verdict: BLOCK
  Gated: foth-email: claude -p '/draft-email foth-followup'
  Review the transcript above, then type:
    APPROVE <initials>   to release (e.g. APPROVE AJ)
    ABORT <initials>     to reject
============================================================

APPROVAL-GATE (BLOCK): APPROVE <initials> or ABORT <initials>?
```

## CLI reference

| Command | Behavior |
|---|---|
| `approval-gate run [--label <name>] [--dry-run] "<task command>"` | Spawn a dedicated workspace/pane, run the task, checker-verdict it, gate it. Fire-and-forget: returns as soon as the pane is confirmed started. `--dry-run` prints the plan and the composed pane-side script without touching herdr. |
| `approval-gate approve <pane-id> <initials>` | Send `APPROVE <initials>` to a blocked gate pane (same keystrokes a human would type; initials validated here too). |
| `approval-gate abort <pane-id> <initials>` | Send `ABORT <initials>`. |
| `approval-gate status` | List panes in `Approval Gate: *` workspaces with their agent status. |
| `approval-gate nudge` | Notification pointing at pending gates (backs the `approve-prompt` action). |
| `approval-gate --help` | Full usage, including the internal/test entry points. |

Exit codes: `0` released/ok, `1` aborted or environment failure, `64` usage
or configuration error.

## Configuration

Config lives at `$HERDR_PLUGIN_CONFIG_DIR/config` (a shell-sourceable
`KEY=value` file), seeded from [`config.example`](config.example) on first
run. When invoked outside the plugin environment (the normal CLI case), the
directory resolves in this order: `$GATE_CONFIG_DIR` env →
`$HERDR_PLUGIN_CONFIG_DIR` → `herdr plugin config-dir ajavaherian.approval-gate`
→ `~/.config/herdr-approval-gate`. `GATE_*` environment variables always
override the file.

| Key | Default | Meaning |
|---|---|---|
| `GATE_CHECKER` | *(unset — required)* | The independent verdict command. Receives the task transcript **piped on stdin and as a file path in `$1`** (use whichever is convenient). Must print one line matching `GATE_VERDICT_REGEX`. Run via `sh -c`, so pipelines and `&&` work. |
| `GATE_VERDICT_REGEX` | `^GATE: (PASS\|BLOCK\|CAUTION)$` | ERE applied to checker stdout; the first matching line is the verdict line and the regex's **single capture group** extracts the token. Only the literal token `PASS` can release; every other token blocks. No match / no capture group → `UNREADABLE` → block. |
| `GATE_LOG` | `$HERDR_PLUGIN_STATE_DIR/audit-log.md` | Append-only audit log path. |
| `GATE_AUTO_RELEASE` | `true` | `true`: a clean `PASS` releases with no human step. `false`: even `PASS` waits for typed approval. |

State (transcripts, pane-side run scripts, default audit log) lives under
`$HERDR_PLUGIN_STATE_DIR` (fallback `~/.local/state/herdr-approval-gate`).

### Audit log format

One line per terminal outcome:

```
- APPROVED by AJ at 2026-07-13T18:42:11Z · foth-email: claude -p '/draft-email …' · gate-check: BLOCK
- AUTO-RELEASED at 2026-07-13T19:01:02Z · gate-20260713-190055-4711: make lint-fix · gate-check: PASS
- ABORTED by KK at 2026-07-13T19:20:40Z · deploy-prod: ./deploy.sh prod · gate-check: CAUTION
- NO-DECISION (stdin closed) at 2026-07-13T20:00:00Z · gate-x: … · gate-check: UNREADABLE
```

## Checker examples

The checker is any command that reads a transcript and prints a verdict
line. Some shapes:

```sh
# A policy/lint script that inspects the transcript file
GATE_CHECKER='./policy-lint.sh "$1"'

# Pure-shell denylist: block if the task ever mentioned prod credentials
GATE_CHECKER='if grep -qiE "aws_secret|BEGIN RSA" ; then echo "GATE: BLOCK"; else echo "GATE: PASS"; fi'

# A second, independent LLM pass reviewing the first one's work
GATE_CHECKER='claude -p "Review the transcript on stdin as a release gate.
If anything looks unsafe to send or run, explain briefly.
End with exactly one line: GATE: PASS or GATE: BLOCK"'

# Reuse an existing tool with its own verdict format
GATE_VERDICT_REGEX='^Band: (SAFE|CAUTION|STOP)$'
GATE_CHECKER='my-privilege-scanner --stdin'
# Note: only the literal token PASS releases — with this regex every band
# blocks, i.e. every run requires human sign-off. Often exactly what you want.
```

## Tests

Pure-logic tests run **without a live herdr server** (herdr-dependent parts
are covered via `--dry-run`; the test harness points `GATE_HERDR_BIN` at
`false` so any accidental herdr call fails fast):

```sh
sh tests/run.sh
```

Covered: verdict classification (pass/block/caution/garbled → fail closed),
custom-regex handling, initials validation (bare `APPROVE` rejected, 2–4
alpha accepted), audit-line formatting, auto-release semantics,
`GATE_AUTO_RELEASE=false`, no-decision-on-EOF fail-closed, checker
invocation (stdin and `$1`), dry-run composition, and config seeding.

## Design notes

- The pane-side pipeline (task → checker → gate) is written as a small bash
  script into `$STATE_DIR/runs/` and executed with `bash <file>` in the new
  pane, so it behaves identically regardless of the pane's login shell.
- herdr's `agent_status=blocked` badge and `herdr notification show` are
  best-effort UI on top of the block; the block itself is a literal blocking
  `read` and is correct with or without them.
- JSON from the herdr CLI is parsed with a small sed/grep heuristic (no `jq`
  dependency). It relies on herdr's flat `*_id`/`label`/`agent_status`
  fields; it is not a general JSON parser.
- Generalized from an internal legal-workflow gate (privilege/alignment
  checks on outbound drafts) that ran in production on herdr 0.7.x; the
  domain logic was removed, the invariants kept.

## License

MIT — see [LICENSE](LICENSE).
