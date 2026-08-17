#!/bin/bash
# Smoke tests for safe-agent.
#
#   ./tests/run.sh          run everything
#   ./tests/run.sh mask     run only tests whose name matches 'mask'
#
# Mount-shape assertions use `-N` (dry run) and inspect the bwrap argv, which is
# fast and needs no privileges. Behavioural assertions run a real jail.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
sa="$repo/safe-agent"
filter="${1:-}"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; }

# assert_contains NAME HAYSTACK NEEDLE
assert_contains() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to find: $3" ;; esac
}
assert_missing() {
  case "$2" in *"$3"*) bad "$1" "expected NOT to find: $3" ;; *) ok "$1" ;; esac
}

run_test() {
  local name="$1"
  [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && return 0
  printf '%s\n' "$name"
  "test_$name"
}

# A throwaway project: a git repo with a few files worth masking.
make_project() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/src" "$d/logs" "$d/node_modules/pkg"
  printf 'SECRET\n' >"$d/.env"
  printf 'not secret\n' >"$d/.env.test"
  printf 'SECRET\n' >"$d/src/.env"
  printf 'SECRET\n' >"$d/node_modules/pkg/.env"
  git -C "$d" init -q
  # Identity comes from the fixture, not the host: these tests must pass on a
  # machine with no ~/.gitconfig (which is exactly what a fresh jail looks like).
  git -C "$d" config user.email safe-agent@test.invalid
  git -C "$d" config user.name 'safe-agent tests'
  git -C "$d" commit -q --allow-empty -m init
  printf '%s' "$d"
}

# --- CWD handling -----------------------------------------------------------

test_refuses_home() {
  local d out rc
  d="$(mktemp -d)"
  out="$(cd "$d" && HOME="$d" "$sa" -N true 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "exits non-zero when CWD is \$HOME" || bad "exits non-zero when CWD is \$HOME"
  assert_contains "explains why it refused" "$out" "refusing to grant entire"
  rm -rf "$d"
}

test_cwd_bound_rw_by_default() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -N true 2>&1)"
  assert_contains "CWD is bind-mounted read-write" "$out" "--bind $d $d"
  assert_contains "CWD is the working directory" "$out" "--chdir $d"
  rm -rf "$d"
}

test_cwd_suppressed_with_D() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -D -N true 2>&1)"
  assert_missing "-D does not bind CWD" "$out" "--bind $d $d"
  rm -rf "$d"
}

# --- masks ------------------------------------------------------------------

test_mask_bare_name_at_any_depth() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m .env -N true 2>&1)"
  assert_contains "masks .env at the root" "$out" "/dev/null $d/.env "
  assert_contains "masks .env in a subdirectory" "$out" "/dev/null $d/src/.env"
  rm -rf "$d"
}

test_mask_prunes_node_modules_and_git() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m .env -N true 2>&1)"
  assert_missing "does not walk into node_modules" "$out" "node_modules"
  rm -rf "$d"
}

test_mask_extglob_negation() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m '.env!(.test)' -N true 2>&1)"
  assert_contains "'.env!(.test)' masks .env" "$out" "/dev/null $d/.env "
  assert_missing "'.env!(.test)' spares .env.test" "$out" "$d/.env.test"
  rm -rf "$d"
}

test_mask_directory_becomes_tmpfs() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m logs -N true 2>&1)"
  assert_contains "a masked directory is replaced by tmpfs" "$out" "--tmpfs $d/logs"
  rm -rf "$d"
}

test_mask_path_style_anchored_at_cwd() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m 'src/*' -N true 2>&1)"
  assert_contains "path-style pattern resolves under CWD" "$out" "/dev/null $d/src/.env"
  rm -rf "$d"
}

test_mask_absolute_path_outside_cwd() {
  local d home out
  d="$(make_project)"
  home="$(mktemp -d)"
  printf 'TOKEN\n' >"$home/token.json"
  out="$(cd "$d" && "$sa" -d "$home" -m "$home/token.json" -N true 2>&1)"
  assert_contains "absolute mask applies outside CWD" "$out" "/dev/null $home/token.json"
  rm -rf "$d" "$home"
}

test_mask_no_match_warns() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m nothing-matches-this -N true 2>&1)"
  assert_contains "an unmatched mask warns" "$out" "matched nothing"
  rm -rf "$d"
}

test_mask_is_enforced_in_the_jail() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m '.env!(.test)' bash -c 'cat .env; cat .env.test' 2>&1)"
  assert_missing "the masked file reads as empty" "$out" "SECRET"
  assert_contains "the spared file still reads" "$out" "not secret"
  rm -rf "$d"
}

# --- optional binds (the regression that broke sclaude) ---------------------

test_missing_b_source_warns_but_runs() {
  local d out rc
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -b "$d/nope.json:$d/nope.json" bash -c 'echo alive' 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "a missing -b source does not abort the jail" || bad "a missing -b source does not abort the jail" "$out"
  assert_contains "a missing -b source warns" "$out" "does not exist; skipping"
  assert_contains "the jail still runs the command" "$out" "alive"
  rm -rf "$d"
}

test_missing_r_source_is_fatal() {
  local d out rc
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -r "$d/nope" true 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "a missing -r source is a hard error" || bad "a missing -r source is a hard error" "$out"
  rm -rf "$d"
}

# --- git --------------------------------------------------------------------

test_git_config_and_hooks_are_read_only() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" bash -c '
    echo x >>.git/config           2>&1 && echo CONFIG-WRITABLE
    echo x  >.git/hooks/pre-commit 2>&1 && echo HOOKS-WRITABLE
    git branch jailed              2>&1 && echo BRANCHED' 2>&1)"
  assert_missing ".git/config is read-only" "$out" "CONFIG-WRITABLE"
  assert_missing ".git/hooks is read-only" "$out" "HOOKS-WRITABLE"
  assert_contains "refs are still writable (branching works)" "$out" "BRANCHED"
  rm -rf "$d"
}

test_git_worktree_metadata_is_bound() {
  local d wt out
  d="$(make_project)"
  wt="$d-wt"
  git -C "$d" worktree add -q -b wt "$wt" 2>/dev/null
  out="$(cd "$wt" && "$sa" -N true 2>&1)"
  assert_contains "the worktree's common git dir is bound" "$out" "--bind $d/.git $d/.git"
  git -C "$d" worktree remove --force "$wt" 2>/dev/null
  rm -rf "$d" "$wt"
}

# --- environment and namespaces ---------------------------------------------

test_env_is_cleared() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && SAFE_AGENT_TEST_LEAK=leaked "$sa" bash -c 'echo "leak=${SAFE_AGENT_TEST_LEAK-none}"; echo "jail=$SAFE_AGENT_JAIL"' 2>&1)"
  assert_contains "unlisted variables are stripped" "$out" "leak=none"
  assert_contains "SAFE_AGENT_JAIL marks an ephemeral jail" "$out" "jail=ephemeral"
  rm -rf "$d"
}

test_proxy_and_tls_env_preserved() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && HTTPS_PROXY=http://proxy:8080 SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    "$sa" bash -c 'echo "proxy=$HTTPS_PROXY cert=$SSL_CERT_FILE"' 2>&1)"
  assert_contains "HTTPS_PROXY survives --clearenv" "$out" "proxy=http://proxy:8080"
  assert_contains "SSL_CERT_FILE survives --clearenv" "$out" "cert=/etc/ssl/certs"
  rm -rf "$d"
}

test_sys_is_available() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" bash -c 'cat /sys/fs/cgroup/cgroup.controllers >/dev/null 2>&1 && echo CGROUPS-VISIBLE' 2>&1)"
  assert_contains "/sys is mounted so cgroup limits are readable" "$out" "CGROUPS-VISIBLE"
  rm -rf "$d"
}

test_home_is_a_fresh_tmpfs() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" bash -c 'ls -A "$HOME" | wc -l' 2>&1)"
  assert_contains "an ephemeral \$HOME starts empty" "$out" "0"
  rm -rf "$d"
}

test_network_can_be_blocked() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -n bash -c 'getent hosts github.com >/dev/null 2>&1 && echo RESOLVED || echo BLOCKED' 2>&1)"
  assert_contains "-n cuts off name resolution" "$out" "BLOCKED"
  rm -rf "$d"
}

command -v bwrap >/dev/null 2>&1 || { echo "bubblewrap not installed" >&2; exit 1; }

for t in $(declare -F | sed -n 's/^declare -f test_//p'); do
  run_test "$t"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
