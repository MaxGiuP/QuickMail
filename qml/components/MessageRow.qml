import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var message
    property var avatarResolver: null
    property bool selected: false
    property bool compact: false
    signal activated()
    signal starRequested()
    signal archiveRequested()
    signal trashRequested()
    signal readRequested(bool read)

    readonly property bool unread: message.unread === true || message.is_read === false || message.read === false
    readonly property bool starred: message.starred === true || message.is_starred === true
    readonly property int conversationCount: Number(message.conversationCount || 1)
    readonly property string sender: singleLine(Array.isArray(message.conversationSenders)
        ? message.conversationSenders.join(", ") : message.from_name || message.sender_name
        || (message.author && (message.author.name || message.author.address))
        || message.from || message.from_address || "Unknown sender") || "Unknown sender"
    readonly property string senderAddress: singleLine((message.author && message.author.address)
        || message.from_address || message.from || "")
    readonly property string subject: singleLine(message.subject) || "(No subject)"
    readonly property string snippet: singleLine(message.snippet || message.preview || "")
    readonly property string timestamp: singleLine(formatTimestamp(message.received_display
        || message.date_display || message.time || message.timestamp || message.received_at || ""))

    function singleLine(value) {
        return String(value === undefined || value === null ? "" : value)
            .replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
            .replace(/\s+/g, " ").trim()
    }

    function formatTimestamp(value) {
        if (!value) return ""
        const date = new Date(value)
        if (isNaN(date.getTime())) return String(value)
        const now = new Date()
        return date.toDateString() === now.toDateString()
            ? Qt.formatTime(date, "HH:mm") : Qt.formatDate(date, "d MMM")
    }

    height: compact ? 74 : 86
    clip: true
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

        SenderAvatar {
            objectName: "messageRowAvatar"
            Layout.preferredWidth: 36
            Layout.preferredHeight: 36
            Layout.alignment: Qt.AlignTop
            displayName: root.sender
            address: root.senderAddress
            avatarResolver: root.avatarResolver
            allowRemoteContent: AppSettings.effectiveAllowRemoteContent
            backgroundColor: root.unread ? Theme.accentSoft : Theme.surfaceRaised
            foregroundColor: root.unread ? Theme.accent : Theme.textSecondary
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: 0
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: 8
                Rectangle {
                    visible: root.unread
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    color: Theme.accent
                }
                Text {
                    objectName: "messageRowSender"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: root.sender
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: root.unread ? Font.Bold : Font.DemiBold
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    clip: true
                }
                Text {
                    visible: root.conversationCount > 1
                    text: root.conversationCount
                    textFormat: Text.PlainText
                    color: root.unread ? Theme.accent : Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                }
                Text {
                    text: root.timestamp
                    Layout.minimumWidth: 0
                    Layout.maximumWidth: 72
                    textFormat: Text.PlainText
                    color: root.unread ? Theme.accent : Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    clip: true
                }
            }
            Text {
                objectName: "messageRowSubject"
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: root.subject
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 12
                font.weight: root.unread ? Font.DemiBold : Font.Normal
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
                clip: true
            }
            Text {
                objectName: "messageRowSnippet"
                visible: !root.compact
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: root.snippet
                textFormat: Text.PlainText
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 11
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
                clip: true
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
