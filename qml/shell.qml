import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
    id: root

    property var attachmentSaveCallback: null

    Binding {
        target: Application.styleHints
        property: "colorScheme"
        value: Theme.followsSystemTheme ? Qt.Unknown
            : Theme.darkMode ? Qt.Dark : Qt.Light
        restoreMode: Binding.RestoreBindingOrValue
    }

    RpcClient { id: rpc }
    MailStore {
        id: store
        rpc: rpc
        attachmentSaveHandler: root.saveAttachment
    }
    WindowLifecycle {
        id: windowLifecycle
        window: window
        onFocusRequested: focusTimer.restart()
    }

    function saveAttachment(source, destination, callback) {
        if (saveProcess.running) {
            if (typeof callback === "function")
                callback({ message: "Another attachment is still being saved" })
            return
        }
        if (source === "" || source[0] !== "/" || destination === ""
                || destination[0] !== "/" || source.indexOf("\u0000") >= 0
                || destination.indexOf("\u0000") >= 0) {
            if (typeof callback === "function")
                callback({ message: "The attachment path is invalid" })
            return
        }
        attachmentSaveCallback = callback
        saveProcess.command = ["install", "-m", "0600", "--", source, destination]
        saveProcess.running = true
    }

    function revealWindow() {
        // A launcher can arrive while native-window close is waiting for its
        // final draft save. Reopening wins: keep the saved draft open and do
        // not let the old completion callback quit the newly mapped window.
        mainWindow.cancelWindowClose()
        windowLifecycle.reveal()
    }

    FloatingWindow {
        id: window
        visible: true
        title: store.unreadCount > 0
            ? "QuickMail (" + store.unreadCount + ")" : "QuickMail"
        implicitWidth: 1180
        implicitHeight: 760
        minimumSize: Qt.size(420, 520)
        color: Theme.canvas
        onClosed: {
            windowLifecycle.handleClosed()
            // Flush an open draft before ending the windowless UI process.
            // MainWindow emits windowCloseReady only after save-and-close has
            // completed, so closing the native window cannot race autosave.
            mainWindow.prepareWindowClose()
        }

        MainWindow {
            id: mainWindow
            anchors.fill: parent
            store: store
            onWindowCloseReady: Qt.quit()
        }
    }

    IpcHandler {
        target: "quickMail"

        readonly property bool serviceConnected: rpc.connected
        readonly property bool accountsLoaded: store.accountsLoaded
        readonly property bool offline: store.offline
        readonly property int accountCount: store.accounts.length
        readonly property string serviceError: rpc.lastError
        readonly property string serviceSocket: rpc.socketPath
        readonly property bool settingsReady: AppSettings.ready
        readonly property bool remoteContentAllowed: AppSettings.effectiveAllowRemoteContent
        readonly property bool windowMapped: window.backingWindowVisible
        readonly property bool safeToReplace: mainWindow.safeToReplace

        function show(): void {
            root.revealWindow()
        }

        function accounts(): void {
            mainWindow.cancelWindowClose()
            mainWindow.openAccountSetup(null)
            root.revealWindow()
        }

        function calendar(): void {
            mainWindow.cancelWindowClose()
            mainWindow.openCalendar()
            root.revealWindow()
        }

        function compose(uri: string): bool {
            const accepted = mainWindow.startMailto(uri)
            if (accepted) root.revealWindow()
            return accepted
        }
    }

    Process {
        id: saveProcess
        onExited: (exitCode, exitStatus) => {
            const callback = root.attachmentSaveCallback
            root.attachmentSaveCallback = null
            if (typeof callback === "function")
                callback(exitCode === 0 ? null : { message: "The attachment could not be saved" })
        }
    }

    Timer {
        id: focusTimer
        interval: 75
        repeat: false
        onTriggered: {
            if (!window.backingWindowVisible
                    || !Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) return
            Quickshell.execDetached([
                "hyprctl", "dispatch",
                "hl.dsp.focus({ window = \"title:^(QuickMail.*)$\" })"
            ])
        }
    }

    Component.onCompleted: {
        const mailtoUri = String(Quickshell.env("QUICKMAIL_MAILTO_URI") || "")
        if (mailtoUri !== "") mainWindow.startMailto(mailtoUri)
        if (String(Quickshell.env("QUICKMAIL_OPEN_ACCOUNTS") || "") === "1")
            mainWindow.openAccountSetup(null)
        if (String(Quickshell.env("QUICKMAIL_OPEN_CALENDAR") || "") === "1")
            mainWindow.openCalendar()
    }
}
