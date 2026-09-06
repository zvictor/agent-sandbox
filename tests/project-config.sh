#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/environment.sh"
source "$REPO_ROOT/bin/lib/container_runtime.sh"
source "$REPO_ROOT/bin/lib/login.sh"
source <(sed -n '/^split_csv_or_lines() {/,/^}/p' "$REPO_ROOT/bin/agent")

config_test_dir="$(mktemp -d)"
trap 'rm -rf "$config_test_dir"' EXIT
export AGENT_PROJECT_CONFIG_FILE="$config_test_dir/config.env"

fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }
assert_equal() { [ "$1" = "$2" ] || fail "$3"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected diagnostic: $2"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "unexpected diagnostic content: $2"; }

test_multiline_extra_env() (
  unset AGENT_EXTRA_ENV AGENT_TEST_AFTER CODEX_DISCORD_WEBHOOK_URL
  local original_tmpdir="${TMPDIR-}"
  cat > "$AGENT_PROJECT_CONFIG_FILE" <<'EOF'
# Project defaults remain separate from the variables below.
AGENT_EXTRA_ENV="
    TMPDIR=$PWD/.tmp

    CODEX_DISCORD_WEBHOOK_URL=https://example.invalid/hook
    OPENROUTER_API_KEY=fixture-openrouter
    MISTRAL_API_KEY=fixture-mistral
"
AGENT_TEST_AFTER=loaded
EOF
  load_project_config
  assert_equal "$AGENT_TEST_AFTER" loaded "expected config after multiline value to load"
  assert_equal "${TMPDIR-}" "$original_tmpdir" "extra env must not change host TMPDIR"
  [ -z "${CODEX_DISCORD_WEBHOOK_URL+x}" ] || fail "block body was loaded as project settings"
  ARGS=()
  append_extra_env_args
  [ "${#ARGS[@]}" = 8 ] || fail "expected exactly four extra environment arguments"
  assert_equal "${ARGS[1]}" "TMPDIR=$PWD/.tmp" "expected expanded TMPDIR"
  assert_equal "${ARGS[3]}" 'CODEX_DISCORD_WEBHOOK_URL=https://example.invalid/hook' "expected webhook"
  assert_equal "${ARGS[5]}" 'OPENROUTER_API_KEY=fixture-openrouter' "expected OpenRouter key"
  assert_equal "${ARGS[7]}" 'MISTRAL_API_KEY=fixture-mistral' "expected Mistral key"

  export AGENT_PASS_ENV_PREFIXES=AGENT_EXTRA_ENV
  ARGS=()
  append_passthrough_env_args
  [ "${#ARGS[@]}" = 2 ] || fail "multiline passthrough must remain one environment argument"
  assert_equal "${ARGS[1]}" "AGENT_EXTRA_ENV=$AGENT_EXTRA_ENV" "passthrough lost multiline data"
)

test_variable_expansion_is_data() (
  cd "$config_test_dir"
  local expanded
  export CONFIG_TEST_SOURCE=$' spaces * & | \\ = ${PWD}\nCODEX_TEST_FORGED=value\n'
  export CONFIG_TEST_SHORT=short CONFIG_TEST_SHORT_SUFFIX=long CONFIG_TEST_EMPTY=""
  unset CONFIG_TEST_MISSING
  expand_config_variables '${CONFIG_TEST_SOURCE}' expanded
  assert_equal "$expanded" "$CONFIG_TEST_SOURCE" "expanded values must preserve data and trailing newlines"
  expand_config_variables '$CONFIG_TEST_SHORT/$CONFIG_TEST_SHORT_SUFFIX/${CONFIG_TEST_EMPTY}/$CONFIG_TEST_MISSING/${CONFIG_TEST_MISSING}/$1' expanded
  assert_equal "$expanded" 'short/long//$CONFIG_TEST_MISSING/${CONFIG_TEST_MISSING}/$1' "incorrect variable boundaries or unset handling"

  export CONFIG_TEST_SOURCE='$(touch '"$config_test_dir"'/executed) `touch never` $PWD'
  expand_config_variables '$CONFIG_TEST_SOURCE' expanded
  assert_equal "$expanded" "$CONFIG_TEST_SOURCE" "injected values must not be interpreted recursively"
  [ ! -e "$config_test_dir/executed" ] || fail "expansion executed a command"
)

test_quoted_values_and_line_endings() (
  unset AGENT_TEST_SINGLE AGENT_TEST_DOUBLE AGENT_TEST_EMPTY AGENT_TEST_CRLF
  cat > "$AGENT_PROJECT_CONFIG_FILE" <<'EOF'
AGENT_TEST_SINGLE='first
# inside a value, not a comment
$PWD
last'
AGENT_TEST_DOUBLE="a \"quote\" and \\ backslash"
AGENT_TEST_EMPTY=""
EOF
  # A closing quote and the final assignment also work without a final newline.
  printf 'AGENT_TEST_CRLF="first\r\nsecond"\r\nAGENT_TEST_LAST=last' >> "$AGENT_PROJECT_CONFIG_FILE"
  unset AGENT_TEST_LAST
  load_project_config
  assert_equal "$AGENT_TEST_SINGLE" $'first\n# inside a value, not a comment\n'"$PWD"$'\nlast' "single-quoted multiline parsing failed"
  assert_equal "$AGENT_TEST_DOUBLE" 'a "quote" and \ backslash' "quoted escapes failed"
  assert_equal "$AGENT_TEST_EMPTY" '' "empty quoted value failed"
  assert_equal "$AGENT_TEST_CRLF" $'first\nsecond' "CRLF handling failed"
  assert_equal "$AGENT_TEST_LAST" last "missing final newline handling failed"

  unset AGENT_TEST_SINGLE
  printf "AGENT_TEST_SINGLE='first\nlast'" > "$AGENT_PROJECT_CONFIG_FILE"
  load_project_config
  assert_equal "$AGENT_TEST_SINGLE" $'first\nlast' "closing quote at EOF was lost"

  unset AGENT_TEST_SINGLE
  printf "AGENT_TEST_SINGLE='  first  \n  last  '\n" > "$AGENT_PROJECT_CONFIG_FILE"
  load_project_config
  assert_equal "$AGENT_TEST_SINGLE" $'  first  \n  last  ' "whitespace inside quotes was trimmed"
)

test_multiline_expansion_and_precedence() (
  unset AGENT_TEST_FIRST AGENT_TEST_REFERENCE
  export AGENT_TEST_EXISTING=host AGENT_TEST_EMPTY=""
  cat > "$AGENT_PROJECT_CONFIG_FILE" <<'EOF'
AGENT_TEST_FIRST="
one
two
"
AGENT_TEST_REFERENCE="$AGENT_TEST_FIRST"
AGENT_TEST_FIRST=ignored
AGENT_TEST_EXISTING=file
AGENT_TEST_EMPTY=file
EOF
  load_project_config
  assert_equal "$AGENT_TEST_FIRST" $'\none\ntwo\n' "multiline whitespace or first-value precedence changed"
  assert_equal "$AGENT_TEST_REFERENCE" "$AGENT_TEST_FIRST" "previous multiline config value was not expanded intact"
  assert_equal "$AGENT_TEST_EXISTING" host "environment must override file values"
  assert_equal "$AGENT_TEST_EMPTY" '' "empty environment values must override file values"
)

test_config_errors_are_redacted() (
  cd "$config_test_dir"
  local output
  local -a inputs=(
    'AGENT_TEST_VALUE="sensitive-fixture'
    'sensitive-fixture'
    'sensitive-fixture=value'
    'AGENT_TEST_VALUE="valid" sensitive-fixture'
    'AGENT_TEST_VALUE=$(touch sensitive-fixture)'
    'AGENT_TEST_VALUE=`touch sensitive-fixture`'
    'UNSUPPORTED_TEST="sensitive-fixture'
  )
  local -a messages=(
    'unterminated quoted value'
    'expected KEY=VALUE'
    'invalid config key'
    'unexpected text after closing quote'
    'command substitution is not supported'
    'command substitution is not supported'
    'unterminated quoted value'
  )
  local index
  for index in "${!inputs[@]}"; do
    printf '# comment\n%s\n' "${inputs[index]}" > "$AGENT_PROJECT_CONFIG_FILE"
    if output="$(load_project_config 2>&1)"; then
      fail "expected malformed config to fail: ${messages[index]}"
    fi
    assert_contains "$output" "$AGENT_PROJECT_CONFIG_FILE:2:"
    assert_contains "$output" "${messages[index]}"
    assert_not_contains "$output" sensitive-fixture
  done
  [ ! -e sensitive-fixture ] || fail "config parsing executed a command"
)

test_unsupported_blocks_are_consumed() (
  local output
  unset CODEX_TEST_NESTED AGENT_TEST_FOLLOWING
  cat > "$AGENT_PROJECT_CONFIG_FILE" <<'EOF'
UNSUPPORTED_TEST="
CODEX_TEST_NESTED=sensitive-fixture
"
AGENT_TEST_FOLLOWING=ok
EOF
  load_project_config 2> "$config_test_dir/unsupported.stderr"
  output="$(< "$config_test_dir/unsupported.stderr")"
  assert_contains "$output" "ignoring unsupported project config key 'UNSUPPORTED_TEST'"
  assert_not_contains "$output" sensitive-fixture
  [ -z "${CODEX_TEST_NESTED+x}" ] || fail "unsupported block contents escaped into config"
  assert_equal "$AGENT_TEST_FOLLOWING" ok "entry after unsupported block was lost"
)

test_extra_env_delimiters_and_values() (
  AGENT_EXTRA_ENV='FIRST=one, SECOND=two=three,EMPTY='
  ARGS=()
  append_extra_env_args
  [ "${#ARGS[@]}" = 6 ] || fail "comma-separated env regressed"
  assert_equal "${ARGS[3]}" 'SECOND=two=three' "equals signs must remain value data"
  assert_equal "${ARGS[5]}" 'EMPTY=' "empty assignment failed"

  AGENT_EXTRA_ENV=$'\n  LIST=one,two\nJSON={"a":1,"b":2}\r\n  SPACES=  keep spaces  \n'
  ARGS=()
  append_extra_env_args
  [ "${#ARGS[@]}" = 6 ] || fail "commas in multiline values were split"
  assert_equal "${ARGS[1]}" 'LIST=one,two' "comma value failed"
  assert_equal "${ARGS[3]}" 'JSON={"a":1,"b":2}' "JSON value failed"
  assert_equal "${ARGS[5]}" 'SPACES=  keep spaces  ' "value whitespace was changed"
)

test_extra_env_errors_are_redacted() (
  local input output
  for input in 'sensitive-fixture' '=sensitive-fixture' 'BAD-NAME=sensitive-fixture' 'BAD NAME=sensitive-fixture'; do
    if output="$(AGENT_EXTRA_ENV="$input" append_extra_env_args 2>&1)"; then
      fail "expected malformed extra env to fail"
    fi
    assert_contains "$output" 'AGENT_EXTRA_ENV entry 1: expected KEY=VALUE'
    assert_not_contains "$output" sensitive-fixture
  done
  if output="$(AGENT_EXTRA_ENV=$'\n  AGENT_RUNTIME_LEASE_ID=sensitive-fixture\n' append_extra_env_args 2>&1)"; then
    fail "indentation bypassed runtime-owned environment protection"
  fi
  assert_contains "$output" 'cannot override runtime-owned variable: AGENT_RUNTIME_LEASE_ID'
  assert_not_contains "$output" sensitive-fixture
)

test_passthrough_preserves_environment_records() (
  export AGENT_PASS_ENV_PREFIXES=CODEX_TEST_
  export CONFIG_TEST_UNFORWARDED=$'data\nCODEX_TEST_FORGED=not-a-variable'
  export CODEX_TEST_MESSAGE=$'first\nsecond\n'
  unset CODEX_TEST_FORGED
  ARGS=()
  append_passthrough_env_args
  [ "${#ARGS[@]}" = 2 ] || fail "environment value contents became additional variables"
  assert_equal "${ARGS[1]}" "CODEX_TEST_MESSAGE=$CODEX_TEST_MESSAGE" "multiline passthrough changed value bytes"
)

test_multiline_debug_logs_are_redacted() (
  local output
  AGENT_EXTRA_ENV=$'\nFIRST=sensitive-fixture\nSECOND=another-sensitive-fixture\n'
  ARGS=()
  append_extra_env_args
  ARGS+=( -e "AGENT_EXTRA_ENV=$AGENT_EXTRA_ENV" )
  output="$(log_container_run_args 2>&1)"
  assert_contains "$output" FIRST=REDACTED
  assert_contains "$output" SECOND=REDACTED
  assert_contains "$output" AGENT_EXTRA_ENV=REDACTED
  assert_not_contains "$output" sensitive-fixture
)

test_login_updates_preserve_blocks() (
  local before output
  HELPER_TMPDIR="$config_test_dir"
  cat > "$AGENT_PROJECT_CONFIG_FILE" <<'EOF'
# keep this comment
AGENT_EXTRA_ENV="
CODEX_AUTH=container-only
FOO=bar
"
CODEX_AUTH = "old
slot"
CODEX_AUTH=duplicate
EOF
  upsert_project_config_value "$AGENT_PROJECT_CONFIG_FILE" CODEX_AUTH new-slot
  unset AGENT_EXTRA_ENV CODEX_AUTH
  load_project_config
  assert_equal "$CODEX_AUTH" new-slot "login did not replace the complete logical assignment"
  assert_equal "$AGENT_EXTRA_ENV" $'\nCODEX_AUTH=container-only\nFOO=bar\n' "login changed a multiline block body"
  output="$(< "$AGENT_PROJECT_CONFIG_FILE")"
  assert_contains "$output" '# keep this comment'
  assert_not_contains "$output" duplicate

  upsert_project_config_value "$AGENT_PROJECT_CONFIG_FILE" CLAUDE_AUTH new-slot
  unset CLAUDE_AUTH
  load_project_config
  assert_equal "$CLAUDE_AUTH" new-slot "login failed to append a missing setting"

  printf 'AGENT_EXTRA_ENV="\nsensitive-fixture\n' > "$AGENT_PROJECT_CONFIG_FILE"
  before="$(< "$AGENT_PROJECT_CONFIG_FILE")"
  if output="$(upsert_project_config_value "$AGENT_PROJECT_CONFIG_FILE" CODEX_AUTH new-slot 2>&1)"; then
    fail "login accepted malformed config"
  fi
  assert_equal "$(< "$AGENT_PROJECT_CONFIG_FILE")" "$before" "failed login update modified the original config"
  assert_not_contains "$output" sensitive-fixture
)

for config_test in \
  test_multiline_extra_env \
  test_variable_expansion_is_data \
  test_quoted_values_and_line_endings \
  test_multiline_expansion_and_precedence \
  test_config_errors_are_redacted \
  test_unsupported_blocks_are_consumed \
  test_extra_env_delimiters_and_values \
  test_extra_env_errors_are_redacted \
  test_passthrough_preserves_environment_records \
  test_multiline_debug_logs_are_redacted \
  test_login_updates_preserve_blocks
do
  printf '[test] %s\n' "$config_test"
  "$config_test"
done
