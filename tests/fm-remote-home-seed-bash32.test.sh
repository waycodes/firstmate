#!/usr/bin/env bash
# tests/fm-remote-home-seed-bash32.test.sh - stock-macOS-Bash regression for
# bin/fm-remote-home-seed.sh's projectless route.
#
# Under `set -u`, Bash 3.2.57 (the stock macOS shell) treats a bare "${arr[@]}"
# on a declared-but-empty array as an unbound-variable error, while Bash 4.4+
# makes it a harmless no-op. `--no-projects` legitimately empties the project
# array, so the projectless seed aborted at the project loop on a Mac and no
# Linux lane could see it.
#
# This proves exactly one thing: under a Bash 3.x interpreter, `--no-projects`
# gets past that loop. The readiness gate runs immediately after the loop, so
# reaching its refusal is the proof. The seed's provisioning, rollback, and
# origin-validation behavior belongs to tests/fm-remote-secondmate-lifecycle-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The probe runs before any other output because an absent interpreter has to be
# this run's FIRST line: bin/fm-test-run.sh reads only the first non-empty line
# of the merged stream to classify a gate skip, and a skip announced later would
# be tallied as an ordinary pass on a primary that cannot observe the defect.
BASH3=
BASH3_VERSION=
for candidate in ${FM_TEST_BASH3:+"$FM_TEST_BASH3"} /bin/bash /usr/local/bin/bash-3.2 /opt/homebrew/bin/bash-3.2; do
  [ -x "$candidate" ] || continue
  # Single-quoted on purpose: the CANDIDATE shell must expand BASH_VERSION, not
  # this one, which is the whole point of asking it its version.
  # shellcheck disable=SC2016
  version=$("$candidate" -c 'printf %s "$BASH_VERSION"' 2>/dev/null) || continue
  case "$version" in
    3.*) BASH3=$candidate; BASH3_VERSION=$version; break ;;
  esac
done
[ -n "$BASH3" ] || { echo "skip: bash 3.x not found (set FM_TEST_BASH3 to a Bash 3.2 interpreter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-seed-bash32)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"

# A fixed readiness refusal, so the run stops at the gate that follows the loop
# without touching the runner's own account. tests/fm-remote-doctor.test.sh owns
# the real doctor's behavior.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
exit 1
SH
chmod +x "$FAKEBIN/fake-ssh"

OUT="$TMP_ROOT/seed.out"
FM_HOME="$PARENT" \
FM_SECONDMATE_CHARTER='Projectless portability charter.' \
FM_SECONDMATE_SCOPE='portability probe' \
FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  "$BASH3" "$ROOT/bin/fm-remote-home-seed.sh" \
  probe remote-mac "$TMP_ROOT/probe-root" "$TMP_ROOT/probe-home" --no-projects \
  > "$OUT" 2>&1 || true

assert_no_grep 'unbound variable' "$OUT" \
  "bash $BASH3_VERSION: --no-projects aborted on an unbound variable at the project loop"$'\n'"$(cat "$OUT")"
assert_grep 'remote runtime preflight failed' "$OUT" \
  "bash $BASH3_VERSION: --no-projects never reached the readiness gate that follows the project loop"$'\n'"$(cat "$OUT")"
pass "bash $BASH3_VERSION: --no-projects gets past the project loop"
