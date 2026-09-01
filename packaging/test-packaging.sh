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
    "$project_dir/packaging/test-packaging.sh"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck \
        "$project_dir/packaging/install.sh" \
        "$project_dir/packaging/quickmail" \
        "$project_dir/packaging/test-qml.sh" \
        "$project_dir/packaging/test-packaging.sh"
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$project_dir/packaging/io.github.MaxGiuP.QuickMail.desktop"
fi

fake_bin=$test_root/fake-build
stage=$test_root/stage
install -d -m 0755 "$fake_bin"
install -m 0755 /bin/true "$fake_bin/quickmaild"
install -m 0755 /bin/true "$fake_bin/quickmailctl"

DESTDIR=$stage PREFIX=/usr QUICKMAIL_SKIP_BUILD=1 QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh"

: >"$stage/usr/share/quickmail/qml/stale-removed-file.qml"
DESTDIR=$stage PREFIX=/usr QUICKMAIL_SKIP_BUILD=1 QUICKMAIL_BINARY_DIR=$fake_bin \
    "$project_dir/packaging/install.sh" >/dev/null
[ ! -e "$stage/usr/share/quickmail/qml/stale-removed-file.qml" ] \
    || fail "reinstall retained a stale file in the managed QML tree"

for executable in quickmaild quickmailctl quickmail
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
: >"$qml/shell.qml"

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
{
    echo CALL
    printf '%s\n' "$@"
    printf 'MAILTO=%s\n' "${QUICKMAIL_MAILTO_URI:-}"
    printf 'OPEN_ACCOUNTS=%s\n' "${QUICKMAIL_OPEN_ACCOUNTS:-}"
} >>"$QUICKMAIL_TEST_QS_LOG"
if [ "${QUICKMAIL_TEST_QS_IPC_FAIL:-0}" = 1 ] && [ "${1:-}" = ipc ]; then
    exit 1
fi
if [ "${1:-}" = list ] && [ -n "${QUICKMAIL_TEST_QS_INSTANCE_PID:-}" ]; then
    printf 'Instance test:\n  Process ID: %s\n' "$QUICKMAIL_TEST_QS_INSTANCE_PID"
    exit 0
fi
if [ "${1:-}" = kill ] && [ -n "${QUICKMAIL_TEST_QS_INSTANCE_PID:-}" ]; then
    if [ -n "${QUICKMAIL_TEST_LEGACY_AUTOSAVE_MARKER:-}" ] \
        && [ ! -e "$QUICKMAIL_TEST_LEGACY_AUTOSAVE_MARKER" ]; then
        printf 'LEGACY_KILLED_EARLY\n' >>"$QUICKMAIL_TEST_QS_LOG"
    fi
    (
        sleep "${QUICKMAIL_TEST_QS_KILL_DELAY:-0}"
        kill "$QUICKMAIL_TEST_QS_INSTANCE_PID" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    exit 0
fi
if [ "${1:-}" = --no-duplicate ] \
    && [ -n "${QUICKMAIL_TEST_QS_INSTANCE_PID:-}" ] \
    && kill -0 "$QUICKMAIL_TEST_QS_INSTANCE_PID" 2>/dev/null; then
    printf 'DUPLICATE_LOCKED\n' >>"$QUICKMAIL_TEST_QS_LOG"
    exit 73
fi
if [ "${1:-}" = ipc ] && [ "${4:-}" = prop ] \
    && [ "${5:-}" = get ] && [ "${7:-}" = windowMapped ]; then
    printf '%s\n' "${QUICKMAIL_TEST_WINDOW_MAPPED:-true}"
fi
if [ "${1:-}" = ipc ] && [ "${4:-}" = prop ] \
    && [ "${5:-}" = get ] && [ "${7:-}" = safeToReplace ]; then
    if [ "${QUICKMAIL_TEST_SAFE_PROPERTY_MISSING:-0}" = 1 ]; then
        if [ -n "${QUICKMAIL_TEST_LEGACY_AUTOSAVE_MARKER:-}" ]; then
            (
                sleep "${QUICKMAIL_TEST_LEGACY_AUTOSAVE_DELAY:-1.6}"
                : >"$QUICKMAIL_TEST_LEGACY_AUTOSAVE_MARKER"
            ) >/dev/null 2>&1 &
        fi
        printf 'Property not found.\n'
        exit 0
    fi
    printf '%s\n' "${QUICKMAIL_TEST_SAFE_TO_REPLACE:-true}"
fi
exit 0
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
    "$command_dir/quickmaild" "$command_dir/quickmailctl"

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

mailto='mailto:person@example.com?subject=Hello%20world&body=a%26b'
qs_log=$test_root/qs-forward.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_QS_LOG=$qs_log \
    "$project_dir/packaging/quickmail" -- "$mailto"
grep -Fx "$mailto" "$qs_log" >/dev/null \
    || fail "mailto URI was not forwarded as one unchanged argument"
grep -Fx compose "$qs_log" >/dev/null \
    || fail "running-client compose IPC was not attempted"

accounts_log=$test_root/qs-accounts-running.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_QS_LOG=$accounts_log \
    "$project_dir/packaging/quickmail" --accounts
grep -Fx accounts "$accounts_log" >/dev/null \
    || fail "running-client accounts IPC was not attempted"

stale_log=$test_root/qs-stale-window.log
sleep 10 &
stale_instance_pid=$!
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_QS_LOG=$stale_log \
QUICKMAIL_TEST_WINDOW_MAPPED=false \
QUICKMAIL_TEST_QS_INSTANCE_PID=$stale_instance_pid \
QUICKMAIL_TEST_QS_KILL_DELAY=0.15 \
    "$project_dir/packaging/quickmail"
grep -Fx kill "$stale_log" >/dev/null \
    || fail "a windowless running instance was not stopped"
grep -Fx -- --no-duplicate "$stale_log" >/dev/null \
    || fail "a replacement UI was not launched after stale IPC success"
if grep -Fx DUPLICATE_LOCKED "$stale_log" >/dev/null; then
    fail "the replacement raced the stale process/config lock"
fi

legacy_stale_log=$test_root/qs-legacy-stale-window.log
legacy_autosave_marker=$test_root/legacy-autosave-complete
sleep 10 &
legacy_stale_instance_pid=$!
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_QS_LOG=$legacy_stale_log \
QUICKMAIL_TEST_WINDOW_MAPPED=false \
QUICKMAIL_TEST_QS_INSTANCE_PID=$legacy_stale_instance_pid \
QUICKMAIL_TEST_SAFE_PROPERTY_MISSING=1 \
QUICKMAIL_TEST_LEGACY_AUTOSAVE_MARKER=$legacy_autosave_marker \
QUICKMAIL_TEST_LEGACY_AUTOSAVE_DELAY=1.6 \
    "$project_dir/packaging/quickmail"
grep -Fx kill "$legacy_stale_log" >/dev/null \
    || fail "a legacy windowless instance was not stopped after its autosave grace"
[ -e "$legacy_autosave_marker" ] \
    || fail "the launcher did not wait for the legacy autosave grace"
if grep -Fx LEGACY_KILLED_EARLY "$legacy_stale_log" >/dev/null; then
    fail "a legacy UI was killed before its asynchronous autosave grace"
fi

accounts_log=$test_root/qs-accounts-startup.log
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_QS_LOG=$accounts_log \
QUICKMAIL_TEST_QS_IPC_FAIL=1 \
    "$project_dir/packaging/quickmail" -- --accounts
grep -Fx accounts "$accounts_log" >/dev/null \
    || fail "accounts IPC was not attempted before launching a new instance"
grep -Fx 'OPEN_ACCOUNTS=1' "$accounts_log" >/dev/null \
    || fail "new QML process did not inherit QUICKMAIL_OPEN_ACCOUNTS=1"
grep -Fx -- --no-duplicate "$accounts_log" >/dev/null \
    || fail "accounts request did not launch QML after failed IPC"
if PATH=$command_dir:/usr/bin:/bin \
    HOME=$test_root/home \
    XDG_RUNTIME_DIR=$runtime \
    QUICKMAIL_QML_DIR=$qml \
    QUICKMAIL_TEST_QS_LOG=$test_root/invalid.log \
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
QUICKMAIL_TEST_QS_LOG=$test_root/qs-unhealthy.log \
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
QUICKMAIL_TEST_QS_LOG=$test_root/qs-not-ready.log \
QUICKMAIL_TEST_SYSTEMCTL_LOG=$test_root/systemctl-not-ready.log \
QUICKMAIL_TEST_DAEMON_HEALTHY=0 \
QUICKMAIL_TEST_DAEMON_LOG=$not_ready_daemon_log \
    "$project_dir/packaging/quickmail" 2>"$not_ready_stderr"
[ ! -e "$not_ready_daemon_log" ] \
    || fail "launcher raced an unready systemd service with a fallback daemon"
grep -F 'systemd started quickmaild, but it is not ready yet' "$not_ready_stderr" >/dev/null \
    || fail "launcher did not report an unready systemd daemon"

qs_log=$test_root/qs-launch.log
daemon_log=$test_root/daemon.log
health_file=$test_root/fallback-daemon-ready
PATH=$command_dir:/usr/bin:/bin \
HOME=$test_root/home \
XDG_RUNTIME_DIR=$runtime \
XDG_DATA_HOME=$test_root/data \
XDG_STATE_HOME=$test_root/state \
XDG_CACHE_HOME=$test_root/cache \
QUICKMAIL_QML_DIR=$qml \
QUICKMAIL_TEST_QS_LOG=$qs_log \
QUICKMAIL_TEST_DAEMON_LOG=$daemon_log \
QUICKMAIL_TEST_DAEMON_HEALTHY=0 \
QUICKMAIL_TEST_HEALTH_FILE=$health_file \
QUICKMAIL_TEST_SYSTEMCTL_FAIL=1 \
QUICKMAIL_TEST_QS_IPC_FAIL=1 \
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
grep -Fx -- --no-duplicate "$qs_log" >/dev/null \
    || fail "QML application was not launched after failed IPC"
grep -Fx "MAILTO=$mailto" "$qs_log" >/dev/null \
    || fail "new QML process did not inherit the mailto URI"

if env -u XDG_RUNTIME_DIR \
    PATH="$command_dir":/usr/bin:/bin \
    QUICKMAIL_QML_DIR="$qml" \
    QUICKMAIL_TEST_QS_LOG="$test_root"/no-runtime.log \
    "$project_dir/packaging/quickmail" >/dev/null 2>&1; then
    fail "launcher accepted an unset XDG_RUNTIME_DIR"
fi

echo "Packaging tests passed"
