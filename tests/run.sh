#!/bin/sh
# herdr-approval-gate test harness — pure-logic tests, NO live herdr server.
# Everything herdr-dependent is exercised only via --dry-run; the pure
# functions (classify, validate-initials, await-approval, check, audit-line)
# are driven as subprocesses with canned stdin.
#
# Run: sh tests/run.sh

set -u
cd "$(dirname "$0")/.." || exit 1
GATE="bin/approval-gate.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  pass: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want [$2], got [$1])"; fi; }
assert_rc() { if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3 (want rc=$2, got rc=$1)"; fi; }
assert_grep() { if printf '%s\n' "$1" | grep -Eq "$2"; then ok "$3"; else bad "$3 (no match for /$2/ in: $1)"; fi; }

# Isolated config/state so tests never touch a real install; GATE_HERDR_BIN
# points at `false` so any accidental herdr call fails fast and harmlessly.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GATE_CONFIG_DIR="$T/config"
export GATE_STATE_DIR="$T/state"
export GATE_HERDR_BIN="false"
export GATE_LOG="$T/state/audit-log.md"

echo "herdr-approval-gate tests"

# ---------------------------------------------------------------- classify
echo "1. verdict classification (default regex)"
assert_eq "$(printf 'noise\nGATE: PASS\n' | bash $GATE classify)" "PASS"  "PASS line -> PASS"
assert_eq "$(printf 'GATE: BLOCK\n'       | bash $GATE classify)" "BLOCK" "BLOCK line -> BLOCK"
assert_eq "$(printf 'GATE: CAUTION\n'     | bash $GATE classify)" "CAUTION" "CAUTION line -> CAUTION"
assert_eq "$(printf 'blah\nGATE: BLOCK\nGATE: PASS\n' | bash $GATE classify)" "BLOCK" "first matching line wins"

echo "2. fail closed on missing/garbled verdict"
assert_eq "$(printf '' | bash $GATE classify)" "UNREADABLE" "empty checker output -> UNREADABLE"
assert_eq "$(printf 'the task went great, ship it\n' | bash $GATE classify)" "UNREADABLE" "no verdict line -> UNREADABLE"
assert_eq "$(printf 'GATE PASS\ngate: pass\n GATE: PASS\n' | bash $GATE classify)" "UNREADABLE" "garbled verdicts -> UNREADABLE"
assert_eq "$(printf 'GATE: PASS maybe\n' | bash $GATE classify)" "UNREADABLE" "trailing junk on verdict line -> UNREADABLE"

echo "3. custom verdict regex"
assert_eq "$(printf 'VERDICT=OK\n' | GATE_VERDICT_REGEX='^VERDICT=(OK|NO)$' bash $GATE classify)" "OK" "custom regex extracts token"
assert_eq "$(printf 'GATE: PASS\n' | GATE_VERDICT_REGEX='^GATE: PASS$' bash $GATE classify)" "UNREADABLE" "regex without capture group -> fail closed"
assert_eq "$(printf 'ok/PASS|x\n' | GATE_VERDICT_REGEX='^ok/(PASS)\|x$' bash $GATE classify)" "PASS" "regex containing / and | still works"

# ------------------------------------------------------- validate-initials
echo "4. initials validation"
bash $GATE validate-initials AJ;    assert_rc $? 0 "AJ accepted"
bash $GATE validate-initials abcd;  assert_rc $? 0 "abcd (4 alpha) accepted"
bash $GATE validate-initials A;     assert_rc $? 1 "single letter rejected"
bash $GATE validate-initials ABCDE; assert_rc $? 1 "5 letters rejected"
bash $GATE validate-initials A1;    assert_rc $? 1 "digit rejected"
bash $GATE validate-initials "";    assert_rc $? 1 "empty rejected"

# ------------------------------------------------------------ audit lines
echo "5. audit-line formatting"
LINE="$(GATE_AUDIT_TS=2026-07-13T12:00:00Z bash $GATE audit-line APPROVED AJ "gate-x: deploy" gate BLOCK)"
assert_eq "$LINE" "- APPROVED by AJ at 2026-07-13T12:00:00Z · gate-x: deploy · gate-check: BLOCK" "attributed line format"
LINE="$(GATE_AUDIT_TS=2026-07-13T12:00:00Z bash $GATE audit-line AUTO-RELEASED - "gate-y" gate PASS)"
assert_eq "$LINE" "- AUTO-RELEASED at 2026-07-13T12:00:00Z · gate-y · gate-check: PASS" "unattributed (auto) line format"

# --------------------------------------------------------- await-approval
echo "6. await-approval: auto-release on PASS"
OUT="$(bash $GATE await-approval --band PASS --doc t6 </dev/null)"; RC=$?
assert_rc $RC 0 "PASS + GATE_AUTO_RELEASE=true releases"
assert_grep "$OUT" "AUTO-RELEASED" "prints AUTO-RELEASED"
assert_grep "$(cat "$GATE_LOG")" '^- AUTO-RELEASED at [0-9T:Z-]+ · t6 · gate-check: PASS$' "audit log gets AUTO-RELEASED line"

echo "7. await-approval: PASS still blocks when GATE_AUTO_RELEASE=false"
OUT="$(printf 'APPROVE AJ\n' | GATE_AUTO_RELEASE=false bash $GATE await-approval --band PASS --doc t7 2>&1)"; RC=$?
assert_rc $RC 0 "released only after typed approval"
assert_grep "$OUT" "BLOCKED" "blocked despite PASS"
assert_grep "$(cat "$GATE_LOG")" '^- APPROVED by AJ at .* · t7 · gate-check: PASS$' "approval attributed to AJ"

echo "8. await-approval: bare APPROVE rejected, then typed initials accepted"
OUT="$(printf 'APPROVE\nAPPROVE AJ\n' | bash $GATE await-approval --band BLOCK --doc t8 2>&1)"; RC=$?
assert_rc $RC 0 "eventually released"
assert_grep "$OUT" "bare APPROVE is rejected" "bare APPROVE re-prompted"
assert_grep "$(cat "$GATE_LOG")" '^- APPROVED by AJ at .* · t8 · gate-check: BLOCK$' "audit line for t8"

echo "9. await-approval: abort path"
OUT="$(printf 'ABORT\nnonsense\nABORT KK\n' | bash $GATE await-approval --band CAUTION --doc t9 2>&1)"; RC=$?
assert_rc $RC 1 "abort exits 1"
assert_grep "$OUT" "bare ABORT is rejected" "bare ABORT re-prompted"
assert_grep "$OUT" "unrecognized input" "garbage re-prompted"
assert_grep "$(cat "$GATE_LOG")" '^- ABORTED by KK at .* · t9 · gate-check: CAUTION$' "abort attributed to KK"

echo "10. await-approval: invalid initials rejected"
OUT="$(printf 'APPROVE A1B2C3\nAPPROVE X\nABORT AJ\n' | bash $GATE await-approval --band BLOCK --doc t10 2>&1)"; RC=$?
assert_rc $RC 1 "ends aborted"
N="$(printf '%s\n' "$OUT" | grep -c "requires 2-4 letter initials")"
assert_eq "$N" "2" "both bad-initials attempts rejected"

echo "11. await-approval: stdin closed with no decision -> fail closed"
OUT="$(bash $GATE await-approval --band BLOCK --doc t11 </dev/null 2>&1)"; RC=$?
assert_rc $RC 1 "no decision exits 1"
assert_grep "$(cat "$GATE_LOG")" '^- NO-DECISION \(stdin closed\) at .* · t11 · gate-check: BLOCK$' "NO-DECISION logged"

echo "12. await-approval: UNREADABLE band never auto-releases"
OUT="$(printf 'APPROVE AJ\n' | bash $GATE await-approval --band UNREADABLE --doc t12 2>&1)"; RC=$?
assert_rc $RC 0 "released only by human"
assert_grep "$OUT" "failing closed" "explains fail-closed reason"

# ------------------------------------------------------------------ check
echo "13. checker invocation (stdin + \$1 path)"
printf 'task output line\n' > "$T/transcript.log"
OUT="$(GATE_CHECKER='cat >/dev/null; echo "GATE: PASS"' bash $GATE check "$T/transcript.log")"
assert_eq "$OUT" "GATE: PASS" "stdin-consuming checker runs"
OUT="$(GATE_CHECKER='grep -q "task output" "$1" && echo "GATE: BLOCK"' bash $GATE check "$T/transcript.log")"
assert_eq "$OUT" "GATE: BLOCK" "path-as-\$1 checker runs"

echo "14. fail closed end-to-end: no checker configured"
OUT="$(GATE_CHECKER='' bash $GATE check "$T/transcript.log" 2>/dev/null | bash $GATE classify)"
assert_eq "$OUT" "UNREADABLE" "empty GATE_CHECKER -> UNREADABLE"
OUT="$(GATE_CHECKER='exit 3' bash $GATE check "$T/transcript.log" 2>/dev/null | bash $GATE classify)"
assert_eq "$OUT" "UNREADABLE" "checker crash with no output -> UNREADABLE"

# ---------------------------------------------------------------- dry run
echo "15. run --dry-run composes without herdr"
OUT="$(GATE_CHECKER='echo "GATE: PASS"' bash $GATE run --label t15 --dry-run 'echo hello gate' 2>&1)"; RC=$?
assert_rc $RC 0 "dry-run exits 0"
assert_grep "$OUT" "PLAN label=t15" "prints plan"
assert_grep "$OUT" "echo hello gate" "embeds the task command"
assert_grep "$OUT" "await-approval" "script gates via await-approval"
assert_grep "$OUT" "APPROVAL-GATE: STARTED t15" "script announces itself"
assert_grep "$OUT" "export GATE_CHECKER='echo \"GATE: PASS\"'" "resolved config is baked into the pane script"
if [ ! -d "$T/state/runs" ]; then ok "dry-run writes no run script"; else bad "dry-run wrote state"; fi

echo "16. run refuses without a checker or task"
GATE_CHECKER='' bash $GATE run --dry-run 'echo x' >/dev/null 2>&1; assert_rc $? 64 "no GATE_CHECKER -> exit 64"
GATE_CHECKER='echo ok' bash $GATE run --dry-run >/dev/null 2>&1;   assert_rc $? 64 "no task command -> exit 64"

echo "17. approve/abort validate initials before touching herdr"
bash $GATE approve w1:p1 "" >/dev/null 2>&1;    assert_rc $? 64 "bare approve rejected"
bash $GATE abort  w1:p1 A1 >/dev/null 2>&1;     assert_rc $? 64 "bad abort initials rejected"

echo "18. config seeding"
rm -rf "$T/config"
printf '' | bash $GATE classify >/dev/null 2>&1
if [ -f "$T/config/config" ]; then ok "config seeded from config.example"; else bad "config not seeded"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
