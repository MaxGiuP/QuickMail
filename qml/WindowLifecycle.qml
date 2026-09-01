import QtQuick

QtObject {
    id: root

    required property var window
    property bool remapPending: false
    signal focusRequested()

    function reveal() {
        if (window.backingWindowVisible === true) {
            window.visible = true
            focusRequested()
            return
        }

        // A compositor close can leave the Quickshell configuration alive
        // after its native window is gone. Force a real false -> true edge on
        // the next event-loop turn so QQuickWindow recreates the surface.
        window.visible = false
        remapPending = true
        remapTimer.restart()
    }

    function handleClosed() {
        remapPending = false
        remapTimer.stop()
        window.visible = false
    }

    property Timer remapTimer: Timer {
        id: remapTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (!root.remapPending) return
            root.remapPending = false
            root.window.visible = true
            root.focusRequested()
        }
    }
}
