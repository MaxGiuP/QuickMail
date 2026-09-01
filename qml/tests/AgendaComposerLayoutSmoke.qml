import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 980
    height: 720
    color: Theme.canvas
    property int phase: 0
    property var destinationModel: [{
        accountId: "",
        provider: "local",
        label: "QuickMail · Local",
        calendarName: "QuickMail"
    }]

    function expect(condition, message) {
        if (condition) return
        console.error("AGENDA COMPOSER LAYOUT TEST FAILED: " + message)
        Qt.exit(1)
    }

    function nearlyEqual(actual, expected) {
        return Math.abs(actual - expected) <= 1
    }

    function checkLayout(composer, expectedWidth, expectedHeight, label) {
        expect(composer.opened, label + " task composer did not open")
        expect(composer.entryKind === "task",
            label + " composer opened with the wrong entry kind")
        expect(nearlyEqual(composer.width, expectedWidth)
                && nearlyEqual(composer.height, expectedHeight),
            label + " dialog did not use its intended size")
        expect(composer.x >= 0 && composer.y >= 0
                && composer.x + composer.width <= composer.parent.width + 1
                && composer.y + composer.height <= composer.parent.height + 1,
            label + " dialog escaped its parent bounds")
        expect(nearlyEqual(composer.contentLayoutWidth, composer.availableWidth)
                && nearlyEqual(composer.contentLayoutHeight,
                    composer.availableHeight),
            label + " dialog content did not fill the available area")
        expect(nearlyEqual(composer.formX, 14)
                && nearlyEqual(composer.formWidth,
                    composer.formViewportWidth - 28),
            label + " task form did not preserve its full-width gutters")
        expect(nearlyEqual(composer.formContentWidth,
                composer.formViewportWidth),
            label + " task viewport retained a collapsed content width")
        expect(nearlyEqual(composer.titleInputWidth, composer.formWidth),
            label + " task title input did not fill the form")
    }

    Item {
        id: desktopHost
        anchors.fill: parent
    }

    Item {
        id: compactHost
        width: 420
        height: 520
    }

    AgendaComposer {
        id: desktopComposer
        parent: desktopHost
        destinations: window.destinationModel
    }

    AgendaComposer {
        id: compactComposer
        parent: compactHost
        destinations: window.destinationModel
    }

    Component.onCompleted: desktopComposer.openFor("task", new Date(2026, 8, 1))

    Timer {
        id: settleTimer
        interval: 80
        running: true
        repeat: false
        onTriggered: {
            if (window.phase === 0) {
                window.checkLayout(desktopComposer, 560, 650, "desktop")
                desktopComposer.close()
                window.phase = 1
                compactComposer.openFor("task", new Date(2026, 8, 1))
                settleTimer.restart()
                return
            }

            window.checkLayout(compactComposer, 388, 488, "compact")
            window.expect(compactComposer.formWidth >= 359,
                "compact task form left an excessive empty gutter")
            Qt.exit(0)
        }
    }
}
