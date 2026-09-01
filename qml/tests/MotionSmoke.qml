import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 520
    height: 240
    color: Theme.canvas

    property int originalAnimationsOverride: -1
    property int waitAttempts: 0
    property var waitCondition: null
    property var waitContinuation: null
    property string waitFailure: ""

    function expect(condition, message) {
        if (condition) return
        console.error("MOTION TEST FAILED: " + message)
        Theme.animationsOverride = originalAnimationsOverride
        Qt.exit(1)
    }

    function nearlyEqual(actual, expected) {
        return Math.abs(Number(actual) - Number(expected)) <= 0.01
    }

    function waitFor(condition, continuation, failure) {
        waitCondition = condition
        waitContinuation = continuation
        waitFailure = failure
        waitAttempts = 0
        settlePoll.restart()
    }

    function finishWait() {
        settlePoll.stop()
        const continuation = waitContinuation
        waitCondition = null
        waitContinuation = null
        waitFailure = ""
        continuation()
    }

    function bannerShown() {
        return banner.visible && banner.enabled && banner.shown
            && nearlyEqual(banner.opacity, 1)
            && nearlyEqual(banner.implicitHeight, 40)
    }

    function bannerHidden() {
        return !banner.visible && !banner.enabled && !banner.shown
            && nearlyEqual(banner.opacity, 0)
            && nearlyEqual(banner.implicitHeight, 0)
    }

    function beginNormalMotion() {
        expect(Theme.animationsEnabled,
            "normal-motion override did not enable animations")
        expect(Theme.motionQuick > 0
                && Theme.motionFast >= Theme.motionQuick
                && Theme.motionMedium >= Theme.motionFast
                && Theme.motionSlow >= Theme.motionMedium,
            "shared motion tokens were zero or out of order")
        banner.message = "Checking for new mail…"
        waitFor(bannerShown, normalBannerShown,
            "normal-motion status banner did not settle open")
    }

    function normalBannerShown() {
        banner.message = ""
        waitFor(bannerHidden, normalBannerHidden,
            "normal-motion status banner did not settle closed")
    }

    function normalBannerHidden() {
        spinner.spinning = true
        waitFor(function() {
            return Math.abs(spinner.iconRotation) > 0.5
        }, normalSpinnerMoving,
        "normal-motion refresh icon did not rotate")
    }

    function normalSpinnerMoving() {
        Theme.animationsOverride = 0
        expect(!Theme.animationsEnabled,
            "reduced-motion override did not disable animations")
        expect(Theme.motionQuick > 0 && Theme.motionFast > 0
                && Theme.motionMedium > 0 && Theme.motionSlow > 0,
            "reduced motion incorrectly changed the raw duration tokens")
        expect(nearlyEqual(spinner.iconRotation, 0),
            "reduced motion did not immediately reset the spinning icon")

        banner.message = "Offline"
        expect(bannerShown(),
            "reduced-motion status banner did not open immediately")
        banner.message = ""
        expect(bannerHidden(),
            "reduced-motion status banner did not close immediately")

        Qt.callLater(finishReducedMotion)
    }

    function finishReducedMotion() {
        expect(nearlyEqual(spinner.iconRotation, 0),
            "disabled spinner resumed after reduced motion was selected")
        spinner.spinning = false
        Theme.animationsOverride = originalAnimationsOverride
        Qt.quit()
    }

    Column {
        anchors.centerIn: parent
        width: 460
        spacing: 16

        StatusBanner {
            id: banner
            width: parent.width
            kind: "syncing"
        }

        IconButton {
            id: spinner
            anchors.horizontalCenter: parent.horizontalCenter
            iconName: "refresh"
            tip: "Motion test"
        }
    }

    Timer {
        id: settlePoll
        interval: 10
        repeat: true
        onTriggered: {
            ++window.waitAttempts
            if (window.waitCondition && window.waitCondition()) {
                window.finishWait()
                return
            }
            if (window.waitAttempts >= 200)
                window.expect(false, window.waitFailure)
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: false
        onTriggered: window.expect(false, "motion smoke test timed out")
    }

    Component.onCompleted: {
        originalAnimationsOverride = Theme.animationsOverride
        Theme.animationsOverride = 1
        waitFor(bannerHidden, beginNormalMotion,
            "status banner did not reach its initial hidden state")
    }
}
