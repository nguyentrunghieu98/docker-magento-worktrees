#!/usr/bin/env bash
# test-wt.sh - automated, dependency-free tests for the wt CLI (bin/wt).
#
# The CLI derives PROJECT_ROOT from the location of the script itself (a "bin"
# parent directory means the project root is the directory above it), so each
# test copies bin/wt into a throwaway project root under /tmp and drives it
# there. The real Docker daemon is never contacted: a fake `docker` earlier on
# PATH answers `docker info`, and bin/docker-compose / bin/magento are stubs that
# record the arguments they receive.
#
# Usage:  bash tests/test-wt.sh
# Exit:   0 when every check passes, 1 otherwise.
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLI_SRC="${MAGENTO_WT_CLI:-$(dirname "$TESTS_DIR")/bin/wt}"
ORIG_PATH="$PATH"

CHECKS=0
PASSED=0
FAILED=0
SANDBOXES=()
SANDBOX=''
OUTPUT=''
STATUS=0

if [[ ! -f "$CLI_SRC" ]]; then
  printf 'Bail out! wt CLI not found at %s\n' "$CLI_SRC" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

_snippet() {
  local text="${1:-}"
  text="${text//$'\n'/ | }"
  printf '%s' "${text:0:400}"
}

pass_() {
  CHECKS=$((CHECKS + 1))
  PASSED=$((PASSED + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail_() {
  local desc="$1" detail="${2:-}"
  CHECKS=$((CHECKS + 1))
  FAILED=$((FAILED + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$desc"
  if [[ -n "$detail" ]]; then
    printf '#   %s\n' "${detail//$'\n'/$'\n'#   }"
  fi
  return 0
}

assert_status() {
  local want="$1" desc="$2"
  if [[ "$STATUS" -eq "$want" ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "expected exit status $want, got $STATUS; output: $(_snippet "$OUTPUT")"
  fi
}

assert_status_nonzero() {
  local desc="$1"
  if [[ "$STATUS" -ne 0 ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "expected a non-zero exit status, got 0; output: $(_snippet "$OUTPUT")"
  fi
}

assert_equals() {
  local want="$1" got="$2" desc="$3"
  if [[ "$want" == "$got" ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "expected [$want], got [$got]"
  fi
}

assert_contains() {
  local needle="$1" desc="$2" hay="${3-$OUTPUT}"
  if [[ "$hay" == *"$needle"* ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "expected [$needle] in: $(_snippet "$hay")"
  fi
}

assert_not_contains() {
  local needle="$1" desc="$2" hay="${3-$OUTPUT}"
  if [[ "$hay" != *"$needle"* ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "did not expect [$needle] in: $(_snippet "$hay")"
  fi
}

assert_file() {
  local path="$1" desc="$2"
  if [[ -f "$path" ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "missing file: $path"
  fi
}

assert_dir() {
  local path="$1" desc="$2"
  if [[ -d "$path" ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "missing directory: $path"
  fi
}

assert_absent() {
  local path="$1" desc="$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "unexpected path exists: $path"
  fi
}

assert_symlink_to() {
  local link="$1" want="$2" desc="$3" got=''
  [[ -L "$link" ]] && got="$(readlink "$link")"
  if [[ "$got" == "$want" ]]; then
    pass_ "$desc"
  else
    fail_ "$desc" "symlink $link -> [$got], expected [$want]"
  fi
}

assert_files_equal() {
  local left="$1" right="$2" desc="$3"
  if [[ -f "$left" && -f "$right" ]] && cmp -s "$left" "$right"; then
    pass_ "$desc"
  else
    fail_ "$desc" "$left and $right differ or are missing"
  fi
}

assert_cmd_status() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_equals "$want" "$got" "$desc"
}

assert_file_line() {
  local file="$1" line="$2" desc="$3"
  if [[ -f "$file" ]] && grep -Fxq -- "$line" "$file"; then
    pass_ "$desc"
  else
    fail_ "$desc" "expected line [$line] in $file; content: $(_snippet "$(cat "$file" 2>/dev/null || true)")"
  fi
}

assert_file_matches() {
  local file="$1" regex="$2" desc="$3"
  if [[ -f "$file" ]] && grep -Eq -- "$regex" "$file"; then
    pass_ "$desc"
  else
    fail_ "$desc" "expected /$regex/ in $file; content: $(_snippet "$(cat "$file" 2>/dev/null || true)")"
  fi
}

assert_file_does_not_match() {
  local file="$1" regex="$2" desc="$3"
  if [[ ! -f "$file" ]] || ! grep -Eq -- "$regex" "$file"; then
    pass_ "$desc"
  else
    fail_ "$desc" "unexpected /$regex/ in $file; content: $(_snippet "$(cat "$file" 2>/dev/null || true)")"
  fi
}

assert_file_line_count() {
  local want="$1" file="$2" regex="$3" desc="$4" got=0
  if [[ -f "$file" ]]; then
    got="$(grep -Ec -- "$regex" "$file" || true)"
  fi
  assert_equals "$want" "$got" "$desc"
}

# --------------------------------------------------------------------------
# Sandbox
# --------------------------------------------------------------------------

cleanup_sandboxes() {
  local dir
  for dir in "${SANDBOXES[@]}"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      rm -rf "$dir"
    fi
  done
  SANDBOXES=()
  return 0
}
trap cleanup_sandboxes EXIT

# A throwaway project root with: the CLI copy, a real Git repo in src/, a couple
# of commits, one extra branch, ignored Magento core files, a minimal
# compose.worktree.yaml, bin/docker-compose + bin/magento stubs and a fake
# docker on PATH.
sandbox_new() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")"
  SANDBOX="$(realpath "$SANDBOX")"
  SANDBOXES+=("$SANDBOX")

  mkdir -p "$SANDBOX/bin" "$SANDBOX/.fakebin" "$SANDBOX/.logs"
  cp "$CLI_SRC" "$SANDBOX/bin/wt"
  chmod 755 "$SANDBOX/bin/wt"

  export WT_LOG_DIR="$SANDBOX/.logs"
  export WT_DOCKER_ONLINE="$SANDBOX/.docker-online"
  export PATH="$SANDBOX/.fakebin:$ORIG_PATH"

  cat > "$SANDBOX/.fakebin/docker" <<'STUB'
#!/usr/bin/env bash
# Fake Docker: records the call and never talks to a daemon.
printf 'docker %s\n' "$*" >> "${WT_LOG_DIR:?}/docker.log"
if [[ "${1:-}" == 'info' ]]; then
  [[ -e "${WT_DOCKER_ONLINE:?}" ]] && exit 0
  exit 1
fi
exit 0
STUB
  chmod 755 "$SANDBOX/.fakebin/docker"

  cat > "$SANDBOX/bin/docker-compose" <<'STUB'
#!/usr/bin/env bash
# Stub of the project's bin/docker-compose wrapper, which loads
# compose.worktree.yaml in the real project. It records every call and
# pretends that app, phpfpm, db and redis are running.
printf 'compose %s\n' "$*" >> "${WT_LOG_DIR:?}/compose.log"
case "${1:-}" in
  ps)
    printf '%s\n' app phpfpm db redis
    exit 0
    ;;
  config)
    exit 0
    ;;
  up)
    [[ "${WT_FAIL_UP:-0}" == '1' ]] && exit 1
    exit 0
    ;;
esac
exit 0
STUB
  chmod 755 "$SANDBOX/bin/docker-compose"

  cat > "$SANDBOX/bin/magento" <<'STUB'
#!/usr/bin/env bash
printf 'magento %s\n' "$*" >> "${WT_LOG_DIR:?}/magento.log"
exit 0
STUB
  chmod 755 "$SANDBOX/bin/magento"

  cat > "$SANDBOX/compose.worktree.yaml" <<'YAML'
services:
  phpfpm:
    volumes:
      - ./.active-src:/var/www/html
      - ./src/bin:/var/www/html/bin
      - ./src/dev:/var/www/html/dev
      - ./src/lib:/var/www/html/lib
      - ./src/phpserver:/var/www/html/phpserver
      - ./src/setup:/var/www/html/setup
      - ./src/vendor:/var/www/html/vendor
      - ./src/node_modules:/var/www/html/node_modules
YAML

  local src="$SANDBOX/src"
  mkdir -p "$src"
  git -c init.defaultBranch=master init -q "$src"
  git -C "$src" config user.name 'wt tests'
  git -C "$src" config user.email 'tests@example.invalid'
  git -C "$src" config commit.gpgsign false

  mkdir -p \
    "$src/app/etc" "$src/pub" "$src/bin" "$src/dev" "$src/lib" \
    "$src/phpserver" "$src/setup" "$src/vendor" "$src/node_modules" "$src/pub/media"

  # Everything is ignored except the whitelisted files, so the Magento core
  # files below are untracked and Git-ignored exactly like in the real project.
  printf '*\n!.gitignore\n!composer.json\n' > "$src/.gitignore"
  cat > "$src/composer.json" <<'JSON'
{
  "name": "format/magento-test",
  "description": "sandbox checkout for wt tests"
}
JSON

  printf '<?php // app/bootstrap.php sandbox\n' > "$src/app/bootstrap.php"
  printf '<?php // app/autoload.php sandbox\n' > "$src/app/autoload.php"
  printf "<?php return __DIR__ . '/../../vendor/autoload.php';\n" > "$src/app/etc/vendor_path.php"
  printf "<?php return ['db' => ['host' => 'db', 'dbname' => 'magento']];\n" > "$src/app/etc/env.php"
  printf '<?php // pub/index.php sandbox\n' > "$src/pub/index.php"

  git -C "$src" add .gitignore composer.json
  git -C "$src" commit -q -m 'sandbox: initial commit'
  git -C "$src" branch stable

  printf '\n' >> "$src/composer.json"
  git -C "$src" add composer.json
  git -C "$src" commit -q -m 'sandbox: second commit'
}

run_wt() {
  if OUTPUT="$("$SANDBOX/bin/wt" "$@" 2>&1)"; then
    STATUS=0
  else
    STATUS=$?
  fi
  return 0
}

reset_calls() {
  rm -f "$WT_LOG_DIR/compose.log" "$WT_LOG_DIR/magento.log" "$WT_LOG_DIR/docker.log"
}

set_docker_online() {
  : > "$WT_DOCKER_ONLINE"
}

set_docker_offline() {
  rm -f "$WT_DOCKER_ONLINE"
}

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

test_help_lists_commands() {
  sandbox_new
  run_wt help
  assert_status 0 'help exits 0'
  assert_contains 'Usage: bin/wt <command> [args]' 'help prints the usage line'
  local cmd
  for cmd in 'init' 'create <branch>' 'use <name|path|branch>' 'doctor' 'remove <name>'; do
    assert_contains "$cmd" "help lists '$cmd'"
  done
  run_wt frobnicate
  assert_status_nonzero 'an unknown command exits non-zero'
  assert_contains 'Unknown command: frobnicate' 'an unknown command is named in the error'
  return 0
}

test_init_creates_active_src() {
  sandbox_new
  run_wt init
  assert_status 0 'init exits 0 in a valid project root'
  assert_contains 'Created .active-src -> src' 'init reports the new symlink'
  assert_symlink_to "$SANDBOX/.active-src" "$SANDBOX/src" 'init creates .active-src -> src'
  assert_dir "$SANDBOX/.worktrees" 'init creates the .worktrees directory'
  assert_equals '' "$(git -C "$SANDBOX/src" status --porcelain)" 'init leaves the main checkout untouched'
  return 0
}

test_init_is_idempotent() {
  sandbox_new
  run_wt init
  run_wt init
  assert_status 0 'a second init exits 0'
  assert_contains 'Already initialized' 'a second init reports the existing setup'
  assert_symlink_to "$SANDBOX/.active-src" "$SANDBOX/src" 'a second init keeps .active-src -> src'
  return 0
}

test_init_refuses_git_file() {
  sandbox_new
  rm -rf "$SANDBOX/src/.git"
  printf 'gitdir: /tmp/not-a-real-gitdir\n' > "$SANDBOX/src/.git"
  run_wt init
  assert_status_nonzero 'init refuses when src/.git is a file'
  assert_contains 'src/.git must be a directory' 'init explains that src/.git must be a directory'
  assert_absent "$SANDBOX/.active-src" 'a refused init does not create .active-src'
  return 0
}

test_init_refuses_regular_active_src() {
  sandbox_new
  printf 'not a symlink\n' > "$SANDBOX/.active-src"
  run_wt init
  assert_status_nonzero 'init refuses a regular .active-src file'
  assert_contains 'is not a symlink' 'init explains that .active-src must be a symlink'
  return 0
}

test_doctor_reports_ok() {
  sandbox_new
  run_wt init
  set_docker_online
  reset_calls
  run_wt doctor
  assert_status 0 'doctor exits 0 in a healthy sandbox'
  assert_contains 'Doctor: OK' 'doctor prints Doctor: OK'
  assert_not_contains 'WARN:' 'doctor prints no warnings in a healthy sandbox'
  assert_contains 'docker compose config validates' 'doctor validates compose config when Docker is online'
  return 0
}

test_list_marks_active_worktree() {
  sandbox_new
  run_wt init
  run_wt create alt
  assert_status 0 'create alt succeeds before listing'
  run_wt use alt
  assert_status 0 'use alt succeeds without Docker'
  reset_calls
  run_wt list
  assert_status 0 'list exits 0'
  assert_contains 'Active Docker source: alt' 'list reports the active worktree'
  local line stars=0 star_line=''
  while IFS= read -r line; do
    if [[ "$line" == '*'* ]]; then
      stars=$((stars + 1))
      star_line="$line"
    fi
  done <<< "$OUTPUT"
  assert_equals 1 "$stars" 'list marks exactly one worktree as active'
  assert_contains 'alt' 'the active marker is on the selected worktree' "$star_line"
  assert_file_does_not_match "$WT_LOG_DIR/compose.log" '^compose (stop|up)' 'use without Docker does not restart services'
  return 0
}

test_path_resolves_names() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  mkdir -p "$SANDBOX/.codex-worktrees"
  git -C "$SANDBOX/src" worktree add -q "$SANDBOX/.codex-worktrees/agent1" -b agent1
  local expected_one expected_agent
  expected_one="$(realpath "$SANDBOX/.worktrees/wt-one")"
  expected_agent="$(realpath "$SANDBOX/.codex-worktrees/agent1")"

  run_wt path main
  assert_status 0 'path main exits 0'
  assert_equals "$(realpath "$SANDBOX/src")" "$OUTPUT" 'path main prints src/'

  run_wt path wt-one
  assert_status 0 'path resolves a worktree name'
  assert_equals "$expected_one" "$OUTPUT" 'path prints the worktree directory'

  run_wt path local/agent1
  assert_status 0 'path resolves a local/ alias'
  assert_equals "$expected_agent" "$OUTPUT" 'the local/ alias resolves to the .codex-worktrees checkout'

  run_wt path agent1
  assert_status 0 'path resolves a branch name'
  assert_equals "$expected_agent" "$OUTPUT" 'path by branch name resolves to the same worktree'
  return 0
}

test_path_unknown_and_ambiguous_fail() {
  sandbox_new
  run_wt init
  run_wt create feature/dup
  run_wt create hotfix/dup
  run_wt path does-not-exist
  assert_status_nonzero 'path with an unknown name fails'
  assert_contains 'Unknown worktree: does-not-exist' 'the unknown name is reported'
  run_wt path dup
  assert_status_nonzero 'path with an ambiguous name fails'
  assert_contains 'matches several worktrees' 'the ambiguity is reported'
  assert_contains '.worktrees/feature/dup' 'the ambiguity lists the first match'
  assert_contains '.worktrees/hotfix/dup' 'the ambiguity lists the second match'
  run_wt use dup
  assert_status_nonzero 'use with an ambiguous name fails'
  assert_contains 'matches several worktrees' 'use reports the ambiguity too'
  return 0
}

test_use_stops_and_recreates_php_only() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  set_docker_online
  reset_calls
  run_wt use wt-one
  assert_status 0 'use switches to the worktree when Docker is online'
  assert_symlink_to "$SANDBOX/.active-src" "$(realpath "$SANDBOX/.worktrees/wt-one")" 'use repoints .active-src at the worktree'
  assert_contains 'Stopping PHP/Nginx only: app phpfpm' 'use stops only app and phpfpm'
  assert_file_line "$WT_LOG_DIR/compose.log" 'compose stop app phpfpm' 'docker compose stop app phpfpm was called'
  assert_file_line "$WT_LOG_DIR/compose.log" 'compose up -d --no-deps --force-recreate app phpfpm' 'app and phpfpm are force-recreated'
  assert_file_line_count 1 "$WT_LOG_DIR/compose.log" '^compose stop ' 'only one stop call is made'
  assert_file_line_count 1 "$WT_LOG_DIR/compose.log" '^compose up ' 'the successful switch recreates once'
  assert_file_does_not_match "$WT_LOG_DIR/compose.log" '^(compose stop|compose up) .*(db|redis|opensearch|rabbitmq|elasticsearch)' 'db/redis/search/queue services are left alone'
  assert_file_line "$WT_LOG_DIR/magento.log" 'magento cache:clean' 'use runs bin/magento cache:clean'
  assert_contains 'Active Docker source: wt-one' 'use reports the new active source'
  return 0
}

test_use_reports_already_active() {
  sandbox_new
  run_wt init
  mkdir -p "$SANDBOX/.codex-worktrees"
  git -C "$SANDBOX/src" worktree add -q "$SANDBOX/.codex-worktrees/agent1" -b agent1
  set_docker_online
  reset_calls

  run_wt use local/agent1
  assert_status 0 'use resolves the local/ alias'
  assert_symlink_to "$SANDBOX/.active-src" "$(realpath "$SANDBOX/.codex-worktrees/agent1")" 'use local/agent1 repoints .active-src'
  assert_contains 'Active Docker source: local/agent1' 'use reports the alias as the active source'

  reset_calls
  run_wt use agent1
  assert_status 0 'use by branch name exits 0 when it is already active'
  assert_contains 'Already the active Docker source' 'a repeat use reports that the source is already active'
  assert_file_does_not_match "$WT_LOG_DIR/compose.log" '^compose (stop|up)' 'a repeat use does not restart services'
  return 0
}

test_use_rolls_back_on_failure() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  set_docker_online
  reset_calls
  export WT_FAIL_UP=1
  run_wt use wt-one
  unset WT_FAIL_UP
  assert_status_nonzero 'use fails when the recreate step fails'
  assert_contains 'Switch canceled; previous source was restored' 'use reports the rollback'
  assert_symlink_to "$SANDBOX/.active-src" "$(realpath "$SANDBOX/src")" 'the failed switch restores the previous .active-src'
  assert_file_line_count 2 "$WT_LOG_DIR/compose.log" '^compose up ' 'the failed switch retries the recreate during rollback'
  assert_file_does_not_match "$WT_LOG_DIR/magento.log" 'cache:clean' 'a failed switch does not clean the Magento cache'
  return 0
}

test_create_builds_worktree() {
  sandbox_new
  run_wt init
  run_wt create feature/one
  local wt="$SANDBOX/.worktrees/feature/one"
  assert_status 0 'create exits 0'
  assert_contains 'Worktree ready:' 'create reports the new worktree'
  assert_dir "$wt" 'create builds the worktree under .worktrees/<branch>'
  assert_equals 'feature/one' "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" 'the worktree is on the new branch'
  assert_cmd_status 0 'the branch exists in the main checkout' git -C "$SANDBOX/src" show-ref --verify --quiet refs/heads/feature/one
  assert_files_equal "$SANDBOX/src/app/etc/env.php" "$wt/app/etc/env.php" 'create copies app/etc/env.php'
  assert_files_equal "$SANDBOX/src/app/bootstrap.php" "$wt/app/bootstrap.php" 'create copies app/bootstrap.php'
  assert_files_equal "$SANDBOX/src/pub/index.php" "$wt/pub/index.php" 'create copies pub/index.php'
  assert_equals '' "$(git -C "$wt" status --porcelain)" 'the prepared worktree has no dirty or untracked files'
  return 0
}

test_create_from_ref() {
  sandbox_new
  run_wt init
  local stable_sha wt
  stable_sha="$(git -C "$SANDBOX/src" rev-parse refs/heads/stable)"
  run_wt create from-stable --from stable
  wt="$SANDBOX/.worktrees/from-stable"
  assert_status 0 'create --from exits 0'
  assert_dir "$wt" 'create --from creates the worktree'
  assert_equals "$stable_sha" "$(git -C "$wt" rev-parse HEAD)" 'create --from checks out the requested ref'
  return 0
}

test_prepare_copies_missing_core_files() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  local wt="$SANDBOX/.worktrees/wt-one"
  rm -f "$wt/app/etc/env.php" "$wt/pub/index.php"
  run_wt prepare wt-one
  assert_status 0 'prepare exits 0 for an existing worktree'
  assert_files_equal "$SANDBOX/src/app/etc/env.php" "$wt/app/etc/env.php" 'prepare restores app/etc/env.php'
  assert_files_equal "$SANDBOX/src/pub/index.php" "$wt/pub/index.php" 'prepare restores pub/index.php'
  assert_equals '' "$(git -C "$wt" status --porcelain)" 'prepare leaves no untracked files behind'
  return 0
}

test_prepare_preserves_existing_files() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  local wt="$SANDBOX/.worktrees/wt-one" before after
  printf '<?php // locally customised\n' > "$wt/app/etc/env.php"
  before="$(cksum < "$wt/app/etc/env.php")"
  run_wt prepare wt-one
  after="$(cksum < "$wt/app/etc/env.php")"
  assert_status 0 'prepare exits 0 when files already exist'
  assert_equals "$before" "$after" 'prepare leaves an existing app/etc/env.php untouched'
  assert_equals '<?php // locally customised' "$(head -n 1 "$wt/app/etc/env.php")" 'the customised content survives prepare'
  return 0
}

test_remove_refuses_main_and_active() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  run_wt remove main
  assert_status_nonzero 'remove refuses the main checkout'
  assert_contains 'Cannot remove the main checkout' 'remove explains why main cannot be removed'
  assert_dir "$SANDBOX/src" 'the main checkout is still present'

  run_wt use wt-one
  assert_status 0 'use wt-one makes it active before the removal check'
  run_wt remove wt-one
  assert_status_nonzero 'remove refuses the active worktree'
  assert_contains 'Cannot remove the active Docker source' 'remove explains why the active worktree cannot be removed'
  assert_dir "$SANDBOX/.worktrees/wt-one" 'the refused removal keeps the worktree'
  return 0
}

test_remove_inactive_keeps_branch() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  local wt="$SANDBOX/.worktrees/wt-one" listed
  run_wt remove wt-one
  assert_status 0 'remove deletes an inactive worktree'
  assert_contains 'Removed worktree: wt-one (local branch kept)' 'remove reports the deletion'
  assert_absent "$wt" 'the worktree directory is gone'
  assert_cmd_status 0 'the local branch is kept' git -C "$SANDBOX/src" show-ref --verify --quiet refs/heads/wt-one
  listed="$(git -C "$SANDBOX/src" worktree list --porcelain)"
  assert_not_contains "$wt" 'the removed worktree is no longer registered' "$listed"
  return 0
}

test_status_reports_active_source() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  run_wt use wt-one
  run_wt status
  assert_status 0 'status exits 0'
  assert_contains 'Active Docker source: wt-one' 'status reports the active source'
  assert_contains 'Branch: wt-one' 'status reports the active branch'
  assert_contains 'Docker daemon is offline or inaccessible' 'status reports offline Docker'
  return 0
}

test_mounts_requires_docker() {
  sandbox_new
  run_wt init
  run_wt mounts
  assert_status_nonzero 'mounts fails when Docker is offline'
  assert_contains 'Docker daemon is offline' 'mounts explains that Docker is offline'
  set_docker_online
  reset_calls
  run_wt mounts
  assert_status 0 'mounts exits 0 when Docker is online'
  assert_file_matches "$WT_LOG_DIR/compose.log" '^compose config$' 'mounts asks compose for the rendered config'
  return 0
}

test_shell_runs_inside_worktree() {
  sandbox_new
  run_wt init
  run_wt create wt-one
  cat > "$SANDBOX/.fakebin/stub-shell" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the user's interactive shell: reports where it was started.
printf 'shell-pwd=%s\n' "$PWD"
exit 0
STUB
  chmod 755 "$SANDBOX/.fakebin/stub-shell"

  SHELL="$SANDBOX/.fakebin/stub-shell" run_wt shell wt-one
  assert_status 0 'shell exits 0 with a stub shell'
  assert_contains "shell-pwd=$(realpath "$SANDBOX/.worktrees/wt-one")" 'shell starts inside the worktree'

  run_wt shell
  assert_status_nonzero 'shell without a name fails'
  assert_contains 'Usage: bin/wt shell <name|path|branch>' 'shell without a name prints its usage'

  run_wt shell does-not-exist
  assert_status_nonzero 'shell with an unknown name fails'
  assert_contains 'Unknown worktree: does-not-exist' 'shell reports the unknown worktree'
  return 0
}

# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

run_test() {
  local fn="$1"
  if "$fn"; then
    :
  else
    fail_ "test body $fn aborted before completing"
  fi
  cleanup_sandboxes
}

printf '# wt test suite\n'
printf '# CLI: %s\n' "$CLI_SRC"

run_test test_help_lists_commands
run_test test_init_creates_active_src
run_test test_init_is_idempotent
run_test test_init_refuses_git_file
run_test test_init_refuses_regular_active_src
run_test test_doctor_reports_ok
run_test test_list_marks_active_worktree
run_test test_path_resolves_names
run_test test_path_unknown_and_ambiguous_fail
run_test test_use_stops_and_recreates_php_only
run_test test_use_reports_already_active
run_test test_use_rolls_back_on_failure
run_test test_create_builds_worktree
run_test test_create_from_ref
run_test test_prepare_copies_missing_core_files
run_test test_prepare_preserves_existing_files
run_test test_remove_refuses_main_and_active
run_test test_remove_inactive_keeps_branch
run_test test_status_reports_active_source
run_test test_mounts_requires_docker
run_test test_shell_runs_inside_worktree

printf '\n'
printf '# ------------------------------------------------------------------\n'
printf '# Summary: %d checks, %d passed, %d failed\n' "$CHECKS" "$PASSED" "$FAILED"
if [[ "$FAILED" -eq 0 ]]; then
  printf '# RESULT: PASS\n'
  exit 0
fi
printf '# RESULT: FAIL\n'
exit 1
