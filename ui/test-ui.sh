#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ui_binary=${QUICKMAIL_UI_BINARY:-$project_dir/target/quickmail-ui-build/quickmail-ui}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/quickmail-ui-test.XXXXXX")
primary_pid=
primary_log=$test_root/primary.log

stop_primary() {
    if [ -z "$primary_pid" ]; then
        return
    fi

    if kill -0 "$primary_pid" 2>/dev/null; then
        kill -TERM "$primary_pid" 2>/dev/null || :
    fi
    wait "$primary_pid" 2>/dev/null || :
    primary_pid=
}

cleanup() {
    status=$?
    trap - 0 1 2 15
    stop_primary
    if [ -n "$test_root" ] && [ -d "$test_root" ]; then
        rm -rf -- "$test_root"
    fi
    exit "$status"
}

trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

fail() {
    echo "test-ui.sh: $*" >&2
    exit 1
}

show_primary_log() {
    if [ -s "$primary_log" ]; then
        echo "test-ui.sh: primary process output:" >&2
        cat "$primary_log" >&2
    fi
}

expect_usage_failure() {
    case_name=$1
    shift
    case_log=$test_root/invalid-$case_name.log

    if timeout 10 "$ui_binary" "$@" >"$case_log" 2>&1; then
        fail "accepted invalid CLI combination: $case_name"
    else
        status=$?
    fi
    [ "$status" -eq 2 ] || {
        cat "$case_log" >&2
        fail "invalid CLI combination '$case_name' exited with $status instead of 2"
    }
}

route_command() {
    route_name=$1
    shift
    route_log=$test_root/route-$route_name.log

    if ! timeout 10 "$ui_binary" "$@" >"$route_log" 2>&1; then
        cat "$route_log" >&2
        show_primary_log
        fail "could not route $route_name to the primary process"
    fi
    if ! kill -0 "$primary_pid" 2>/dev/null; then
        show_primary_log
        fail "the primary process exited while routing $route_name"
    fi
}

[ -x "$ui_binary" ] || fail "standalone host is not built at $ui_binary"
command -v timeout >/dev/null 2>&1 || fail "timeout is required"
command -v stat >/dev/null 2>&1 || fail "stat is required"

install -d -m 0700 \
    "$test_root/home" \
    "$test_root/config" \
    "$test_root/state" \
    "$test_root/runtime" \
    "$test_root/cache" \
    "$test_root/data"

HOME=$test_root/home
XDG_CONFIG_HOME=$test_root/config
XDG_STATE_HOME=$test_root/state
XDG_RUNTIME_DIR=$test_root/runtime
XDG_CACHE_HOME=$test_root/cache
XDG_DATA_HOME=$test_root/data
QUICKMAIL_QML_DIR=$project_dir/qml
QT_QPA_PLATFORM=offscreen
export HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
export XDG_CACHE_HOME XDG_DATA_HOME QUICKMAIL_QML_DIR QT_QPA_PLATFORM
unset HYPRLAND_INSTANCE_SIGNATURE

check_log=$test_root/check.log
if ! timeout 15 "$ui_binary" --check >"$check_log" 2>&1; then
    cat "$check_log" >&2
    fail "--check did not load and close the standalone window successfully"
fi
[ ! -e "$XDG_RUNTIME_DIR/quickmail/ui.sock" ] \
    || fail "--check unexpectedly created the single-instance socket"

stalled_close_log=$test_root/stalled-close.log
if ! timeout 15 "$ui_binary" --check-stalled-close >"$stalled_close_log" 2>&1; then
    cat "$stalled_close_log" >&2
    fail "the stalled-draft close check did not recover successfully"
fi
[ ! -e "$XDG_RUNTIME_DIR/quickmail/ui.sock" ] \
    || fail "the stalled-draft close check unexpectedly created the UI socket"

mailto_uri='mailto:routing@example.test?subject=QuickMail%20routing&body=a%26b'
expect_usage_failure accounts-calendar --accounts --calendar
expect_usage_failure accounts-mailto --accounts "$mailto_uri"
expect_usage_failure calendar-mailto --calendar "$mailto_uri"
expect_usage_failure multiple-mailto mailto:first@example.test mailto:second@example.test

"$ui_binary" >"$primary_log" 2>&1 &
primary_pid=$!

socket_path=$XDG_RUNTIME_DIR/quickmail/ui.sock
attempt=0
while [ ! -S "$socket_path" ] && [ "$attempt" -lt 200 ]; do
    if ! kill -0 "$primary_pid" 2>/dev/null; then
        wait "$primary_pid" 2>/dev/null || :
        primary_pid=
        show_primary_log
        fail "primary process exited before creating its socket"
    fi
    sleep 0.05
    attempt=$((attempt + 1))
done
if [ ! -S "$socket_path" ]; then
    show_primary_log
    fail "primary process did not create its socket within 10 seconds"
fi

[ "$(stat -c %a "$XDG_RUNTIME_DIR/quickmail")" = 700 ] \
    || fail "QuickMail runtime directory is not mode 0700"
[ "$(stat -c %a "$socket_path")" = 700 ] \
    || fail "QuickMail UI socket is not owner-only mode 0700"

route_command show
route_command accounts --accounts
route_command calendar --calendar
route_command mailto "$mailto_uri"

stop_primary

echo "test-ui.sh: standalone host integration checks passed"
