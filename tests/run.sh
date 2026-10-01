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
vault="$repo/vault"
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

assert_file_mask() {
  local normalized
  normalized="$(printf '%s' "$2" | sed -E 's/--ro-bind-data [0-9]+ /--ro-bind-data FD /g')"
  assert_contains "$1" "$normalized" "--ro-bind-data FD $3"
}

test_mask_bare_name_at_any_depth() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m .env -N true 2>&1)"
  assert_file_mask "masks .env at the root" "$out" "$d/.env "
  assert_file_mask "masks .env in a subdirectory" "$out" "$d/src/.env"
  rm -rf "$d"
}

test_mask_prunes_node_modules_and_git() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m .env -N true 2>&1)"
  assert_missing "does not walk into node_modules" "$out" "$d/node_modules"
  rm -rf "$d"
}

test_mask_extglob_negation() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m '.env!(.test)' -N true 2>&1)"
  assert_file_mask "'.env!(.test)' masks .env" "$out" "$d/.env "
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
  assert_file_mask "path-style pattern resolves under CWD" "$out" "$d/src/.env"
  rm -rf "$d"
}

test_mask_absolute_path_outside_cwd() {
  local d home out
  d="$(make_project)"
  home="$(mktemp -d)"
  printf 'TOKEN\n' >"$home/token.json"
  out="$(cd "$d" && "$sa" -d "$home" -m "$home/token.json" -N true 2>&1)"
  assert_file_mask "absolute mask applies outside CWD" "$out" "$home/token.json"
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
  d="$(mktemp -d)"
  printf 'SECRET\n' >"$d/private.txt"
  printf 'not secret\n' >"$d/private.public"
  out="$(cd "$d" && "$sa" -m 'private!(.public)' bash -c 'cat private.txt; cat private.public' 2>&1)"
  assert_missing "the masked file reads as empty" "$out" "SECRET"
  assert_contains "the spared file still reads" "$out" "not secret"
  rm -rf "$d"
}

# --- masks that follow a running jail (safe-agent-watch) --------------------

# run_with_host_change DIR HOST_CMD JAIL_CMD [SAFE_AGENT_OPTS...]
# Runs JAIL_CMD in a jail on DIR. Once the jail is up, HOST_CMD runs on the host
# in DIR; JAIL_CMD sees it done when 'host-done' exists. Files, not sleeps, order
# the two sides, then a short grace period lets the watcher land its mask.
run_with_host_change() {
  local d="$1" host_cmd="$2" jail_cmd="$3"
  shift 3
  rm -f "$d/jail-up" "$d/host-done"
  (
    cd "$d" || exit
    for _ in $(seq 100); do [ -e jail-up ] && break; sleep 0.05; done
    eval "$host_cmd"
    : >host-done
  ) &
  (cd "$d" && "$sa" "$@" bash -c "
    : >jail-up
    for _ in \$(seq 100); do [ -e host-done ] && break; sleep 0.05; done
    sleep 0.3
    $jail_cmd" 2>&1)
  wait
}

test_mask_watch_covers_files_created_later() {
  local d out
  d="$(make_project)"
  out="$(run_with_host_change "$d" \
    'printf "SECRET\n" >.env.local; mkdir -p new/deep; printf "SECRET\n" >new/deep/.env; printf "fine\n" >.env.test.copy.txt' \
    'echo "local[$(cat .env.local)] deep[$(cat new/deep/.env)] other[$(cat .env.test.copy.txt)]"' \
    -m '.env!(.test)')"
  assert_contains "a matching file created after launch is masked" "$out" "local[]"
  assert_contains "one in a directory created after launch is masked" "$out" "deep[]"
  assert_missing "no secret leaks" "$out" "SECRET"
  rm -rf "$d"
}

test_mask_watch_covers_files_the_jail_creates() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m '.env!(.test)' bash -c '
    printf "SECRET\n" >.env.production; sleep 0.3
    echo "prod[$(cat .env.production)]"
    printf "test\n" >.env.test; echo "test[$(cat .env.test)]"' 2>&1)"
  assert_contains "a matching file the jail writes is masked" "$out" "prod[]"
  assert_contains "the extglob exception still applies" "$out" "test[test]"
  rm -rf "$d"
}

# Editors save by writing a temp file and renaming it over the original. That
# replaces the inode a launch-time mask was bound to, and the new one shows.
test_mask_watch_remasks_after_rename_over() {
  local d out
  d="$(make_project)"
  out="$(run_with_host_change "$d" 'printf "NEW SECRET\n" >tmp; mv tmp .env' \
    'echo "env[$(cat .env)]"' -m '.env!(.test)')"
  assert_contains "a file renamed over a masked one is masked again" "$out" "env[]"
  out="$(run_with_host_change "$d" 'printf "NEW SECRET\n" >tmp; mv tmp .env' \
    'echo "env[$(cat .env)]"' -M -m '.env!(.test)')"
  assert_contains "without the watcher it leaks (why the watcher exists)" "$out" "env[NEW SECRET]"
  rm -rf "$d"
}

test_mask_watch_masks_new_directories_as_tmpfs() {
  local d out
  d="$(mktemp -d)"
  out="$(run_with_host_change "$d" 'mkdir -p sub/logs; printf "SECRET\n" >sub/logs/app.log' \
    'ls -A sub/logs; echo listed' -m logs)"
  assert_missing "a matching directory created after launch is emptied" "$out" "app.log"
  assert_contains "the directory itself still exists" "$out" "listed"
  rm -rf "$d"
}

test_mask_watch_disabled_with_M() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -m .env -N true 2>&1)"
  assert_contains "the watcher's empty file is bound" "$out" "/run/safe-agent/empty"
  out="$(cd "$d" && "$sa" -M -m .env -N true 2>&1)"
  assert_missing "-M binds no watcher file" "$out" "/run/safe-agent/empty"
  out="$(cd "$d" && "$sa" -m 'src/*' -N true 2>&1)"
  assert_missing "path-style masks start no watcher" "$out" "/run/safe-agent/empty"
  rm -rf "$d"
}

test_mask_watch_exits_with_the_jail() {
  local d
  d="$(make_project)"
  (cd "$d" && "$sa" -m .env true >/dev/null 2>&1)
  sleep 0.3
  if pgrep -f "safe-agent-watch .* $d " >/dev/null; then
    bad "the watcher exits when the jail does"
  else
    ok "the watcher exits when the jail does"
  fi
  rm -rf "$d"
}

# Use only synthetic .txt files: no project secrets are needed to reproduce
# Git rejecting a device-file mask while building a checkpoint tree.
test_mask_regular_files_support_git_checkpoint() {
  local d out rc before after
  d="$(mktemp -d)"
  mkdir -p "$d/vendor"
  git -C "$d" init -q
  printf 'synthetic fixture\n' >"$d/private.txt"
  printf 'second fixture\n' >"$d/vendor/private.txt"
  git -C "$d" add -- private.txt vendor/private.txt
  before="$(sha256sum "$d/private.txt" "$d/vendor/private.txt")"
  out="$(cd "$d" && "$sa" -m private.txt bash -ec '
    for path in private.txt vendor/private.txt; do
      test -f "$path"
      test ! -s "$path"
      if printf changed >"$path" 2>/dev/null; then
        echo MASK-WRITABLE
        exit 1
      fi
    done
    export GIT_INDEX_FILE=/tmp/checkpoint-index
    git read-tree HEAD 2>/dev/null || git read-tree --empty
    git add -A
    git write-tree >/dev/null
    test "$(git rev-parse :private.txt)" = "$(git hash-object --stdin </dev/null)"
    echo CHECKPOINT-OK
  ' 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "masked regular files support a Git checkpoint" || \
    bad "masked regular files support a Git checkpoint" "$out"
  assert_contains "checkpoint completes with empty placeholders" "$out" "CHECKPOINT-OK"
  assert_missing "file masks cannot be written" "$out" "MASK-WRITABLE"
  after="$(sha256sum "$d/private.txt" "$d/vendor/private.txt")"
  [ "$before" = "$after" ] && ok "host fixture contents remain unchanged" || \
    bad "host fixture contents changed"
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

# --- stale mount points in a persistent jail --------------------------------

# jail_run HOME JAILNAME ARG... — run safe-agent in a named jail whose state
# lives under the throwaway HOME, so the real ~/.cache is never touched. The
# throwaway's bin goes on $PATH because that is where the shadowing happens.
jail_run() {
  local home="$1" jail="$2"; shift 2
  HOME="$home" XDG_CACHE_HOME="$home/.cache" PATH="$home/.local/bin:$PATH" \
    "$sa" -j "$jail" "$@" 2>&1
}

# The regression: bwrap creates a mount point for every bind, and in a named
# jail that file persists. Once the source goes missing the bind is skipped and
# the empty stub is left on $PATH, where it shadows the real binary and turns
# into "bwrap: execvp NAME: Permission denied".
test_stale_mount_point_is_pruned() {
  local d home stub out
  d="$(make_project)"
  home="$(mktemp -d)"
  mkdir -p "$home/.local/bin"
  printf '#!/bin/bash\necho ran\n' >"$home/.local/bin/tool"
  chmod +x "$home/.local/bin/tool"
  stub="$home/.cache/safe-agent/t/home/.local/bin/tool"

  out="$(cd "$d" && jail_run "$home" t -b "$home/.local/bin/tool:$home/.local/bin/tool" tool)"
  assert_contains "the bound binary runs in the jail" "$out" "ran"
  [ -f "$stub" ] && [ ! -s "$stub" ] &&
    ok "bwrap leaves an empty mount point in the persistent home" ||
    bad "bwrap leaves an empty mount point in the persistent home" "no stub at $stub"

  # The install moves or a self-update repoints a symlink: source now missing.
  rm -f "$home/.local/bin/tool"
  out="$(cd "$d" && jail_run "$home" t -b "$home/.local/bin/tool:$home/.local/bin/tool" true)"
  assert_contains "a skipped bind reports the stale mount point" "$out" "removed stale mount point"
  [ ! -e "$stub" ] && ok "the stale mount point is gone" ||
    bad "the stale mount point is gone" "$stub still exists"
  rm -rf "$d" "$home"
}

test_stale_mount_point_does_not_shadow_path() {
  local d home out
  d="$(make_project)"
  home="$(mktemp -d)"
  mkdir -p "$home/.local/bin"
  printf '#!/bin/bash\necho ran\n' >"$home/.local/bin/tool"
  chmod +x "$home/.local/bin/tool"
  (cd "$d" && jail_run "$home" t -b "$home/.local/bin/tool:$home/.local/bin/tool" true) >/dev/null
  rm -f "$home/.local/bin/tool"

  # Without the prune this is EACCES ("Permission denied") from the 0-byte stub,
  # which says nothing about the real problem. ENOENT is the honest answer.
  out="$(cd "$d" && jail_run "$home" t -b "$home/.local/bin/tool:$home/.local/bin/tool" tool)"
  assert_missing "a missing binary is not reported as a permission error" "$out" "Permission denied"
  rm -rf "$d" "$home"
}

test_pruning_spares_real_jail_state() {
  local d home kept out
  d="$(make_project)"
  home="$(mktemp -d)"
  kept="$home/.cache/safe-agent/t/home/.config/keep.json"
  mkdir -p "${kept%/*}"
  printf '{"real": true}\n' >"$kept"
  out="$(cd "$d" && jail_run "$home" t -b "$home/.config/keep.json:$home/.config/keep.json" true)"
  assert_contains "the missing source still warns" "$out" "does not exist; skipping"
  [ -s "$kept" ] && ok "a non-empty file at the same path is left alone" ||
    bad "a non-empty file at the same path is left alone" "$kept was removed or emptied"
  rm -rf "$d" "$home"
}

# --- leftover mount-point directories in a persistent jail ------------------

# A jail started from ~/work/a leaves an empty ~/work/a skeleton in its home.
# Started later from ~/work/b, that skeleton is all the jail would see of a.
test_left_mount_points_are_pruned_on_next_launch() {
  local home jh out
  home="$(mktemp -d)"
  jh="$home/.cache/safe-agent/t/home"
  mkdir -p "$home/work/a/sub" "$home/work/b"
  (cd "$home/work/a/sub" && jail_run "$home" t true) >/dev/null
  [ -d "$jh/work/a/sub" ] &&
    ok "bwrap leaves the launch directory as an empty skeleton" ||
    bad "bwrap leaves the launch directory as an empty skeleton" "no $jh/work/a/sub"
  out="$(cd "$home/work/b" && jail_run "$home" t bash -c 'ls -A "$HOME/work" | sed "s/^/entry:/"')"
  assert_contains "a later launch still sees its own directory" "$out" "entry:b"
  assert_missing "a later launch from elsewhere no longer sees the skeleton" "$out" "entry:a"
  [ ! -e "$jh/work/a" ] && ok "the skeleton is gone from the jail home" ||
    bad "the skeleton is gone from the jail home" "$jh/work/a still exists"
  rm -rf "$home"
}

test_mount_point_pruning_spares_real_jail_state() {
  local home jh
  home="$(mktemp -d)"
  jh="$home/.cache/safe-agent/t/home"
  mkdir -p "$home/work/a" "$home/work/b"
  (cd "$home/work/a" && jail_run "$home" t bash -c 'echo kept >"$HOME/work/note"') >/dev/null
  (cd "$home/work/b" && jail_run "$home" t true) >/dev/null
  [ -s "$jh/work/note" ] && ok "a file the agent wrote is kept" ||
    bad "a file the agent wrote is kept" "$jh/work/note is gone"
  [ ! -e "$jh/work/a" ] && ok "the empty skeleton beside it is still removed" ||
    bad "the empty skeleton beside it is still removed" "$jh/work/a still exists"
  rm -rf "$home"
}

# Removing a directory another session has mounted on detaches that mount, so
# a running session of the same jail must stop the cleanup.
test_mount_point_pruning_waits_for_running_sessions() {
  local home jh lock_fd
  command -v flock >/dev/null 2>&1 || { ok "flock absent, pruning skipped"; return 0; }
  home="$(mktemp -d)"
  jh="$home/.cache/safe-agent/t/home"
  mkdir -p "$home/work/a" "$home/work/b"
  (cd "$home/work/a" && jail_run "$home" t true) >/dev/null
  exec {lock_fd}<"$home/.cache/safe-agent/t/jail.lock"
  flock -s "$lock_fd"
  (cd "$home/work/b" && jail_run "$home" t true) >/dev/null
  [ -d "$jh/work/a" ] && ok "nothing is pruned while a session is running" ||
    bad "nothing is pruned while a session is running" "$jh/work/a was removed"
  exec {lock_fd}<&-
  (cd "$home/work/b" && jail_run "$home" t true) >/dev/null
  [ ! -e "$jh/work/a" ] && ok "pruning resumes once the session ends" ||
    bad "pruning resumes once the session ends" "$jh/work/a still exists"
  rm -rf "$home"
}

test_dry_run_leaves_the_jail_home_alone() {
  local home log
  home="$(mktemp -d)"
  log="$home/.cache/safe-agent/t/mount-points"
  mkdir -p "$home/work/a"
  (cd "$home/work/a" && jail_run "$home" t -N true) >/dev/null
  [ ! -e "$log" ] && ok "a dry run records no mount points" ||
    bad "a dry run records no mount points" "$log exists"
  rm -rf "$home"
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
  assert_contains "HTTPS_PROXY survives the cleared environment" "$out" "proxy=http://proxy:8080"
  assert_contains "SSL_CERT_FILE survives the cleared environment" "$out" "cert=/etc/ssl/certs"
  rm -rf "$d"
}

# bwrap's argv is readable by every process on the host (ps, /proc/PID/cmdline);
# a token passed with -e must travel in its environment instead.
test_preserved_env_stays_off_the_command_line() {
  local d pid out i found=""
  d="$(make_project)"
  (cd "$d" && SAFE_AGENT_TEST_SECRET=hunter2-$$ "$sa" -e SAFE_AGENT_TEST_SECRET \
    bash -c 'echo "secret=$SAFE_AGENT_TEST_SECRET" >"'"$d"'/seen"; sleep 2') >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 50); do
    [ -s "$d/seen" ] && break
    sleep 0.1
  done
  out="$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null)"
  case "$out" in *bwrap*) found=1 ;; esac
  [ -n "$found" ] && ok "the jail is running under bwrap" || bad "the jail is running under bwrap" "$out"
  assert_missing "the secret is not in bwrap's argv" "$out" "hunter2-$$"
  wait "$pid"
  assert_contains "the secret still reaches the jail" "$(cat "$d/seen")" "secret=hunter2-$$"
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
  # ~/.gitconfig and ~/screenshots are bound in unconditionally and on purpose,
  # so they are the only things allowed to appear; nothing else may follow the
  # host in. Filtered rather than assumed absent, because whether they exist is
  # a property of the machine running the tests, not of the jail.
  out="$(cd "$d" && "$sa" bash -c 'ls -A "$HOME" | grep -vxE "\.gitconfig|screenshots" | wc -l' 2>&1)"
  assert_contains "an ephemeral \$HOME starts empty" "$out" "0"
  rm -rf "$d"
}

test_screenshots_are_bound_read_only() {
  local d home out
  d="$(make_project)"
  home="$(mktemp -d)"
  mkdir -p "$home/screenshots"
  out="$(cd "$d" && HOME="$home" "$sa" -N true 2>&1)"
  assert_contains "the screenshot export is read-only" "$out" \
    "--ro-bind $home/screenshots $home/screenshots"
  rm -rf "$d" "$home"
}

test_missing_screenshots_warns() {
  local d home out
  d="$(make_project)"
  home="$(mktemp -d)"
  out="$(cd "$d" && HOME="$home" "$sa" -N true 2>&1)"
  assert_contains "a missing screenshot export warns" "$out" \
    "screenshots does not exist"
  rm -rf "$d" "$home"
}

test_inaccessible_windows_path_entries_are_removed() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && PATH="/usr/bin:/mnt/c/Windows/System32:/bin" "$sa" -N true 2>&1)"
  assert_contains "ordinary PATH entries remain" "$out" " PATH=/usr/bin:/bin "
  assert_missing "inaccessible Windows PATH entries are removed" "$out" "/mnt/c/Windows"
  rm -rf "$d"
}

# --- host-side clipboard image export --------------------------------------

test_pasteshot_exports_path_to_clipboard() {
  local home stubs out exported
  home="$(mktemp -d)"
  stubs="$(mktemp -d)"
  printf '#!/bin/bash\nprintf UE5H\n' >"$stubs/powershell.exe"
  printf '#!/bin/bash\ncat >"$HOME/clipboard"\n' >"$stubs/clip.exe"
  chmod +x "$stubs/powershell.exe" "$stubs/clip.exe"

  out="$(HOME="$home" PATH="$stubs:/usr/bin:/bin" "$repo/pasteshot")"
  exported="$(cat "$home/clipboard")"
  assert_contains "pasteshot prints the exported pathname" "$out" "$home/screenshots/screenshot-"
  [ "$out" = "$exported" ] && ok "pasteshot copies the same pathname as text" || \
    bad "pasteshot copies the same pathname as text" "printed=$out clipboard=$exported"
  [ -f "$exported" ] && ok "pasteshot creates the PNG" || bad "pasteshot creates the PNG" "$exported"
  rm -rf "$home" "$stubs"
}

test_pasteshot_refuses_to_run_in_jail() {
  local out rc
  out="$(SAFE_AGENT=1 "$repo/pasteshot" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "pasteshot refuses a jailed invocation" || bad "pasteshot refuses a jailed invocation"
  assert_contains "pasteshot explains the host-only requirement" "$out" "outside Safe Agent"
}

test_pasteshot_removes_incomplete_file_on_clipboard_error() {
  local home stubs out rc
  home="$(mktemp -d)"
  stubs="$(mktemp -d)"
  printf '#!/bin/bash\necho "pasteshot: no image found in Windows clipboard" >&2\nexit 2\n' \
    >"$stubs/powershell.exe"
  printf '#!/bin/bash\ncat >/dev/null\n' >"$stubs/clip.exe"
  chmod +x "$stubs/powershell.exe" "$stubs/clip.exe"

  out="$(HOME="$home" PATH="$stubs:/usr/bin:/bin" "$repo/pasteshot" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] && ok "pasteshot preserves the clipboard error status" || \
    bad "pasteshot preserves the clipboard error status" "rc=$rc output=$out"
  [ -d "$home/screenshots" ] && [ -z "$(find "$home/screenshots" -type f -print -quit)" ] && \
    ok "pasteshot removes an incomplete PNG" || bad "pasteshot removes an incomplete PNG"
  rm -rf "$home" "$stubs"
}

test_pasteshot_gui_copies_image_to_linux_clipboard() {
  local home stubs out rc
  home="$(mktemp -d)"
  stubs="$(mktemp -d)"
  printf '#!/bin/bash\nprintf UE5H\n' >"$stubs/powershell.exe"
  printf '#!/bin/bash\ncat >"$HOME/windows-clipboard"\n' >"$stubs/clip.exe"
  printf '#!/bin/bash\necho "$*" >"$HOME/wl-args"\ncat >"$HOME/linux-clipboard"\n' >"$stubs/wl-copy"
  chmod +x "$stubs/powershell.exe" "$stubs/clip.exe" "$stubs/wl-copy"

  out="$(HOME="$home" WAYLAND_DISPLAY=wayland-0 PATH="$stubs:/usr/bin:/bin" "$repo/pasteshot" --gui)"
  [ "$(cat "$home/linux-clipboard" 2>/dev/null)" = PNG ] && \
    ok "pasteshot --gui copies the PNG bytes" || bad "pasteshot --gui copies the PNG bytes"
  assert_contains "pasteshot --gui declares a PNG" "$(cat "$home/wl-args" 2>/dev/null)" "--type image/png"
  [ ! -e "$home/windows-clipboard" ] && ok "pasteshot --gui leaves the Windows clipboard alone" || \
    bad "pasteshot --gui leaves the Windows clipboard alone"
  [ -f "$out" ] && ok "pasteshot --gui still saves the PNG" || bad "pasteshot --gui still saves the PNG" "$out"

  out="$(HOME="$home" PATH="$stubs:/usr/bin:/bin" "$repo/pasteshot" --bogus 2>&1)"; rc=$?
  [ "$rc" -eq 64 ] && ok "pasteshot rejects unknown options" || bad "pasteshot rejects unknown options" "rc=$rc"
  rm -rf "$home" "$stubs"
}

test_pasteshot_gui_needs_a_linux_clipboard_tool() {
  local home stubs out rc
  home="$(mktemp -d)"
  stubs="$(mktemp -d)"
  printf '#!/bin/bash\nprintf UE5H\n' >"$stubs/powershell.exe"
  printf '#!/bin/bash\ncat >/dev/null\n' >"$stubs/clip.exe"
  chmod +x "$stubs/powershell.exe" "$stubs/clip.exe"
  for tool in base64 date mkdir tr rm; do ln -s "$(command -v "$tool")" "$stubs/$tool"; done

  out="$(HOME="$home" PATH="$stubs" /bin/bash "$repo/pasteshot" --gui 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "pasteshot --gui fails without wl-copy or xclip" || \
    bad "pasteshot --gui fails without wl-copy or xclip"
  assert_contains "pasteshot --gui names the package to install" "$out" "wl-clipboard"
  [ ! -e "$home/screenshots" ] && ok "pasteshot --gui checks tools before exporting" || \
    bad "pasteshot --gui checks tools before exporting"
  rm -rf "$home" "$stubs"
}

test_network_can_be_blocked() {
  local d out
  d="$(make_project)"
  out="$(cd "$d" && "$sa" -n bash -c 'getent hosts github.com >/dev/null 2>&1 && echo RESOLVED || echo BLOCKED' 2>&1)"
  assert_contains "-n cuts off name resolution" "$out" "BLOCKED"
  rm -rf "$d"
}

# --- agent aliases ----------------------------------------------------------

# run_alias HOME INVOCATION — source aliases.sh with a stub `safe-agent` first on
# PATH and echo the argv the wrapper handed it. HOME is a throwaway, so what the
# machine running the tests happens to have installed cannot change the result.
run_alias() {
  local stub out
  stub="$(mktemp -d)"
  printf '#!/bin/bash\necho "$@"\n' >"$stub/safe-agent"
  printf '#!/bin/bash\n[ "$1" = root ] && [ "$2" = -g ] && printf "%%s\\n" "$HOME/npm-root"\n' >"$stub/npm"
  mkdir -p "$1/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin"
  : >"$1/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  : >"$1/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex-code-mode-host"
  chmod +x "$stub/safe-agent" "$stub/npm" \
    "$1/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex" \
    "$1/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex-code-mode-host"
  out="$(HOME="$1" PATH="$stub:$PATH" bash -c ". '$repo/aliases.sh'; $2" 2>&1)"
  rm -rf "$stub"
  printf '%s' "$out"
}

test_alias_sclaude_pins_host_config() {
  local home out
  home="$(mktemp -d)"
  out="$(run_alias "$home" sclaude)"
  assert_contains "sclaude uses the 'claude' jail" "$out" "-j claude"
  assert_contains "~/.claude is read-write" "$out" "-d $home/.claude "
  assert_contains "credentials are pinned read-only" "$out" \
    "-b $home/.claude/.credentials.json:$home/.claude/.credentials.json"
  assert_contains "settings are pinned read-only" "$out" \
    "-b $home/.claude/settings.json:$home/.claude/settings.json"
  assert_contains "shared skills are pinned read-only for Claude" "$out" \
    "-b $home/.agents/skills:$home/.agents/skills"
  assert_contains "the standard masks are applied" "$out" "-m .env!(.test)"
  rm -rf "$home"
}

# The current project's transcripts must survive the jail. Masking is a tmpfs, so
# a directory name this wrapper fails to recognise as "mine" takes the session's
# own transcript down with it — which is exactly what a dot in the path used to do.
test_alias_sclaude_keeps_the_current_transcripts() {
  local home out d mine theirs
  home="$(mktemp -d)"
  # A path with a dot in it: the encoding flattens it, so the directory name and
  # the raw path do not match character for character.
  d="$home/work/repo/.worktrees/feature"
  mkdir -p "$d"
  d="$(cd "$d" && pwd -P)"   # the wrapper matches on the resolved path
  mine="$home/.claude/projects/${d//[^a-zA-Z0-9]/-}"
  theirs="$home/.claude/projects/-some-other-project"
  mkdir -p "$mine" "$theirs"
  out="$(cd "$d" && run_alias "$home" sclaude)"
  assert_missing "the current project's transcripts are not masked" "$out" "-m $mine"
  assert_contains "another project's transcripts are masked" "$out" "-m $theirs"
  rm -rf "$home"
}

test_alias_scodex_pins_host_config() {
  local home native out
  home="$(mktemp -d)"
  native="$home/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl"
  out="$(run_alias "$home" scodex)"
  assert_contains "scodex uses the 'codex' jail" "$out" "-j codex"
  assert_contains "~/.codex is read-write" "$out" "-d $home/.codex "
  assert_contains "auth is pinned read-only" "$out" \
    "-b $home/.codex/auth.json:$home/.codex/auth.json"
  assert_contains "plugins are pinned read-only" "$out" \
    "-b $home/.codex/plugins:$home/.codex/plugins"
  assert_contains "shared skills are pinned read-only for Codex" "$out" \
    "-b $home/.agents/skills:$home/.agents/skills"
  assert_contains "the native npm payload is pinned read-only" "$out" \
    "-b $native:$home/.local/share/codex-npm"
  assert_contains "scodex launches the native binary from that payload" "$out" \
    "$home/.local/share/codex-npm/bin/codex --dangerously-bypass-approvals-and-sandbox"
  # The host runs the app-server daemon installed here, and it must not be
  # hidden under the payload either, or codex cannot find it.
  assert_contains "the daemon packages are pinned read-only" "$out" \
    "-b $home/.codex/packages:$home/.codex/packages"
  # config.toml doubles as Codex's trust store and is written on entering a
  # directory, so pinning it breaks the app. See aliases.sh.
  assert_missing "config.toml is left writable" "$out" "$home/.codex/config.toml"
  assert_contains "the standard masks are applied" "$out" "-m .env!(.test)"
  rm -rf "$home"
}

# The Codex wrapper validates its npm payload before handing it to safe-agent.
# The target is a directory of its own, not a PATH entry where a stale mount
# point could shadow another command.
test_alias_binaries_are_hard_binds() {
  local home native out
  home="$(mktemp -d)"
  native="$home/npm-root/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl"
  out="$(run_alias "$home" scodex)"
  assert_contains "scodex binds the package containing both binaries" "$out" \
    "-b $native:$home/.local/share/codex-npm"
  out="$(run_alias "$home" sclaude)"
  assert_contains "sclaude binds the claude binary with -r" "$out" "-r $home/.local/bin/claude"
  assert_missing "sclaude does not make the binary optional" "$out" "-b $home/.local/bin/claude"
  rm -rf "$home"
}

# T3 must keep every access grant and pin from both terminal wrappers.
test_alias_st3_shares_both_agent_policies() {
  local home out reference agent i flag
  local words=()
  home="$(mktemp -d)"
  mkdir -p "$home/.local/bin" "$home/apps/t3/squashfs-root" \
    "$home/.claude/projects/-another-project"
  printf '#!/bin/bash\nexit 0\n' >"$home/apps/t3/squashfs-root/AppRun"
  cp "$home/apps/t3/squashfs-root/AppRun" "$home/apps/t3/squashfs-root/t3code"
  chmod +x "$home/apps/t3/squashfs-root/"{AppRun,t3code}
  ln -s "$home/apps/t3/squashfs-root/AppRun" "$home/.local/bin/t3code"
  out="$(PATH="$home/.local/bin:$PATH" run_alias "$home" 'st3 --dry-run --test-argument')"
  for agent in sclaude scodex; do
    reference="$(run_alias "$home" "$agent")"
    read -r -a words <<<"$reference"
    for ((i=0; i<${#words[@]}-1; i++)); do
      flag="${words[i]}"
      case "$flag" in
        -d|-r|-b|-m)
          if [ "$flag" = -m ] && [[ "${words[i+1]}" = "$home/.claude/projects/"* ]]; then
            assert_missing "T3 leaves other projects' Claude transcripts accessible" "$out" "$flag ${words[i+1]}"
            continue
          fi
          assert_contains "st3 retains $agent $flag ${words[i+1]}" "$out" "$flag ${words[i+1]}"
          ;;
      esac
    done
  done
  assert_contains "T3 uses its own persistent jail" "$out" "-j t3code"
  assert_contains "T3 install is read-only" "$out" "-r $home/apps/t3/squashfs-root"
  assert_contains "T3 exposes WSLg" "$out" "-d /mnt/wslg -d /tmp/.X11-unix"
  assert_contains "T3 binds the Wayland socket" "$out" \
    "-b /mnt/wslg/runtime-dir/wayland-0:/run/user/$(id -u)/wayland-0"
  assert_contains "T3 supports dry runs" "$out" "-N"
  assert_contains "T3 passes app arguments through" "$out" \
    "AppRun --no-sandbox --ozone-platform=wayland --test-argument"
  reference="$(PATH="$home/.local/bin:$PATH" run_alias "$home" 'st3code --dry-run --test-argument')"
  [ "$reference" = "$out" ] && ok "st3code is a synonym for st3" || bad "st3code differs from st3"
  # An existing host launch must block a second jail even though each jail
  # has its own /tmp and cannot reach Electron's other singleton socket.
  mkdir -p "$home/.cache/safe-agent/t3code"
  local lock_fd
  exec {lock_fd}>"$home/.cache/safe-agent/t3code/launch.lock"
  flock -n "$lock_fd"
  out="$(XDG_CACHE_HOME="$home/.cache" PATH="$home/.local/bin:$PATH" run_alias "$home" st3)"
  assert_contains "a second T3 launch reports the running instance" "$out" "already running in this jail"
  assert_missing "a second T3 launch never starts another jail" "$out" "-j t3code"
  out="$(XDG_CACHE_HOME="$home/.cache" PATH="$home/.local/bin:$PATH" run_alias "$home" 'st3 --dry-run')"
  assert_contains "dry runs work while T3 is running" "$out" "-j t3code"
  exec {lock_fd}>&-
  out="$(XDG_CACHE_HOME="$home/.cache" PATH="$home/.local/bin:$PATH" run_alias "$home" st3)"
  assert_contains "T3 can launch after the prior lock is released" "$out" "-j t3code"
  rm -rf "$home"
}

test_alias_st3_rejects_unextracted_install() {
  local home out
  home="$(mktemp -d)"
  mkdir -p "$home/.local/bin"
  printf '#!/bin/bash\nexit 0\n' >"$home/.local/bin/t3code"
  chmod +x "$home/.local/bin/t3code"
  out="$(PATH="$home/.local/bin:$PATH" run_alias "$home" st3)"
  assert_contains "T3 explains unsupported launcher layouts" "$out" "must point to an extracted AppImage"
  assert_missing "invalid installs never enter the jail" "$out" "-j t3code"
  rm -rf "$home"
}

# A read-only pin only holds if bwrap mounts it after the read-write grant it
# sits inside; safe-agent orders -d before -r before -b for exactly this.
test_ro_pins_are_mounted_after_the_rw_grant() {
  local d out rw_at pin_at
  d="$(make_project)"
  mkdir -p "$d/state/pinned"
  out="$(cd "$d" && "$sa" -d "$d/state" -r "$d/state/pinned" -N true 2>&1)"
  rw_at="${out%%--bind $d/state $d/state*}"
  pin_at="${out%%--ro-bind $d/state/pinned*}"
  [ "${#rw_at}" -lt "${#pin_at}" ] &&
    ok "-d is mounted before the -r nested inside it" ||
    bad "-d is mounted before the -r nested inside it" "$out"
  rm -rf "$d"
}

# --- vault ------------------------------------------------------------------
#
# The password is piped rather than typed: `read -rs` takes a line from stdin
# when it is not a terminal, which is what makes these runnable unattended.
# $VAULT_EDITOR stands in for the interactive editor for the same reason.

vault_env() {
  local d="$1"; shift
  VAULT_ARCHIVE="$d/vault.7z" VAULT_EDITOR="$d/editor.sh" "$vault" "$@" 2>&1
}

# A vault holding one file, plus a scripted "editor" that appends a line.
make_vault() {
  local d
  d="$(mktemp -d)"
  printf 'api_key=SECRET123\n' >"$d/creds.txt"
  printf '#!/bin/bash\nprintf "EDITED\\n" >> "$1"\n' >"$d/editor.sh"
  chmod +x "$d/editor.sh"
  printf '#!/bin/bash\nexit 0\n' >"$d/noop.sh"
  chmod +x "$d/noop.sh"
  ( cd "$d" && printf 'pw\npw\n' | VAULT_ARCHIVE="$d/vault.7z" "$vault" add creds.txt >/dev/null 2>&1 )
  printf '%s' "$d"
}

# Help has to work on a machine without 7z — it is the thing you run to find out
# what is missing. And a typo must not exit 0, or it sails through `vault x && y`.
test_vault_help() {
  local out rc bindir b
  for arg in --help -h help; do
    out="$("$vault" "$arg" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] && ok "$arg exits 0" || bad "$arg exits 0" "got $rc"
    assert_contains "$arg prints usage on stdout" "$out" "usage: vault"
  done

  "$vault" bogus >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && ok "an unknown command exits non-zero" || bad "an unknown command exits non-zero"
  out="$("$vault" bogus 2>/dev/null)"
  assert_missing "an unknown command writes nothing to stdout" "$out" "usage: vault"

  "$vault" edit >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && ok "a missing argument exits non-zero" || bad "a missing argument exits non-zero"

  # A PATH holding just enough coreutils to render the help, and no 7z.
  bindir="$(mktemp -d)"
  for b in cat mktemp rm chmod dirname cksum; do ln -s "/usr/bin/$b" "$bindir/$b"; done
  out="$(PATH="$bindir" "$vault" --help 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "help works without 7z installed" || bad "help works without 7z installed" "$out"
  out="$(PATH="$bindir" "$vault" ls 2>&1)"
  assert_contains "other commands explain the missing dependency" "$out" "7z not found"
  rm -rf "$bindir"
}

test_vault_add_and_read() {
  local d
  d="$(make_vault)"
  assert_contains "ls shows what was added" "$(printf 'pw\n' | vault_env "$d" ls)" "creds.txt"
  assert_contains "cat prints the contents" "$(printf 'pw\n' | vault_env "$d" cat creds.txt)" "SECRET123"
  rm -rf "$d"
}

# The point of the whole thing: edit in place, with plaintext never on disk.
test_vault_edit_roundtrip() {
  local d out
  d="$(make_vault)"
  out="$(printf 'pw\n' | vault_env "$d" edit creds.txt)"
  assert_contains "edit reports the save" "$out" "saved creds.txt"
  assert_contains "the edit survives re-encryption" "$(printf 'pw\n' | vault_env "$d" cat creds.txt)" "EDITED"
  assert_contains "the original content is still there" "$(printf 'pw\n' | vault_env "$d" cat creds.txt)" "SECRET123"

  # Editing a name that is not in the archive creates it, like `vim newfile`.
  out="$(printf 'pw\n' | vault_env "$d" edit sub/fresh.txt)"
  assert_contains "editing a new name creates it" "$out" "saved sub/fresh.txt"
  assert_contains "the new file is in the archive" "$(printf 'pw\n' | vault_env "$d" ls)" "sub/fresh.txt"

  # Quitting without changing anything must not force a needless rewrite.
  out="$(printf 'pw\n' | VAULT_ARCHIVE="$d/vault.7z" VAULT_EDITOR="$d/noop.sh" "$vault" edit creds.txt 2>&1)"
  assert_contains "an unchanged file is not rewritten" "$out" "unchanged"
  rm -rf "$d"
}

# -mhe=on is what stops `7z l` printing every filename to anyone who asks.
test_vault_headers_are_encrypted() {
  local d out
  d="$(make_vault)"
  out="$(7z l "$d/vault.7z" -p 2>&1)"
  assert_contains "listing without the password fails" "$out" "Cannot open encrypted archive"
  assert_missing "filenames do not leak" "$out" "creds.txt"
  assert_missing "contents do not leak to strings(1)" "$(strings "$d/vault.7z")" "SECRET123"
  rm -rf "$d"
}

# Creating an archive SETS the password, so an unconfirmed typo would encrypt
# the data under a string nobody knows.
test_vault_new_archive_confirms_password() {
  local d out
  d="$(mktemp -d)"
  printf 'secret\n' >"$d/f.txt"
  out="$(cd "$d" && printf 'pw1\npw2\n' | VAULT_ARCHIVE="$d/v.7z" "$vault" add f.txt 2>&1)"
  assert_contains "mismatched passwords are refused" "$out" "do not match"
  [ ! -f "$d/v.7z" ] && ok "no archive is created on mismatch" || bad "no archive is created on mismatch"
  out="$(cd "$d" && printf '\n\n' | VAULT_ARCHIVE="$d/v.7z" "$vault" add f.txt 2>&1)"
  assert_contains "empty passwords are refused" "$out" "empty password"
  rm -rf "$d"
}

# Every write recreates the archive, which resets it to a world-readable 0644.
test_vault_archive_is_not_world_readable() {
  local d
  d="$(make_vault)"
  assert_contains "0600 after add" "$(stat -c '%a' "$d/vault.7z")" "600"
  printf 'pw\n' | vault_env "$d" edit creds.txt >/dev/null
  assert_contains "0600 after edit" "$(stat -c '%a' "$d/vault.7z")" "600"
  printf 'pw\n' | vault_env "$d" rm creds.txt >/dev/null
  assert_contains "0600 after rm" "$(stat -c '%a' "$d/vault.7z")" "600"
  rm -rf "$d"
}

# Plaintext lives in /dev/shm only for the life of one command.
test_vault_leaves_no_plaintext() {
  local d
  d="$(make_vault)"
  # Compared before and after rather than globbing /dev/shm outright: a real
  # `vault edit` open in another terminal legitimately owns a scratch dir there,
  # and the suite must not fail because the machine is in use.
  local before after
  before="$(ls -d /dev/shm/vault.* 2>/dev/null | sort)"
  printf 'pw\n' | vault_env "$d" cat creds.txt >/dev/null
  printf 'pw\n' | vault_env "$d" edit creds.txt >/dev/null
  after="$(ls -d /dev/shm/vault.* 2>/dev/null | sort)"
  [ "$before" = "$after" ] &&
    ok "no scratch dir survives the command" ||
    bad "no scratch dir survives the command" "new: $after"
  [ ! -e "$d/creds.txt.tmp" ] && ok "no stray temp files beside the archive" || bad "no stray temp files"
  rm -rf "$d"
}

# A trap whose last command fails silently takes the script's exit status with
# it, which would break `vault add x && rm x` in a caller's script.
# A shell session that ends up empty must not replace the archive: `7z a` on an
# empty dir writes a 32-byte stub and drops the encryption with it, silently
# destroying the vault. This happened for real before the guard existed.
test_vault_sh_will_not_empty_the_archive() {
  local d before after out
  d="$(make_vault)"
  printf '#!/bin/bash\nrm -rf ./*\nexit 0\n' >"$d/wipe.sh"; chmod +x "$d/wipe.sh"
  before="$(md5sum <"$d/vault.7z")"
  out="$(printf 'pw\n' | VAULT_ARCHIVE="$d/vault.7z" SHELL="$d/wipe.sh" "$vault" sh 2>&1)"
  after="$(md5sum <"$d/vault.7z")"
  assert_contains "it says why nothing was written" "$out" "archive left as it was"
  [ "$before" = "$after" ] && ok "the archive is byte-identical" || bad "the archive is byte-identical"
  assert_contains "the contents are still encrypted" "$(7z l "$d/vault.7z" -p 2>&1)" "Cannot open encrypted archive"
  rm -rf "$d"
}

test_vault_sh_saves_and_marks_the_shell() {
  local d
  d="$(make_vault)"
  printf '#!/bin/bash\necho "marker=$VAULT_SH" > from-shell.txt\nexit 0\n' >"$d/sh.sh"
  chmod +x "$d/sh.sh"
  printf 'pw\n' | VAULT_ARCHIVE="$d/vault.7z" SHELL="$d/sh.sh" "$vault" sh >/dev/null 2>&1
  assert_contains "work done in the shell is re-encrypted" "$(printf 'pw\n' | vault_env "$d" cat from-shell.txt)" "marker=1"
  # The prompt rcfile lives outside the scratch dir precisely so it cannot be
  # swept into the archive along with the user's files.
  assert_missing "the prompt rcfile is not archived" "$(printf 'pw\n' | vault_env "$d" ls)" "vault-rc"
  rm -rf "$d"
}

# Two sessions each re-add their whole scratch dir on exit, so the last one out
# silently overwrites the other's work.
test_vault_blocks_concurrent_sessions() {
  local d out
  command -v flock >/dev/null 2>&1 || { ok "flock absent, locking skipped"; return 0; }
  d="$(make_vault)"
  printf '#!/bin/bash\nsleep 3\n' >"$d/slow.sh"; chmod +x "$d/slow.sh"
  ( printf 'pw\n' | VAULT_ARCHIVE="$d/vault.7z" SHELL="$d/slow.sh" "$vault" sh >/dev/null 2>&1 ) &
  sleep 1
  out="$(printf 'pw\n' | vault_env "$d" sh 2>&1)"
  assert_contains "a second writer is refused" "$out" "already has"
  out="$(printf 'pw\n' | vault_env "$d" edit creds.txt 2>&1)"
  assert_contains "a concurrent edit is refused" "$out" "already has"
  # Readers do not mutate the archive, so they are allowed through.
  assert_contains "readers are still allowed" "$(printf 'pw\n' | vault_env "$d" ls)" "creds.txt"
  wait
  out="$(printf 'pw\n' | vault_env "$d" ls 2>&1)"
  assert_contains "the lock frees when the holder exits" "$out" "creds.txt"
  rm -rf "$d"
}

test_vault_exit_codes() {
  local d rc
  d="$(make_vault)"
  printf 'pw\n' | vault_env "$d" ls >/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "ls exits 0 on success" || bad "ls exits 0 on success" "got $rc"
  printf 'pw\n' | vault_env "$d" edit creds.txt >/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "edit exits 0 on success" || bad "edit exits 0 on success" "got $rc"
  printf 'wrong\n' | vault_env "$d" ls >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && ok "a wrong password exits non-zero" || bad "a wrong password exits non-zero"
  rm -rf "$d"
}

command -v bwrap >/dev/null 2>&1 || { echo "bubblewrap not installed" >&2; exit 1; }

# vault is optional, so its tests are skipped rather than failed without 7z.
if ! command -v 7z >/dev/null 2>&1; then
  echo "note: 7z not installed, skipping vault tests" >&2
  for t in $(declare -F | sed -n 's/^declare -f test_vault_//p'); do
    unset -f "test_vault_$t"
  done
fi

for t in $(declare -F | sed -n 's/^declare -f test_//p'); do
  run_test "$t"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
