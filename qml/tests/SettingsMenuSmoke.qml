import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 760
    height: 480
    color: Theme.canvas
    property bool originalCompact: false
    property string originalThemeMode: "system"

    function expect(condition, message) {
        if (condition) return
        console.error("SETTINGS MENU TEST FAILED: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
    }

    function named(object, name) {
        const result = []
        descendantsWithName(object, name, result)
        return result.length > 0 ? result[0] : null
    }

    QtObject {
        id: store

        property var selectedMessage: null
        property var threadMessages: []
        property bool threadLoading: false
        property bool threadTruncated: false
        property bool readerLoading: false
        property string errorText: ""

        function messageId(message) { return "" }
        function messageBodyText(message) { return "" }
        function openThreadMessage(message) {}
        function archive(message) {}
        function toggleStar(message) {}
        function trash(message) {}
        function markRead(message, read) {}
        function downloadAttachment(attachment, open, callback) {}
        function saveAttachmentTo(source, destination, callback) {}
    }

    MessageReaderPane {
        id: reader
        anchors.fill: parent
        store: store
    }

    Timer {
        interval: 40
        running: true
        repeat: false
        onTriggered: {
            window.originalCompact = AppSettings.compactMessageList
            window.originalThemeMode = AppSettings.themeMode
            const button = window.named(reader, "readerSettingsButton")
            window.expect(button !== null, "settings button was not created")
            if (!button) return
            button.clicked()
            openedCheck.start()
        }
    }

    Timer {
        id: openedCheck
        interval: 80
        repeat: false
        onTriggered: {
            window.expect(reader.settingsMenuVisible,
                "first settings-button click did not open the menu")
            window.expect(reader.settingsMenuItemCount >= 9,
                "expanded settings menu is missing options")
            AppSettings.compactMessageList = !window.originalCompact
            window.expect(reader.compactSettingChecked === !window.originalCompact,
                "compact message-list setting was not bound to preferences")
            window.expect(reader.composeFormattingSettingChecked
                    === AppSettings.composeFormattingExpanded,
                "compose formatting setting was not bound to preferences")
            AppSettings.themeMode = "dark"
            window.expect(reader.darkModeSettingChecked
                    && !reader.systemThemeSettingChecked,
                "dark-mode override was not reflected in the settings menu")
            AppSettings.themeMode = "system"
            window.expect(reader.systemThemeSettingChecked,
                "system-theme default was not reflected in the settings menu")
            window.named(reader, "readerSettingsButton").clicked()
            closedCheck.start()
        }
    }

    Timer {
        id: closedCheck
        interval: 80
        repeat: false
        onTriggered: {
            window.expect(!reader.settingsMenuVisible,
                "second settings-button click did not close the menu")
            AppSettings.compactMessageList = window.originalCompact
            AppSettings.themeMode = window.originalThemeMode
            Qt.quit()
        }
    }
}
