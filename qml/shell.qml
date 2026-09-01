import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
    id: root

    property var attachmentSaveCallback: null

    RpcClient { id: rpc }
    MailStore {
        id: store
        rpc: rpc
        attachmentSaveHandler: root.saveAttachment
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
        window.visible = true
        if (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) {
            Qt.callLater(function() {
                Quickshell.execDetached([
                    "hyprctl", "dispatch", "focuswindow", "title:^(QuickMail.*)$"
                ])
            })
        }
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

        MainWindow {
            id: mainWindow
            anchors.fill: parent
            store: store
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
        readonly property bool remoteContentAllowed: AppSettings.allowRemoteContent

        function show(): void {
            root.revealWindow()
        }

        function accounts(): void {
            mainWindow.openAccountSetup(null)
            root.revealWindow()
        }

        function compose(uri: string): bool {
            const accepted = store.composeMailto(uri)
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

    Component.onCompleted: {
        const mailtoUri = String(Quickshell.env("QUICKMAIL_MAILTO_URI") || "")
        if (mailtoUri !== "") store.composeMailto(mailtoUri)
        if (String(Quickshell.env("QUICKMAIL_OPEN_ACCOUNTS") || "") === "1")
            mainWindow.openAccountSetup(null)
    }
}
