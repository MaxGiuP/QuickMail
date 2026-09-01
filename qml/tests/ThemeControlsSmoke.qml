import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 420
    height: 220
    color: Theme.canvas

    function expect(condition, message) {
        if (condition) return
        console.error("QML SMOKE TEST FAILED: theme controls: " + message)
        Qt.exit(1)
    }

    function colorHex(value) {
        return String(value).toLowerCase()
    }

    StyledComboBox {
        id: selector
        anchors.centerIn: parent
        width: 320
        model: [
            { text: "First account", value: "first" },
            { text: "Second account", value: "second" }
        ]
        textRole: "text"
        valueRole: "value"
    }

    Timer {
        interval: 40
        running: true
        repeat: false
        onTriggered: {
            Theme.loadSystemPalette('{"background":"#123456","primary":"#abcdef","on_primary":"#010203"}')
            window.expect(window.colorHex(Theme.canvas) === "#123456"
                    && window.colorHex(Theme.accent) === "#abcdef"
                    && window.colorHex(Theme.accentText) === "#010203",
                "system palette roles were not mapped into the QuickMail theme")
            window.expect(selector.currentValue === "first",
                "the styled selector did not retain ComboBox value semantics")
            selector.popup.open()
            popupCheck.start()
        }
    }

    Timer {
        id: popupCheck
        interval: 40
        repeat: false
        onTriggered: {
            window.expect(selector.popup.visible,
                "the styled selector popup did not open")
            window.expect(selector.count === 2,
                "the styled selector did not retain every option")
            selector.currentIndex = 1
            window.expect(selector.currentValue === "second",
                "the styled selector did not update its current value")
            selector.popup.close()
            Qt.quit()
        }
    }
}
