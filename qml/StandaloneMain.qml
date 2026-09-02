import QtQuick
import QtQuick.Controls
import QuickMail.Host
import "."

ApplicationWindow {
    id: window

    objectName: "quickMailStandaloneWindow"
    visible: !quickMailCheckMode || quickMailExerciseNativeClose
    width: 1180
    height: 760
    minimumWidth: 420
    minimumHeight: 520
    title: store.unreadCount > 0
        ? "QuickMail (" + store.unreadCount + ")" : "QuickMail"
    color: Theme.canvas

    property var attachmentSaveCallback: null
    property bool exitAuthorized: false
    readonly property bool closePending: closeGuard.pending
    readonly property bool composeVisible: mainWindow.composeVisible
    readonly property string composeRecipientText: mainWindow.composeRecipientText
    readonly property bool safeToReplace: mainWindow.safeToReplace

    Binding {
        target: Application.styleHints
        property: "colorScheme"
        value: Theme.followsSystemTheme ? Qt.Unknown
            : Theme.darkMode ? Qt.Dark : Qt.Light
        restoreMode: Binding.RestoreBindingOrValue
    }

    RpcClient {
        id: rpc
        socketPathOverride: quickMailDaemonSocketOverride
    }

    MailStore {
        id: store
        rpc: rpc
        attachmentSaveHandler: window.saveAttachment
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
        exitAuthorized = false
        closeGuard.cancel()
        mainWindow.cancelWindowClose()
        visible = true
        showNormal()
        raise()
        requestActivate()
        focusTimer.restart()
    }

    function requestApplicationClose() {
        if (!closeGuard.begin()) return false
        mainWindow.prepareWindowClose()
        return true
    }

    function handleCommand(commandValue, payloadValue) {
        const command = String(commandValue || "show")
        const payload = String(payloadValue || "")
        if (command === "show") {
            revealWindow()
            return true
        }
        if (command === "accounts") {
            mainWindow.cancelWindowClose()
            mainWindow.openAccountSetup(null)
            revealWindow()
            return true
        }
        if (command === "calendar") {
            mainWindow.cancelWindowClose()
            mainWindow.openCalendar()
            revealWindow()
            return true
        }
        if (command === "compose") {
            const accepted = mainWindow.startMailto(payload)
            if (accepted) revealWindow()
            return accepted
        }
        return false
    }

    onClosing: close => {
        if (exitAuthorized) {
            close.accepted = true
            return
        }
        close.accepted = false
        requestApplicationClose()
    }

    WindowCloseGuard {
        id: closeGuard
        timeoutMs: quickMailCloseTimeoutMs
        onTimedOut: window.revealWindow()
    }

    MainWindow {
        id: mainWindow
        anchors.fill: parent
        store: store
        onWindowCloseReady: {
            closeGuard.complete()
            // QGuiApplication asks every window to close before it leaves the
            // event loop. Authorize that second close event so Qt.quit() does
            // not re-enter this save handshake indefinitely.
            window.exitAuthorized = true
            Qt.quit()
        }
        onWindowCloseFailed: window.revealWindow()
    }

    ProcessRunner {
        id: saveProcess
        onExited: (exitCode, exitStatus) => {
            const callback = window.attachmentSaveCallback
            window.attachmentSaveCallback = null
            if (typeof callback === "function")
                callback(exitCode === 0 ? null
                    : { message: "The attachment could not be saved" })
        }
    }

    ProcessRunner { id: focusProcess }

    Timer {
        id: focusTimer
        interval: 75
        repeat: false
        onTriggered: {
            if (!window.visible || !quickMailHyprlandAvailable
                    || focusProcess.running) return
            focusProcess.command = [
                "hyprctl", "dispatch",
                "focuswindow", "title:^(QuickMail.*)$"
            ]
            focusProcess.running = true
        }
    }
}
