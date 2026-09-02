import QtQuick

QtObject {
    id: root

    property int timeoutMs: 10000
    readonly property bool pending: pendingState
    property bool pendingState: false

    signal timedOut()

    function begin() {
        if (pendingState) return false
        pendingState = true
        timeoutTimer.restart()
        return true
    }

    function complete() {
        if (!pendingState) return false
        pendingState = false
        timeoutTimer.stop()
        return true
    }

    function cancel() {
        if (!pendingState) return false
        pendingState = false
        timeoutTimer.stop()
        return true
    }

    property Timer timeoutTimer: Timer {
        id: timeoutTimer
        interval: Math.max(1, root.timeoutMs)
        repeat: false
        onTriggered: {
            if (!root.pendingState) return
            root.pendingState = false
            root.timedOut()
        }
    }
}
