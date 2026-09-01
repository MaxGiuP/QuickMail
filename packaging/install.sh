#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${PREFIX:-"$HOME/.local"}
destdir=${DESTDIR:-}
skip_build=${QUICKMAIL_SKIP_BUILD:-0}

case "$prefix" in
    /*) ;;
    *)
        echo "install.sh: PREFIX must be an absolute path" >&2
        exit 2
        ;;
esac
while [ "$prefix" != / ] && [ "${prefix%/}" != "$prefix" ]
do
    prefix=${prefix%/}
done
carriage_return=$(printf '\r')
case "$prefix" in
    *'
'*|*"$carriage_return"*)
        echo "install.sh: PREFIX must not contain line breaks" >&2
        exit 2
        ;;
esac
if [ -n "$destdir" ]; then
    case "$destdir" in
        /*) ;;
        *)
            echo "install.sh: DESTDIR must be empty or an absolute path" >&2
            exit 2
            ;;
    esac
fi
case "$skip_build" in
    0|1) ;;
    *)
        echo "install.sh: QUICKMAIL_SKIP_BUILD must be 0 or 1" >&2
        exit 2
        ;;
esac

if [ "$skip_build" -eq 0 ]; then
    command -v cargo >/dev/null 2>&1 || {
        echo "install.sh: cargo is required" >&2
        exit 1
    }

    (CDPATH='' cd -- "$project_dir" && cargo build --release --locked \
        --package quickmaild --package quickmailctl)
fi

if [ -n "${QUICKMAIL_BINARY_DIR:-}" ]; then
    binary_dir=$QUICKMAIL_BINARY_DIR
else
    cargo_target_dir=${CARGO_TARGET_DIR:-"$project_dir/target"}
    case "$cargo_target_dir" in
        /*) ;;
        *) cargo_target_dir=$project_dir/$cargo_target_dir ;;
    esac
    binary_dir=$cargo_target_dir/release
fi

for binary in quickmaild quickmailctl
do
    if [ ! -f "$binary_dir/$binary" ] || [ ! -x "$binary_dir/$binary" ]; then
        echo "install.sh: missing executable $binary_dir/$binary" >&2
        exit 1
    fi
done

destroot=${destdir%/}
install_root=$destroot$prefix
install_root=${install_root%/}
logical_root=${prefix%/}
bin_dir=$install_root/bin
app_data_dir=$install_root/share/quickmail
data_dir=$app_data_dir/qml
application_dir=$install_root/share/applications
unit_dir=$install_root/share/systemd/user
logical_bin_dir=$logical_root/bin

install -d -m 0755 "$bin_dir" "$app_data_dir" "$application_dir" "$unit_dir"
install -m 0755 "$binary_dir/quickmaild" "$bin_dir/quickmaild"
install -m 0755 "$binary_dir/quickmailctl" "$bin_dir/quickmailctl"
install -m 0755 "$project_dir/packaging/quickmail" "$bin_dir/quickmail"

# Build the managed QML tree separately so removed source files cannot linger
# across upgrades. Only the exact quickmail/qml destination is replaced.
staged_qml=$app_data_dir/.qml.install.$$
old_qml=$app_data_dir/.qml.previous.$$
if [ -e "$staged_qml" ] || [ -L "$staged_qml" ] \
    || [ -e "$old_qml" ] || [ -L "$old_qml" ]; then
    echo "install.sh: temporary QML install path already exists" >&2
    exit 1
fi
cleanup_qml() {
    if [ -e "$staged_qml" ] || [ -L "$staged_qml" ]; then
        rm -rf -- "$staged_qml"
    fi
    if { [ -e "$old_qml" ] || [ -L "$old_qml" ]; } \
        && [ ! -e "$data_dir" ] && [ ! -L "$data_dir" ]; then
        mv -- "$old_qml" "$data_dir"
    fi
}
trap cleanup_qml 0 1 2 15
install -d -m 0755 "$staged_qml"
cp -R "$project_dir/qml/." "$staged_qml/"
find "$staged_qml" -type f -exec chmod 0644 {} +
find "$staged_qml" -type d -exec chmod 0755 {} +
if [ -e "$data_dir" ] || [ -L "$data_dir" ]; then
    mv -- "$data_dir" "$old_qml"
fi
if ! mv -- "$staged_qml" "$data_dir"; then
    echo "install.sh: could not replace the managed QML tree" >&2
    exit 1
fi
if [ -e "$old_qml" ] || [ -L "$old_qml" ]; then
    rm -rf -- "$old_qml"
fi
trap - 0 1 2 15

install -m 0644 "$project_dir/packaging/io.github.MaxGiuP.QuickMail.desktop" \
    "$application_dir/io.github.MaxGiuP.QuickMail.desktop"
escaped_bin_dir=$(printf '%s' "$logical_bin_dir" \
    | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')
while IFS= read -r service_line || [ -n "$service_line" ]
do
    case "$service_line" in
        *'@BINDIR@'*)
            before=${service_line%%@BINDIR@*}
            after=${service_line#*@BINDIR@}
            printf '%s%s%s\n' "$before" "$escaped_bin_dir" "$after"
            ;;
        *) printf '%s\n' "$service_line" ;;
    esac
done <"$project_dir/packaging/quickmaild.service" >"$unit_dir/quickmaild.service"
chmod 0644 "$unit_dir/quickmaild.service"

if [ -z "$destdir" ]; then
    if command -v update-desktop-database >/dev/null 2>&1; then
        if ! update-desktop-database "$prefix/share/applications"; then
            echo "install.sh: warning: desktop database update failed" >&2
        fi
    fi
    if command -v systemctl >/dev/null 2>&1; then
        link_service=1
        case "$prefix" in
            /usr|/usr/local) link_service=0 ;;
            "$HOME/.local")
                if [ "${XDG_DATA_HOME:-$HOME/.local/share}" = "$HOME/.local/share" ]; then
                    link_service=0
                fi
                ;;
        esac
        if [ "$link_service" -eq 1 ] \
            && ! systemctl --user link "$unit_dir/quickmaild.service"; then
            echo "install.sh: warning: could not link the user service" >&2
        fi
        if systemctl --user daemon-reload; then
            if ! systemctl --user enable --now quickmaild.service; then
                echo "install.sh: warning: installed, but the daemon could not be enabled" >&2
            fi
        else
            echo "install.sh: warning: installed, but the user service manager is unavailable" >&2
        fi
    fi
fi

if [ -n "$destdir" ]; then
    echo "Staged QuickMail under $destdir$prefix (install prefix $prefix)"
else
    echo "Installed QuickMail under $prefix"
fi
