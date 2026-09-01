import QtQuick
import ".."

Item {
    id: root

    property int focusRequests: 0

    function expect(condition, message) {
        if (condition) return
        console.error("WINDOW LIFECYCLE TEST FAILED: " + message)
        Qt.exit(1)
    }

    QtObject {
        id: fakeWindow
        property bool visible: true
        property bool backingWindowVisible: false
        property int visibleChanges: 0
        onVisibleChanged: ++visibleChanges
    }

    WindowLifecycle {
        id: lifecycle
        window: fakeWindow
        onFocusRequested: ++root.focusRequests
    }

    Component.onCompleted: {
        fakeWindow.visibleChanges = 0
        lifecycle.reveal()
        root.expect(!fakeWindow.visible,
            "a windowless instance was not hidden before remapping")
    }

    Timer {
        interval: 20
        running: true
        repeat: false
        onTriggered: {
            root.expect(fakeWindow.visible,
                "a windowless instance was not shown on the next event-loop turn")
            root.expect(fakeWindow.visibleChanges === 2,
                "reveal did not force the required false-to-true visibility edge")
            root.expect(root.focusRequests === 1,
                "the remapped window did not request focus")

            fakeWindow.backingWindowVisible = true
            lifecycle.reveal()
            root.expect(fakeWindow.visible && root.focusRequests === 2,
                "an already mapped window was not focused without hiding")

            lifecycle.handleClosed()
            root.expect(!fakeWindow.visible && !lifecycle.remapPending,
                "closing left a pending or logically visible window")
            Qt.quit()
        }
    }
}
