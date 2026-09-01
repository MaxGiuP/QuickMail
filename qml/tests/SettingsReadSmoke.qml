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
