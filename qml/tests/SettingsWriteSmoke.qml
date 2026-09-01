import QtQuick
import ".."

Item {
    id: root
    property bool changed: false

    function fail(message) {
        console.error("SETTINGS PERSISTENCE TEST FAILED: " + message)
        Qt.exit(1)
    }

    Component.onCompleted: {
        if (!AppSettings.ready && AppSettings.effectiveAllowRemoteContent)
            root.fail("remote content was enabled before persisted settings were ready")
    }

    Timer {
        interval: 20
        running: true
        repeat: true
        onTriggered: {
            if (!AppSettings.ready || root.changed) return
            root.changed = true
            AppSettings.allowRemoteContent = false
            AppSettings.compactMessageList = true
            AppSettings.readerZoomPercent = 130
            AppSettings.useThemeEmailColors = false
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
