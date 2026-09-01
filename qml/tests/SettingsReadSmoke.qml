import QtQuick
import ".."

Item {
    id: root
    property bool checked: false

    function fail(message) {
        console.error("SETTINGS PERSISTENCE TEST FAILED: " + message)
        Qt.exit(1)
    }

    Timer {
        interval: 20
        running: true
        repeat: true
        onTriggered: {
            if (!AppSettings.ready || root.checked) return
            root.checked = true
            if (AppSettings.allowRemoteContent !== false) {
                root.fail("remote-content choice did not survive a new process")
                return
            }
            if (AppSettings.effectiveAllowRemoteContent !== false) {
                root.fail("the effective remote-content policy ignored the saved opt-out")
                return
            }
            if (AppSettings.compactMessageList !== true) {
                root.fail("compact message-list preference did not survive a new process")
                return
            }
            if (AppSettings.readerZoomPercent !== 130) {
                root.fail("reader zoom did not survive a new process")
                return
            }
            if (AppSettings.useThemeEmailColors !== false) {
                root.fail("original-colour preference did not survive a new process")
                return
            }
            Qt.quit()
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: root.fail("settings never became ready for reading")
    }
}
