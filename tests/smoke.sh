#!/usr/bin/env bash
#
# Smoke tests for entrypoint.sh — PHASE 2 stubbed exercise.
#
# PHASE 1 (root-only socket-GID grant) is skipped implicitly: the tests run as
# a non-root UID, so the `id -u -eq 0` gate is not taken. PHASE 2 is exercised
# by stubbing `curl`, `config.sh`, and `run.sh` and running the entrypoint
# with tailored env combinations.
#
# The pure helpers (parse_runner_scope, scope_endpoint) are also exercised
# directly via the KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 test hook that sources
# the entrypoint and returns before running PHASE 1 or 2.
#
# Ergonomics: each assertion is one line, results are tallied into a
# PASS/FAIL counter, and the script exits non-zero if anything failed. No
# external deps beyond bash + coreutils + jq + curl (already required by
# the entrypoint runtime, so this doesn't add anything to the image).

set -u  # NOT -e: we want to keep going through all tests and report at the end.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${REPO_ROOT}/entrypoint.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

_pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_eq() {
  # $1 expected, $2 actual, $3 label
  if [[ "$1" == "$2" ]]; then
    _pass "$3"
  else
    _fail "$3 — expected [$1], got [$2]"
  fi
}

assert_contains() {
  # $1 haystack, $2 needle, $3 label
  if [[ "$1" == *"$2"* ]]; then
    _pass "$3"
  else
    _fail "$3 — needle [$2] not found"
  fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then
    _pass "$3"
  else
    _fail "$3 — needle [$2] unexpectedly present"
  fi
}

assert_rc() {
  # $1 expected rc, $2 actual rc, $3 label
  if [[ "$1" -eq "$2" ]]; then
    _pass "$3"
  else
    _fail "$3 — expected rc=$1, got rc=$2"
  fi
}

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# Section 1 — pure helpers via KADENZ_CI_ENTRYPOINT_SOURCE_ONLY
# ---------------------------------------------------------------------------
# The helpers run in a subshell (implicit in $()) which is fine here because
# their return value is captured via stdout/rc — no counter mutation involved.

section "parse_runner_scope"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live' \
      && printf '%s|%s|%s\n' \"\${_SCOPE_KIND}\" \"\${_SCOPE_OWNER}\" \"\${_SCOPE_REPO}\"
  "
)"
assert_eq "org|kadenz-live|" "${out}" "org URL parses to (org, kadenz-live, empty repo)"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live/' \
      && printf '%s|%s|%s\n' \"\${_SCOPE_KIND}\" \"\${_SCOPE_OWNER}\" \"\${_SCOPE_REPO}\"
  "
)"
assert_eq "org|kadenz-live|" "${out}" "org URL with trailing slash parses same as without"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live/kadenz' \
      && printf '%s|%s|%s\n' \"\${_SCOPE_KIND}\" \"\${_SCOPE_OWNER}\" \"\${_SCOPE_REPO}\"
  "
)"
assert_eq "repo|kadenz-live|kadenz" "${out}" "repo URL parses to (repo, kadenz-live, kadenz)"

KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
  source '${ENTRYPOINT}'
  parse_runner_scope 'https://github.com/a/b/c'
" >/dev/null 2>&1
assert_rc 1 $? "3-segment URL is rejected"

KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
  source '${ENTRYPOINT}'
  parse_runner_scope 'https://gitlab.com/kadenz-live/kadenz'
" >/dev/null 2>&1
assert_rc 1 $? "non-github.com URL is rejected"

KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
  source '${ENTRYPOINT}'
  parse_runner_scope 'http://github.com/kadenz-live'
" >/dev/null 2>&1
assert_rc 1 $? "plain-http URL is rejected"

section "scope_endpoint"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live'
    scope_endpoint registration
  "
)"
assert_eq \
  "https://api.github.com/orgs/kadenz-live/actions/runners/registration-token" \
  "${out}" "org registration endpoint"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live'
    scope_endpoint remove
  "
)"
assert_eq \
  "https://api.github.com/orgs/kadenz-live/actions/runners/remove-token" \
  "${out}" "org remove endpoint"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live/kadenz'
    scope_endpoint registration
  "
)"
assert_eq \
  "https://api.github.com/repos/kadenz-live/kadenz/actions/runners/registration-token" \
  "${out}" "repo registration endpoint"

out="$(
  KADENZ_CI_ENTRYPOINT_SOURCE_ONLY=1 bash -c "
    source '${ENTRYPOINT}'
    parse_runner_scope 'https://github.com/kadenz-live/kadenz'
    scope_endpoint remove
  "
)"
assert_eq \
  "https://api.github.com/repos/kadenz-live/kadenz/actions/runners/remove-token" \
  "${out}" "repo remove endpoint"

# ---------------------------------------------------------------------------
# Section 2 — end-to-end PHASE 2 with stubs
# ---------------------------------------------------------------------------
# Each test:
#   1. Builds a fresh scratch dir with stub actions-runner + stub curl.
#   2. Runs the entrypoint via `env` (no subshell — so the parent's PASS/FAIL
#      counters see subsequent assertions).
#   3. Asserts against captured stdout+stderr / stub-generated log files.
#   4. Tears down the scratch dir.

setup_stubs() {
  STUBS="$(mktemp -d)"
  RUNNER_HOME_TMP="${STUBS}/runner-home"
  mkdir -p "${RUNNER_HOME_TMP}/actions-runner"
  CURL_LOG="${STUBS}/curl.log"
  CONFIG_LOG="${STUBS}/config.log"
  RUN_LOG="${STUBS}/run.log"
  CONFIG_STATE="${STUBS}/config.state"

  # Stub curl: log invocation args, emit a JSON body with a canned token
  # depending on the URL. The entrypoint pipes curl into jq, so what curl
  # writes to stdout is what jq parses .token out of.
  cat >"${STUBS}/curl" <<STUB_CURL
#!/usr/bin/env bash
{
  printf 'ARGS:'
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >>"${CURL_LOG}"
url=""
for a in "\$@"; do
  case "\$a" in
    https://*) url="\$a" ;;
  esac
done
case "\$url" in
  *registration-token*) printf '{"token":"stub-reg-XYZ","expires_at":"2099-01-01T00:00:00Z"}\n' ;;
  *remove-token*)       printf '{"token":"stub-rem-ABC","expires_at":"2099-01-01T00:00:00Z"}\n' ;;
  *)                    printf '{}\n' ;;
esac
exit 0
STUB_CURL
  chmod 755 "${STUBS}/curl"

  # Stub config.sh:
  #   * default:                    succeeds, logs args.
  #   * STUB_CONFIG_FAIL_FIRST=1:   first invocation fails (rc=1), retry OK.
  cat >"${RUNNER_HOME_TMP}/actions-runner/config.sh" <<STUB_CONFIG
#!/usr/bin/env bash
{
  printf 'CALL:'
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >>"${CONFIG_LOG}"
if [[ "\${STUB_CONFIG_FAIL_FIRST:-0}" == "1" && ! -f "${CONFIG_STATE}" ]]; then
  touch "${CONFIG_STATE}"
  echo "stub config.sh: simulated first-call failure" >&2
  exit 1
fi
exit 0
STUB_CONFIG
  chmod 755 "${RUNNER_HOME_TMP}/actions-runner/config.sh"

  # Stub run.sh: exit fast so the entrypoint's `wait` returns and the EXIT
  # trap fires. Also verify the env scrub: RUNNER_TOKEN / ACCESS_TOKEN must
  # not be visible to run.sh nor to any process it spawns.
  cat >"${RUNNER_HOME_TMP}/actions-runner/run.sh" <<STUB_RUN
#!/usr/bin/env bash
{
  printf 'RUN: pid=%s trap_sig=%s\n' "\$\$" "\${RUNNER_MANUALLY_TRAP_SIG:-unset}"
  printf 'RUNNER_TOKEN=%s\n' "\${RUNNER_TOKEN:-<unset>}"
  printf 'ACCESS_TOKEN=%s\n' "\${ACCESS_TOKEN:-<unset>}"
} >>"${RUN_LOG}"
exit 0
STUB_RUN
  chmod 755 "${RUNNER_HOME_TMP}/actions-runner/run.sh"
}

teardown_stubs() {
  rm -rf "${STUBS}"
}

# Runs the entrypoint under `env` (so we can pass a controlled env without
# leaking exports into the parent shell — that used to require a subshell,
# which discarded our counter mutations).
run_entry() {
  # Args: KEY=VAL pairs, then the entrypoint sees them.
  OUT="$(
    env -i \
      HOME="${RUNNER_HOME_TMP}" \
      PATH="${STUBS}:/usr/local/bin:/usr/bin:/bin" \
      RUNNER_HOME="${RUNNER_HOME_TMP}" \
      "$@" \
      bash "${ENTRYPOINT}" 2>&1
  )"
  RC=$?
}

# ---------------------------------------------------------------------------

section "PHASE 2 — empty RUNNER_TOKEN + ACCESS_TOKEN + org URL (auto-mint)"

setup_stubs
run_entry \
  RUNNER_URL="https://github.com/kadenz-live" \
  RUNNER_TOKEN="" \
  ACCESS_TOKEN="pat-fake" \
  RUNNER_NAME="test-runner-org" \
  EPHEMERAL="true"
assert_rc 0 "${RC}" "entrypoint exits 0 with org URL + auto-mint"
assert_contains "${OUT}" \
  "Detected runner scope: org (owner='kadenz-live'" \
  "scope detection logs org"
assert_contains "${OUT}" \
  "minting a fresh org-scoped registration token" \
  "auto-mint path is taken when RUNNER_TOKEN is empty"
assert_contains "$(cat "${CURL_LOG}")" \
  "https://api.github.com/orgs/kadenz-live/actions/runners/registration-token" \
  "mint targets the ORG registration endpoint"
assert_contains "$(cat "${CONFIG_LOG}")" \
  "--token stub-reg-XYZ" \
  "config.sh receives the freshly-minted registration token"
assert_not_contains "${OUT}" "stub-reg-XYZ" \
  "fresh registration token is never echoed to entrypoint output"
assert_not_contains "${OUT}" "pat-fake" \
  "PAT is never echoed to entrypoint output"
assert_contains "$(cat "${RUN_LOG}")" "RUNNER_TOKEN=<unset>" \
  "RUNNER_TOKEN scrubbed before run.sh"
assert_contains "$(cat "${RUN_LOG}")" "ACCESS_TOKEN=<unset>" \
  "ACCESS_TOKEN scrubbed before run.sh"
teardown_stubs

section "PHASE 2 — empty RUNNER_TOKEN + ACCESS_TOKEN + repo URL"

setup_stubs
run_entry \
  RUNNER_URL="https://github.com/kadenz-live/kadenz" \
  RUNNER_TOKEN="" \
  ACCESS_TOKEN="pat-fake" \
  RUNNER_NAME="test-runner-repo" \
  EPHEMERAL="true"
assert_rc 0 "${RC}" "entrypoint exits 0 with repo URL + auto-mint"
assert_contains "${OUT}" \
  "Detected runner scope: repo (owner='kadenz-live', repo='kadenz')" \
  "scope detection logs repo with owner+repo"
assert_contains "$(cat "${CURL_LOG}")" \
  "https://api.github.com/repos/kadenz-live/kadenz/actions/runners/registration-token" \
  "mint targets the REPO registration endpoint"
teardown_stubs

section "PHASE 2 — EXIT trap uses ORG remove endpoint"

setup_stubs
run_entry \
  RUNNER_URL="https://github.com/kadenz-live" \
  RUNNER_TOKEN="pre-supplied-reg" \
  ACCESS_TOKEN="pat-fake" \
  RUNNER_NAME="test-runner-org-cleanup" \
  EPHEMERAL="false"
assert_rc 0 "${RC}" "entrypoint exits 0 through EXIT trap"
assert_contains "$(cat "${CURL_LOG}")" \
  "https://api.github.com/orgs/kadenz-live/actions/runners/remove-token" \
  "EXIT trap hits ORG remove endpoint"
assert_not_contains "$(cat "${CURL_LOG}")" \
  "/repos/kadenz-live" \
  "EXIT trap does NOT hit any repo endpoint when scope is org"
assert_contains "$(cat "${CONFIG_LOG}")" "remove --token stub-rem-ABC" \
  "config.sh remove uses freshly-minted removal token"
teardown_stubs

section "PHASE 2 — EXIT trap uses REPO remove endpoint"

setup_stubs
run_entry \
  RUNNER_URL="https://github.com/kadenz-live/kadenz" \
  RUNNER_TOKEN="pre-supplied-reg" \
  ACCESS_TOKEN="pat-fake" \
  RUNNER_NAME="test-runner-repo-cleanup" \
  EPHEMERAL="false"
assert_rc 0 "${RC}" "entrypoint exits 0 through EXIT trap (repo)"
assert_contains "$(cat "${CURL_LOG}")" \
  "https://api.github.com/repos/kadenz-live/kadenz/actions/runners/remove-token" \
  "EXIT trap hits REPO remove endpoint when scope is repo"
assert_not_contains "$(cat "${CURL_LOG}")" \
  "/orgs/kadenz-live" \
  "EXIT trap does NOT hit any org endpoint when scope is repo"
teardown_stubs

section "PHASE 2 — config.sh failure triggers one-shot fresh-mint retry"

setup_stubs
run_entry \
  RUNNER_URL="https://github.com/kadenz-live" \
  RUNNER_TOKEN="stale-token" \
  ACCESS_TOKEN="pat-fake" \
  RUNNER_NAME="test-runner-retry" \
  EPHEMERAL="true" \
  STUB_CONFIG_FAIL_FIRST="1"
assert_rc 0 "${RC}" "entrypoint recovers from initial config.sh failure"
assert_contains "${OUT}" "Minting a fresh org-scoped token and retrying once" \
  "retry log line present"
first_call="$(grep -c 'stale-token' "${CONFIG_LOG}" || true)"
retry_call="$(grep -c 'stub-reg-XYZ' "${CONFIG_LOG}" || true)"
assert_eq "1" "${first_call}" "config.sh first call used the stale token"
assert_eq "1" "${retry_call}" "config.sh retry used the freshly-minted token"
teardown_stubs

section "PHASE 2 — malformed RUNNER_URL fails loud early"

setup_stubs
run_entry \
  RUNNER_URL="https://gitlab.com/kadenz-live/kadenz" \
  RUNNER_TOKEN="whatever"
assert_rc 1 "${RC}" "entrypoint exits 1 on non-github.com URL"
assert_contains "${OUT}" "does not match either supported shape" \
  "error message names the URL shape mismatch"
assert_contains "${OUT}" "docs.github.com" \
  "error message links to the GitHub self-hosted-runners docs"
if [[ ! -s "${CONFIG_LOG}" ]]; then
  _pass "config.sh not invoked on malformed URL"
else
  _fail "config.sh unexpectedly invoked on malformed URL"
fi
teardown_stubs

section "PHASE 2 — neither RUNNER_TOKEN nor ACCESS_TOKEN fails loud"

setup_stubs
run_entry \
  RUNNER_URL="https://github.com/kadenz-live"
assert_rc 1 "${RC}" "entrypoint exits 1 with no token at all"
assert_contains "${OUT}" "Neither RUNNER_TOKEN nor ACCESS_TOKEN is set" \
  "error message names both env vars"
teardown_stubs

# ---------------------------------------------------------------------------

section "Summary"
printf 'PASS: %d\n' "${PASS}"
printf 'FAIL: %d\n' "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  printf '\nFailed tests:\n'
  for t in "${FAILED_TESTS[@]}"; do
    printf '  - %s\n' "$t"
  done
  exit 1
fi
exit 0
