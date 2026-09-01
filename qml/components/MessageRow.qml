import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var message
    property bool selected: false
    property bool compact: false
    signal activated()
    signal starRequested()
    signal archiveRequested()
    signal trashRequested()
    signal readRequested(bool read)

    readonly property bool unread: message.unread === true || message.is_read === false || message.read === false
    readonly property bool starred: message.starred === true || message.is_starred === true
    readonly property string sender: String(message.from_name || message.sender_name
        || (message.author && (message.author.name || message.author.address))
        || message.from || message.from_address || "Unknown sender")
    readonly property string subject: String(message.subject || "(No subject)")
    readonly property string snippet: String(message.snippet || message.preview || "")
    readonly property string timestamp: formatTimestamp(message.received_display || message.date_display
        || message.time || message.timestamp || message.received_at || "")

    function formatTimestamp(value) {
        if (!value) return ""
        const date = new Date(value)
        if (isNaN(date.getTime())) return String(value)
        const now = new Date()
        return date.toDateString() === now.toDateString()
            ? Qt.formatTime(date, "HH:mm") : Qt.formatDate(date, "d MMM")
    }

    height: compact ? 74 : 86
    radius: Theme.radiusSmall
    color: selected ? Theme.surfaceSelected
        : rowMouse.containsMouse ? Theme.surfaceHover : "transparent"

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 8
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 10

        Rectangle {
            Layout.preferredWidth: 36
            Layout.preferredHeight: 36
            Layout.alignment: Qt.AlignTop
            radius: 18
            color: root.unread ? Theme.accentSoft : Theme.surfaceRaised
            Text {
                anchors.centerIn: parent
                text: Theme.initials(root.sender)
                textFormat: Text.PlainText
                color: root.unread ? Theme.accent : Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Rectangle {
                    visible: root.unread
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    color: Theme.accent
                }
                Text {
                    Layout.fillWidth: true
                    text: root.sender
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: root.unread ? Font.Bold : Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    text: root.timestamp
                    textFormat: Text.PlainText
                    color: root.unread ? Theme.accent : Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.subject
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 12
                font.weight: root.unread ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }
            Text {
                visible: !root.compact
                Layout.fillWidth: true
                text: root.snippet
                textFormat: Text.PlainText
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        IconButton {
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32
            Layout.alignment: Qt.AlignTop
            iconName: root.starred ? "star" : "starOutline"
            emphasized: root.starred
            tip: root.starred ? "Unstar" : "Star"
            onClicked: root.starRequested()
        }
    }

    MouseArea {
        id: rowMouse
        anchors.fill: parent
        anchors.rightMargin: 40
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) contextMenu.popup()
            else root.activated()
        }
    }

    Menu {
        id: contextMenu
        MenuItem { text: root.unread ? "Mark read" : "Mark unread"; onTriggered: root.readRequested(root.unread) }
        MenuItem { text: root.starred ? "Unstar" : "Star"; onTriggered: root.starRequested() }
        MenuSeparator {}
        MenuItem { text: "Archive"; onTriggered: root.archiveRequested() }
        MenuItem { text: "Move to trash"; onTriggered: root.trashRequested() }
    }
}
