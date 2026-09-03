#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
import_path=${QML_IMPORT_PATH:-/usr/lib/qt6/qml}
host_import_path=$project_dir/qml/host/quickshell
test_config_dir=$(mktemp -d "${TMPDIR:-/tmp}/quickmail-qml-config.XXXXXX")
test_runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/quickmail-qml-runtime.XXXXXX")
test_xdg_runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/quickmail-xdg-runtime.XXXXXX")
chmod 700 "$test_xdg_runtime_dir"
smoke_log=
cleanup() {
  if [ -n "$smoke_log" ]; then rm -f -- "$smoke_log"; fi
  rm -rf -- "$test_config_dir" "$test_runtime_dir" "$test_xdg_runtime_dir"
}
trap cleanup EXIT HUP INT TERM

command -v qs >/dev/null 2>&1 || {
  echo "test-qml.sh: Quickshell (qs) is required" >&2
  exit 1
}

find "$project_dir/qml" -name '*.qml' -print0 \
  | xargs -0 /usr/lib/qt6/bin/qmllint \
      -I "$import_path" -I "$project_dir/qml" \
      -I "$host_import_path" \
      --unqualified disable \
      --unused-imports disable \
      --signal-handler-parameters disable \
      -W 0

cp -R "$project_dir/qml/." "$test_runtime_dir/"
cp "$project_dir/qml/tests/SmokeHarness.qml" "$test_runtime_dir/shell.qml"

for smoke in UiSmoke StoreContractSmoke PlainTextSecuritySmoke HtmlRenderSmoke MessageTextLayoutSmoke MessageContextMenuSmoke TextSelectionContextSmoke MessageNavigationSmoke ReaderZoomSmoke ThreadPresentationSmoke ThemeModeSmoke SettingsMenuSmoke SenderAvatarSmoke ReaderAvatarLazySmoke WindowLifecycleSmoke WindowCloseGuardSmoke ComposeFormattingSmoke SettingsWriteSmoke SettingsReadSmoke CalendarPaneSmoke AgendaComposerLayoutSmoke NavigationHierarchySmoke AttachmentViewerSmoke MotionSmoke
do
  smoke_log=$(mktemp "${TMPDIR:-/tmp}/quickmail-qml-smoke.XXXXXX")
  smoke_timezone=${TZ:-UTC}
  if [ "$smoke" = CalendarPaneSmoke ]; then
    # Reproduce the UTC-midnight/local-date DST boundary used by providers.
    smoke_timezone=Europe/London
  fi
  if ! TZ="$smoke_timezone" QUICKMAIL_SMOKE="$smoke" XDG_CONFIG_HOME="$test_config_dir" \
    XDG_RUNTIME_DIR="$test_xdg_runtime_dir" QS_EVENT_LOG_DISABLE=1 \
    QML_IMPORT_PATH="$host_import_path${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
    QT_QPA_PLATFORM=offscreen timeout 10 qs --no-color \
    -p "$test_runtime_dir" >"$smoke_log" 2>&1; then
    cat "$smoke_log" >&2
    rm -f "$smoke_log"
    exit 1
  fi

  if grep -Eq 'QML SMOKE TEST FAILED|UI SMOKE TEST FAILED|STORE CONTRACT TEST FAILED|PLAIN TEXT SECURITY TEST FAILED|HTML RENDER TEST FAILED|MESSAGE TEXT LAYOUT TEST FAILED|MESSAGE CONTEXT MENU TEST FAILED|TEXT CONTEXT MENU TEST FAILED|MESSAGE NAVIGATION TEST FAILED|READER ZOOM TEST FAILED|THEME MODE TEST FAILED|SETTINGS MENU TEST FAILED|SENDER AVATAR TEST FAILED|READER AVATAR LAZY TEST FAILED|WINDOW LIFECYCLE TEST FAILED|WINDOW CLOSE GUARD TEST FAILED|COMPOSE FORMATTING TEST FAILED|SETTINGS PERSISTENCE TEST FAILED|CALENDAR PANE TEST FAILED|AGENDA COMPOSER LAYOUT TEST FAILED|ATTACHMENT VIEWER TEST FAILED|MOTION TEST FAILED|Binding loop detected|Type .* unavailable|Cannot assign to non-existent|ReferenceError:|TypeError:|RangeError:|SyntaxError:|is not defined|Failed to load component|Failed to load configuration' "$smoke_log"; then
    cat "$smoke_log" >&2
    rm -f "$smoke_log"
    exit 1
  fi
  rm -f "$smoke_log"
  smoke_log=
done
