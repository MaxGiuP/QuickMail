import QtQuick
import ".."

Item {
    id: root
    property bool changed: false

    function fail(message) {
        console.error("SETTINGS PERSISTENCE TEST FAILED: " + message)
        Qt.exit(1)
    }

    Timer {
        interval: 20
        running: true
        repeat: true
        onTriggered: {
            if (!AppSettings.ready || root.changed) return
            root.changed = true
            AppSettings.allowRemoteContent = false
            finishTimer.start()
        }
    }

    Timer {
        id: finishTimer
        interval: 350
        repeat: false
        onTriggered: Qt.quit()
    }

    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: root.fail("settings never became ready for writing")
    }
}
