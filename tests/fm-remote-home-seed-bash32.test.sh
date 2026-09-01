#!/usr/bin/env bash
# tests/fm-remote-home-seed-bash32.test.sh - stock-macOS-Bash regression coverage
# for bin/fm-remote-home-seed.sh's projectless route.
#
# The defect: the seed runs under `set -eu`, and under `set -u` Bash 3.2.57 (the
# stock macOS shell, which `env bash` still resolves to on a Mac with no newer
# bash on PATH) treats a bare "${arr[@]}" on a declared-but-empty array as an
# unbound-variable error, while Bash 4.4+ makes it a harmless no-op. `--no-projects`
# legitimately leaves the project array empty, so `fm-remote-home-seed.sh ...
# --no-projects` aborted on a macOS primary before it reached the readiness gate,
# while every Linux run was unaffected. The repo supports stock macOS Bash 3.2
# (.github/workflows/ci.yml's macos-stock-bash job), so this is a portability
# defect in the script, not a shell requirement.
#
# The interpreter is the variable under test, so these assertions run the real
# seed twice: once under the ambient bash, and once under a located Bash 3.x
# interpreter. On Linux CI the ambient arm is Bash 5 and cannot observe the
# defect at all, which is exactly why the 3.x arm reports an absent interpreter
# explicitly instead of passing silently over it.
#
# The route is driven through the real script's own CLI with a fake SSH boundary
# whose readiness verdict is a fixed refusal: the readiness gate runs immediately
# AFTER the project loop, so reaching its refusal is the observable proof that the
# loop was crossed. tests/fm-remote-secondmate-lifecycle-e2e.test.sh owns the
# seed's full provisioning, rollback, and origin-validation behavior; this file
# owns only the interpreter axis.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-seed-bash32)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"

# One registered remote-backed project, so the with-projects arm exercises the
# loop body rather than only the empty path.
fm_git_init_commit "$TMP_ROOT/alpha-src"
fm_git_add_origin "$TMP_ROOT/alpha-src" "$TMP_ROOT/alpha.git"
ALPHA_ORIGIN="file://$(cd "$TMP_ROOT/alpha.git" && pwd)"
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-31)\n' > "$PARENT/data/projects.md"

# The readiness gate's verdict is fixed here rather than answered by the real
# doctor, which would inspect the runner's own account.
# tests/fm-remote-doctor.test.sh owns the doctor's real behavior.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf 'check gui-session=human: no Aqua login session exists for this uid\n'
printf 'action: gui-session: log that account in once at the console\n'
printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
exit 1
SH
chmod +x "$FAKEBIN/fake-ssh"

# seed_under <interpreter> <id> <out-file> [seed args...]
# Runs the real seed with that interpreter, records combined output, and echoes
# its exit status. An interpreter abort under `set -u` is reported as exit 0 on
# Bash 3.2 (this script's EXIT trap ends in a command that succeeds, and a trap
# that does not itself exit still resets the reported status there), so the
# status alone can read green on the very failure under test - the assertions
# below check the recorded output as well as the status.
seed_under() {
  local interpreter=$1 id=$2 out=$3 rc=0
  shift 3
  FM_HOME="$PARENT" \
  FM_SECONDMATE_CHARTER="Projectless portability charter for $id." \
  FM_SECONDMATE_SCOPE="portability probe $id" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    "$interpreter" "$ROOT/bin/fm-remote-home-seed.sh" \
    "$id" remote-mac "$TMP_ROOT/$id-root" "$TMP_ROOT/$id-home" "$@" \
    > "$out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# assert_crossed_project_loop <interpreter-label> <out-file> <id> <rc>
# The seed must fail on the fixed readiness refusal - never on an interpreter
# error raised before the gate could run.
assert_crossed_project_loop() {
  local label=$1 out=$2 id=$3 rc=$4
  assert_no_grep 'unbound variable' "$out" \
    "$label: the seed aborted on an unbound variable instead of reaching the readiness gate"$'\n'"$(cat "$out")"
  assert_grep 'remote runtime preflight failed' "$out" \
    "$label: the seed never reached the readiness gate that follows the project loop"$'\n'"$(cat "$out")"
  [ "$rc" -ne 0 ] || fail \
    "$label: the seed reported success against a host the readiness gate refused"$'\n'"$(cat "$out")"
  # Rollback removes the registry outright when the seed created it, so an
  # absent file and a file without this route are both clean results.
  if [ -f "$PARENT/data/secondmates.md" ]; then
    assert_no_grep "- $id " "$PARENT/data/secondmates.md" \
      "$label: the refused route survived the preflight rollback"
  fi
}

# assert_refused_inside_project_loop <interpreter-label> <out-file> <rc>
# The negative control for the loop body. `no registry record` is raised only
# from inside the loop, after the mode and origin checks, so an expansion that
# silently dropped its elements would skip the body entirely, leave the project
# list empty, and land on the readiness refusal instead of this one.
assert_refused_inside_project_loop() {
  local label=$1 out=$2 rc=$3
  assert_no_grep 'unbound variable' "$out" \
    "$label: the seed aborted on an unbound variable instead of entering the project loop"$'\n'"$(cat "$out")"
  assert_grep 'no registry record' "$out" \
    "$label: an unregistered project was never refused from inside the project loop"$'\n'"$(cat "$out")"
  assert_no_grep 'remote runtime preflight failed' "$out" \
    "$label: an unregistered project reached the readiness gate instead of the loop body's refusal"$'\n'"$(cat "$out")"
  [ "$rc" -ne 0 ] || fail \
    "$label: the seed reported success for a project with no registry record"$'\n'"$(cat "$out")"
}

# --- locate a Bash 3.x interpreter ------------------------------------------
# /bin/bash is Bash 3.2.57 on every supported macOS. FM_TEST_BASH3 lets a
# maintainer point this arm at a built 3.2 elsewhere.
#
# The probe runs before any assertion output because an absent interpreter has
# to be the run's first line: bin/fm-test-run.sh's detect_gate_skip classifies a
# script as a gate skip only from its first non-empty line, so a skip announced
# later would be tallied as an ordinary pass on a primary that cannot observe the
# defect at all. The ambient arm below still runs after the skip line - it exits
# non-zero on failure, which the runner scores independently of the skip - so no
# coverage is traded for the honest accounting.
BASH3=
for candidate in ${FM_TEST_BASH3:+"$FM_TEST_BASH3"} /bin/bash /usr/local/bin/bash-3.2 /opt/homebrew/bin/bash-3.2; do
  [ -x "$candidate" ] || continue
  case "$("$candidate" -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in
    3.*) BASH3=$candidate; break ;;
  esac
done

if [ -z "$BASH3" ]; then
  echo "skip: bash 3.x not found (set FM_TEST_BASH3 to a Bash 3.2 interpreter)"
fi

# --- ambient bash -----------------------------------------------------------
AMBIENT=$(command -v bash) || fail "no bash on PATH"

RC=$(seed_under "$AMBIENT" ambient-none "$TMP_ROOT/ambient-none.out" --no-projects)
assert_crossed_project_loop "ambient bash ($BASH_VERSION)" "$TMP_ROOT/ambient-none.out" ambient-none "$RC"
pass "ambient bash: --no-projects crosses the project loop and stops at the readiness gate"

RC=$(seed_under "$AMBIENT" ambient-alpha "$TMP_ROOT/ambient-alpha.out" "alpha=$ALPHA_ORIGIN")
assert_crossed_project_loop "ambient bash ($BASH_VERSION)" "$TMP_ROOT/ambient-alpha.out" ambient-alpha "$RC"
assert_no_grep 'no registry record' "$TMP_ROOT/ambient-alpha.out" \
  "ambient bash: the guarded expansion stopped the loop body from resolving its project"
pass "ambient bash: a named project still resolves through the loop body unchanged"

RC=$(seed_under "$AMBIENT" ambient-beta "$TMP_ROOT/ambient-beta.out" "beta=$ALPHA_ORIGIN")
assert_refused_inside_project_loop "ambient bash ($BASH_VERSION)" "$TMP_ROOT/ambient-beta.out" "$RC"
pass "ambient bash: an unregistered project is still refused from inside the loop body"

# --- located Bash 3.x -------------------------------------------------------
# This arm is the only one that can observe the defect, so a primary without a
# 3.x interpreter leaves the run classified as a gate skip by the line already
# printed above rather than reporting the ambient arm as a full pass.
[ -n "$BASH3" ] || exit 0

BASH3_VERSION=$("$BASH3" -c 'printf %s "$BASH_VERSION"')

RC=$(seed_under "$BASH3" bash3-none "$TMP_ROOT/bash3-none.out" --no-projects)
assert_crossed_project_loop "bash $BASH3_VERSION" "$TMP_ROOT/bash3-none.out" bash3-none "$RC"
pass "bash $BASH3_VERSION: --no-projects crosses the project loop and stops at the readiness gate"

RC=$(seed_under "$BASH3" bash3-alpha "$TMP_ROOT/bash3-alpha.out" "alpha=$ALPHA_ORIGIN")
assert_crossed_project_loop "bash $BASH3_VERSION" "$TMP_ROOT/bash3-alpha.out" bash3-alpha "$RC"
assert_no_grep 'no registry record' "$TMP_ROOT/bash3-alpha.out" \
  "bash $BASH3_VERSION: the guarded expansion stopped the loop body from resolving its project"
pass "bash $BASH3_VERSION: a named project still resolves through the loop body unchanged"

RC=$(seed_under "$BASH3" bash3-beta "$TMP_ROOT/bash3-beta.out" "beta=$ALPHA_ORIGIN")
assert_refused_inside_project_loop "bash $BASH3_VERSION" "$TMP_ROOT/bash3-beta.out" "$RC"
pass "bash $BASH3_VERSION: an unregistered project is still refused from inside the loop body"

echo "ALL TESTS PASSED"
