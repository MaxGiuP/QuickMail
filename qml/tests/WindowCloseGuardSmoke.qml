import QtQuick
import ".."

Item {
    id: root

    property int timeoutCount: 0

    function expect(condition, message) {
        if (condition) return
        console.error("WINDOW CLOSE GUARD TEST FAILED: " + message)
        Qt.exit(1)
    }

    WindowCloseGuard {
        id: guard
        timeoutMs: 80
        onTimedOut: ++root.timeoutCount
    }

    Component.onCompleted: {
        expect(guard.begin(), "the first close attempt was not accepted")
        expect(guard.pending, "an accepted close attempt was not pending")
        expect(!guard.begin(), "a second close attempt replaced the pending one")
    }

    Timer {
        interval: 160
        running: true
        repeat: false
        onTriggered: {
            root.expect(!guard.pending, "an unanswered close remained pending")
            root.expect(root.timeoutCount === 1,
                "an unanswered close did not time out exactly once")
            root.expect(guard.begin(), "close was not retryable after timeout")
            root.expect(guard.complete(), "a pending close could not complete")
            root.expect(!guard.pending, "completed close remained pending")
        }
    }

    Timer {
        interval: 300
        running: true
        repeat: false
        onTriggered: {
            root.expect(root.timeoutCount === 1,
                "a completed close later emitted a timeout")
            root.expect(guard.begin(), "close could not begin after completion")
            root.expect(guard.cancel(), "a pending close could not be cancelled")
            root.expect(!guard.pending, "cancelled close remained pending")
        }
    }

    Timer {
        interval: 440
        running: true
        repeat: false
        onTriggered: {
            root.expect(root.timeoutCount === 1,
                "a cancelled close later emitted a timeout")
            Qt.quit()
        }
    }
}
