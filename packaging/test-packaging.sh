#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/quickmail-packaging.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fail() {
    echo "test-packaging.sh: $*" >&2
    exit 1
}

sh -n \
    "$project_dir/packaging/install.sh" \
    "$project_dir/packaging/quickmail" \
    "$project_dir/packaging/test-qml.sh" \
    "$project_dir/packaging/test-packaging.sh" \
    "$project_dir/ui/test-ui.sh"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck \
        "$project_dir/packaging/install.sh" \
        "$project_dir/packaging/quickmail" \
        "$project_dir/packaging/test-qml.sh" \
        "$project_dir/packaging/test-packaging.sh" \
        "$project_dir/ui/test-ui.sh"
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$project_dir/packaging/io.github.MaxGiuP.QuickMail.desktop"
fi
grep -Fx 'Icon=mail-unread' \
    "$project_dir/packaging/io.github.MaxGiuP.QuickMail.desktop" >/dev/null \
    || fail "desktop entry does not use the light/dark adaptive mail icon"

fake_bin=$test_root/fake-build
stage=$test_root/stage
install -d -m 0755 "$fake_bin"
install -m 0755 /bin/true "$fake_bin/quickmaild"
install -m 0755 /bin/true "$fake_bin/quickmailctl"
install -m 0755 /bin/true "$fake_bin/quickmail-ui"

DESTDIR=$stage PREFIX=/usr QUICKMAIL_SKIP_BUILD=1 QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh"

: >"$stage/usr/share/quickmail/qml/stale-removed-file.qml"
DESTDIR=$stage PREFIX=/usr QUICKMAIL_SKIP_BUILD=1 QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" >/dev/null
[ ! -e "$stage/usr/share/quickmail/qml/stale-removed-file.qml" ] \
    || fail "reinstall retained a stale file in the managed QML tree"

for executable in quickmaild quickmailctl quickmail-ui quickmail
do
    [ "$(stat -c %a "$stage/usr/bin/$executable")" = 755 ] \
        || fail "$executable was not installed with mode 0755"
done
[ "$(stat -c %a "$stage/usr/share/applications/io.github.MaxGiuP.QuickMail.desktop")" = 644 ] \
    || fail "desktop entry mode is not 0644"
[ "$(stat -c %a "$stage/usr/share/systemd/user/quickmaild.service")" = 644 ] \
    || fail "user service mode is not 0644"
grep -F 'ExecStart="/usr/bin/quickmaild"' \
    "$stage/usr/share/systemd/user/quickmaild.service" >/dev/null \
    || fail "staged service does not contain the logical-prefix daemon path"
grep -F 'Environment=TOKIO_WORKER_THREADS=4' \
    "$stage/usr/share/systemd/user/quickmaild.service" >/dev/null \
    || fail "staged service does not cap the asynchronous worker pool"
grep -F 'RestartMaxDelaySec=30s' \
    "$stage/usr/share/systemd/user/quickmaild.service" >/dev/null \
    || fail "staged service does not back off repeated daemon failures"
grep -F 'RestartSteps=5' \
    "$stage/usr/share/systemd/user/quickmaild.service" >/dev/null \
    || fail "staged service does not define bounded backoff steps"
if grep -F "$stage" "$stage/usr/share/systemd/user/quickmaild.service" >/dev/null; then
    fail "DESTDIR leaked into the installed service"
fi

percent_stage=$test_root/percent-stage
percent_prefix='/opt/QuickMail%Preview'
DESTDIR=$percent_stage PREFIX=$percent_prefix QUICKMAIL_SKIP_BUILD=1 \
QUICKMAIL_BINARY_DIR=$fake_bin "$project_dir/packaging/install.sh" >/dev/null
grep -F 'ExecStart="/opt/QuickMail%%Preview/bin/quickmaild"' \
    "$percent_stage$percent_prefix/share/systemd/user/quickmaild.service" >/dev/null \
    || fail "percent sign in PREFIX was not escaped for systemd specifier parsing"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$stage/usr/share/applications/io.github.MaxGiuP.QuickMail.desktop"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    validation_service=$test_root/quickmaild-validation.service
    sed 's|@BINDIR@/quickmaild|/bin/true|g' \
        "$project_dir/packaging/quickmaild.service" >"$validation_service"
    systemd-analyze --user verify "$validation_service"
fi

if DESTDIR=relative PREFIX=/usr QUICKMAIL_SKIP_BUILD=1 QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" >/dev/null 2>&1; then
    fail "installer accepted a relative DESTDIR"
fi

runtime=$test_root/runtime
qml=$test_root/qml
command_dir=$test_root/commands
install -d -m 0700 "$runtime"
install -d -m 0755 "$qml" "$command_dir"
: >"$qml/StandaloneMain.qml"

cat >"$command_dir/systemctl" <<'EOF'
#!/bin/sh
if [ -n "${QUICKMAIL_TEST_SYSTEMCTL_LOG:-}" ]; then
    {
        echo CALL
        printf '%s\n' "$@"
    } >>"$QUICKMAIL_TEST_SYSTEMCTL_LOG"
fi
if [ "${QUICKMAIL_TEST_SYSTEMCTL_FAIL:-0}" = 1 ]; then
    exit 1
fi
if [ "${1:-}" = --user ] && [ "${2:-}" = start ] \
    && [ -n "${QUICKMAIL_TEST_SYSTEMCTL_HEALTH_FILE:-}" ]; then
    : >"$QUICKMAIL_TEST_SYSTEMCTL_HEALTH_FILE"
fi
exit 0
EOF
cat >"$command_dir/qs" <<'EOF'
#!/bin/sh
if [ "${1:-}" = list ] && [ -n "${QUICKMAIL_TEST_QS_INSTANCE_PID:-}" ]; then
    printf 'Instance test:\n  Process ID: %s\n' "$QUICKMAIL_TEST_QS_INSTANCE_PID"
fi
EOF
cat >"$command_dir/quickmail-ui" <<'EOF'
#!/bin/sh
{
    echo CALL
    printf 'ARGC=%s\n' "$#"
    printf '%s\n' "$@"
    printf 'QML_DIR=%s\n' "${QUICKMAIL_QML_DIR:-}"
} >>"$QUICKMAIL_TEST_UI_LOG"
EOF
cat >"$command_dir/quickmaild" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$QUICKMAIL_TEST_DAEMON_LOG"
if [ -n "${QUICKMAIL_TEST_HEALTH_FILE:-}" ]; then
    : >"$QUICKMAIL_TEST_HEALTH_FILE"
fi
exit 0
EOF
cat >"$command_dir/quickmailctl" <<'EOF'
#!/bin/sh
if [ -n "${QUICKMAIL_TEST_CTL_LOG:-}" ]; then
    printf '%s\n' "$@" >>"$QUICKMAIL_TEST_CTL_LOG"
fi
if [ -n "${QUICKMAIL_TEST_HEALTH_FILE:-}" ] \
    && [ -e "$QUICKMAIL_TEST_HEALTH_FILE" ]; then
    exit 0
fi
[ "${QUICKMAIL_TEST_DAEMON_HEALTHY:-1}" = 1 ]
EOF
chmod 0755 "$command_dir/systemctl" "$command_dir/qs" \
    "$command_dir/quickmail-ui" \
    "$command_dir/quickmaild" "$command_dir/quickmailctl"

legacy_prefix=$test_root/legacy-prefix
legacy_stderr=$test_root/legacy-install.stderr
install -d -m 0755 "$legacy_prefix/share/quickmail/qml"
: >"$legacy_prefix/share/quickmail/qml/shell.qml"
sleep 10 &
legacy_ui_pid=$!
if PATH=$command_dir:/usr/bin:/bin \
    QUICKMAIL_TEST_QS_INSTANCE_PID=$legacy_ui_pid \
    PREFIX=$legacy_prefix \
    QUICKMAIL_SKIP_BUILD=1 \
    QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" 2>"$legacy_stderr"; then
    kill "$legacy_ui_pid" 2>/dev/null || true
    wait "$legacy_ui_pid" 2>/dev/null || true
    fail "installer replaced files while the legacy Quickshell UI was running"
fi
kill "$legacy_ui_pid" 2>/dev/null || true
wait "$legacy_ui_pid" 2>/dev/null || true
grep -F 'close QuickMail normally to save any draft' "$legacy_stderr" >/dev/null \
    || fail "legacy UI guard did not explain how to retry safely"
[ ! -e "$legacy_prefix/bin/quickmail-ui" ] \
    || fail "legacy UI guard ran after replacing application files"

standalone_runtime=$test_root/standalone-runtime
standalone_prefix=$test_root/standalone-prefix
standalone_stderr=$test_root/standalone-install.stderr
install -d -m 0700 "$standalone_runtime/quickmail"
sleep 10 &
standalone_ui_pid=$!
{
    printf '%s\n' "$standalone_ui_pid"
    printf '%s\n' quickmail-ui test-host test-id
} >"$standalone_runtime/quickmail/ui.lock"
if PATH=$command_dir:/usr/bin:/bin \
    XDG_RUNTIME_DIR=$standalone_runtime \
    PREFIX=$standalone_prefix \
    QUICKMAIL_SKIP_BUILD=1 \
    QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" 2>"$standalone_stderr"; then
    kill "$standalone_ui_pid" 2>/dev/null || true
    wait "$standalone_ui_pid" 2>/dev/null || true
    fail "installer replaced files while the standalone Qt UI was running"
fi
grep -F 'close QuickMail normally to save any draft' "$standalone_stderr" >/dev/null \
    || fail "standalone UI guard did not explain how to retry safely"
[ ! -e "$standalone_prefix/bin/quickmail-ui" ] \
    || fail "standalone UI guard ran after replacing application files"

standalone_stage=$test_root/standalone-stage
PATH=$command_dir:/usr/bin:/bin \
XDG_RUNTIME_DIR=$standalone_runtime \
DESTDIR=$standalone_stage \
PREFIX=/usr \
QUICKMAIL_SKIP_BUILD=1 \
QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" >/dev/null
[ -x "$standalone_stage/usr/bin/quickmail-ui" ] \
    || fail "standalone UI guard incorrectly blocked a DESTDIR install"

kill "$standalone_ui_pid" 2>/dev/null || true
wait "$standalone_ui_pid" 2>/dev/null || true

zero_lock_prefix=$test_root/zero-lock-prefix
printf '0000\n' >"$standalone_runtime/quickmail/ui.lock"
PATH=$command_dir:/usr/bin:/bin \
XDG_RUNTIME_DIR=$standalone_runtime \
PREFIX=$zero_lock_prefix \
QUICKMAIL_SKIP_BUILD=1 \
QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" >/dev/null
[ -x "$zero_lock_prefix/bin/quickmail-ui" ] \
    || fail "a zero PID in ui.lock was treated as a live standalone UI"

systemctl_log=$test_root/systemctl-install.log
live_prefix=$test_root/live-prefix
PATH=$command_dir:/usr/bin:/bin \
XDG_DATA_HOME=$test_root/nonstandard-data-home \
QUICKMAIL_TEST_SYSTEMCTL_LOG=$systemctl_log \
PREFIX=$live_prefix \
QUICKMAIL_SKIP_BUILD=1 \
QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh"
grep -Fx link "$systemctl_log" >/dev/null \
    || fail "custom-prefix service was not linked into the user manager"
grep -Fx daemon-reload "$systemctl_log" >/dev/null \
    || fail "installer did not reload the user service manager"
grep -Fx enable "$systemctl_log" >/dev/null \
    || fail "installer did not enable the daemon"
grep -Fx -- --now "$systemctl_log" >/dev/null \
    || fail "installer did not start the daemon"
grep -F "ExecStart=\"$live_prefix/bin/quickmaild\"" \
    "$live_prefix/share/systemd/user/quickmaild.service" >/dev/null \
    || fail "custom-prefix service does not use its installed daemon"

QUICKMAIL_UI_BINARY=$command_dir/quickmail-ui
export QUICKMAIL_UI_BINARY

mailto='mailto:person@example.com?subject=Hello%20world&body=a%26b'
ui_log=$test_root/ui-forward.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$ui_log \
    "$project_dir/packaging/quickmail" -- "$mailto"
grep -Fx 'ARGC=1' "$ui_log" >/dev/null \
    || fail "mailto request did not preserve the standalone UI argument count"
grep -Fx "$mailto" "$ui_log" >/dev/null \
    || fail "mailto URI was not forwarded as one unchanged argument"
grep -Fx "QML_DIR=$qml" "$ui_log" >/dev/null \
    || fail "launcher did not expose the resolved QML tree to the standalone UI"

default_log=$test_root/ui-default.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$default_log \
    "$project_dir/packaging/quickmail"
grep -Fx 'ARGC=0' "$default_log" >/dev/null \
    || fail "default launch passed unexpected standalone UI arguments"

accounts_log=$test_root/ui-accounts.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$accounts_log \
    "$project_dir/packaging/quickmail" -- --accounts
grep -Fx 'ARGC=1' "$accounts_log" >/dev/null \
    || fail "accounts request did not preserve the standalone UI argument count"
grep -Fx -- --accounts "$accounts_log" >/dev/null \
    || fail "accounts request was not forwarded to the standalone UI"

calendar_log=$test_root/ui-calendar.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$calendar_log \
    "$project_dir/packaging/quickmail" -- --calendar
grep -Fx 'ARGC=1' "$calendar_log" >/dev/null \
    || fail "calendar request did not preserve the standalone UI argument count"
grep -Fx -- --calendar "$calendar_log" >/dev/null \
    || fail "calendar request was not forwarded to the standalone UI"

if PATH=$command_dir:/usr/bin:/bin \
    HOME=$test_root/home \
    XDG_RUNTIME_DIR=$runtime \
    QUICKMAIL_QML_DIR=$qml \
    QUICKMAIL_TEST_UI_LOG=$test_root/invalid.log \
    "$project_dir/packaging/quickmail" --accounts unexpected >/dev/null 2>&1; then
    fail "launcher accepted extra arguments after --accounts"
fi

unhealthy_runtime=$test_root/unhealthy-runtime
unhealthy_systemctl_log=$test_root/systemctl-unhealthy.log
unhealthy_daemon_log=$test_root/daemon-must-not-start.log
unhealthy_health=$test_root/systemd-daemon-ready
unhealthy_ctl_log=$test_root/ctl-unhealthy.log
install -d -m 0700 "$unhealthy_runtime/quickmail"
: >"$unhealthy_runtime/quickmail/daemon.sock"
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$unhealthy_runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$test_root/ui-unhealthy.log \
QUICKMAIL_TEST_SYSTEMCTL_LOG=$unhealthy_systemctl_log \
QUICKMAIL_TEST_SYSTEMCTL_HEALTH_FILE=$unhealthy_health \
QUICKMAIL_TEST_HEALTH_FILE=$unhealthy_health \
QUICKMAIL_TEST_CTL_LOG=$unhealthy_ctl_log \
QUICKMAIL_TEST_DAEMON_HEALTHY=0 \
QUICKMAIL_TEST_DAEMON_LOG=$unhealthy_daemon_log \
    "$project_dir/packaging/quickmail"
grep -Fx start "$unhealthy_systemctl_log" >/dev/null \
    || fail "an unresponsive socket pathname was treated as a healthy daemon"
grep -Fx -- --socket "$unhealthy_ctl_log" >/dev/null \
    || fail "launcher did not probe daemon health over JSON-RPC"
grep -Fx "$unhealthy_runtime/quickmail/daemon.sock" "$unhealthy_ctl_log" >/dev/null \
    || fail "launcher health probe used the wrong socket"
grep -Fx ping "$unhealthy_ctl_log" >/dev/null \
    || fail "launcher health probe did not call ping"
[ ! -e "$unhealthy_daemon_log" ] \
    || fail "launcher raced a successfully started systemd service with a fallback daemon"

not_ready_runtime=$test_root/not-ready-runtime
not_ready_daemon_log=$test_root/not-ready-fallback-must-not-start.log
not_ready_stderr=$test_root/not-ready.stderr
install -d -m 0700 "$not_ready_runtime"
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$not_ready_runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$test_root/ui-not-ready.log \
QUICKMAIL_TEST_SYSTEMCTL_LOG=$test_root/systemctl-not-ready.log \
QUICKMAIL_TEST_DAEMON_HEALTHY=0 \
QUICKMAIL_TEST_DAEMON_LOG=$not_ready_daemon_log \
    "$project_dir/packaging/quickmail" 2>"$not_ready_stderr"
[ ! -e "$not_ready_daemon_log" ] \
    || fail "launcher raced an unready systemd service with a fallback daemon"
grep -F 'systemd started quickmaild, but it is not ready yet' "$not_ready_stderr" >/dev/null \
    || fail "launcher did not report an unready systemd daemon"

ui_log=$test_root/ui-launch.log
daemon_log=$test_root/daemon.log
health_file=$test_root/fallback-daemon-ready
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
XDG_DATA_HOME=$test_root/data \
XDG_STATE_HOME=$test_root/state \
XDG_CACHE_HOME=$test_root/cache \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_UI_LOG=$ui_log \
QUICKMAIL_TEST_DAEMON_LOG=$daemon_log \
QUICKMAIL_TEST_DAEMON_HEALTHY=0 \
QUICKMAIL_TEST_HEALTH_FILE=$health_file \
QUICKMAIL_TEST_SYSTEMCTL_FAIL=1 \
    "$project_dir/packaging/quickmail" -- "$mailto"

attempts=0
while [ ! -f "$daemon_log" ] && [ "$attempts" -lt 20 ]
do
    attempts=$((attempts + 1))
    sleep 0.05
done
[ -f "$daemon_log" ] || fail "fallback daemon was not started"
grep -Fx -- --socket "$daemon_log" >/dev/null \
    || fail "fallback daemon did not receive --socket"
grep -Fx "$runtime/quickmail/daemon.sock" "$daemon_log" >/dev/null \
    || fail "fallback daemon socket does not match the QML client"
grep -Fx "$test_root/state/quickmail/mail.db" "$daemon_log" >/dev/null \
    || fail "fallback daemon database does not match the installed service layout"
grep -Fx "$test_root/cache/quickmail/attachments" "$daemon_log" >/dev/null \
    || fail "fallback attachment cache does not match the installed service layout"
grep -Fx "$mailto" "$ui_log" >/dev/null \
    || fail "standalone UI was not launched with the mailto URI"

if env -u XDG_RUNTIME_DIR \
    PATH="$command_dir":/usr/bin:/bin \
    QUICKMAIL_QML_DIR="$qml" \
    QUICKMAIL_TEST_UI_LOG="$test_root"/no-runtime.log \
    "$project_dir/packaging/quickmail" >/dev/null 2>&1; then
    fail "launcher accepted an unset XDG_RUNTIME_DIR"
fi

if XDG_RUNTIME_DIR=relative/runtime \
    PATH="$command_dir":/usr/bin:/bin \
    HOME=$test_root/home \
    QUICKMAIL_QML_DIR="$qml" \
    QUICKMAIL_TEST_UI_LOG="$test_root"/relative-runtime.log \
    "$project_dir/packaging/quickmail" >/dev/null 2>&1; then
    fail "launcher accepted a relative XDG_RUNTIME_DIR"
fi

echo "Packaging tests passed"
