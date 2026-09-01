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
    readonly property bool threaded: conversationCount > 1
    readonly property string conversationLabel: conversationCount
        + (conversationCount === 1 ? " message" : " messages")
    readonly property string sender: singleLine(Array.isArray(message.conversationSenders)
        ? conversationSenderLabel(message.conversationSenders)
        : message.from_name || message.sender_name
        || (message.author && (message.author.name || message.author.address))
        || message.from || message.from_address || "Unknown sender") || "Unknown sender"
    readonly property string senderAddress: singleLine((message.author && message.author.address)
        || message.from_address || message.from || "")
    readonly property string subject: singleLine(message.subject) || "(No subject)"
    readonly property string snippet: singleLine(message.snippet || message.preview || "")
    readonly property string timestamp: singleLine(formatTimestamp(message.received_display
        || message.date_display || message.time || message.timestamp || message.received_at || ""))

    Accessible.role: Accessible.ListItem
    Accessible.selected: selected
    Accessible.name: (unread ? "Unread, " : "") + sender + ", " + subject
        + (threaded ? ", conversation thread, at least " + conversationLabel : "")
    Accessible.description: threaded
        ? "Conversation thread with at least " + conversationLabel
        : "Single message"
    Accessible.onPressAction: root.activated()

    function singleLine(value) {
        return String(value === undefined || value === null ? "" : value)
            .replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
            .replace(/\s+/g, " ").trim()
    }

    function conversationSenderLabel(values) {
        const senders = []
        const list = Array.isArray(values) ? values : []
        for (let index = 0; index < list.length; ++index) {
            const senderName = singleLine(list[index])
            if (senderName !== "" && senders.indexOf(senderName) < 0)
                senders.push(senderName)
        }
        if (senders.length <= 2) return senders.join(", ")
        return senders.slice(0, 2).join(", ") + " +" + (senders.length - 2)
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
        objectName: "messageRowContent"
        anchors.fill: parent
        anchors.leftMargin: Theme.space3
        anchors.rightMargin: Theme.space3
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 10

        Item {
            objectName: "messageRowAvatarStack"
            Layout.preferredWidth: 40
            Layout.preferredHeight: 40
            Layout.alignment: Qt.AlignTop

            Rectangle {
                visible: root.threaded
                x: 8
                y: 0
                width: 32
                height: 32
                radius: 16
                color: Theme.surfaceRaised
                border.width: 1
                border.color: root.unread ? Theme.accent : Theme.border
            }

            Rectangle {
                visible: root.threaded
                x: 4
                y: 4
                width: 32
                height: 32
                radius: 16
                color: Theme.surfaceHover
                border.width: 1
                border.color: root.unread ? Theme.accent : Theme.border
            }

            SenderAvatar {
                objectName: "messageRowAvatar"
                x: 0
                y: root.threaded ? 6 : 2
                width: root.threaded ? 34 : 36
                height: width
                displayName: root.sender
                address: root.senderAddress
                avatarResolver: root.avatarResolver
                allowRemoteContent: AppSettings.effectiveAllowRemoteContent
                backgroundColor: root.unread ? Theme.accentSoft : Theme.surfaceRaised
                foregroundColor: root.unread ? Theme.accent : Theme.textSecondary
            }
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
            RowLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: 8

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

                Rectangle {
                    id: threadBadge
                    objectName: "messageRowThreadBadge"
                    visible: root.threaded
                    Layout.preferredWidth: threadBadgeContent.implicitWidth + 14
                    Layout.preferredHeight: 20
                    radius: 10
                    color: root.unread ? Theme.accentSoft : Theme.surfaceRaised
                    border.width: 1
                    border.color: root.unread ? Theme.accent : Theme.border

                    Accessible.role: Accessible.StaticText
                    Accessible.name: "Conversation thread, " + root.conversationLabel

                    Row {
                        id: threadBadgeContent
                        anchors.centerIn: parent
                        spacing: 4

                        Text {
                            text: Theme.icon("thread")
                            color: root.unread ? Theme.accent : Theme.textSecondary
                            font.family: Theme.iconFont
                            font.pixelSize: 13
                        }

                        Text {
                            objectName: "messageRowThreadBadgeText"
                            text: root.compact ? String(root.conversationCount)
                                : "THREAD · " + root.conversationCount
                            textFormat: Text.PlainText
                            color: root.unread ? Theme.accent : Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            font.weight: Font.Bold
                        }
                    }
                }
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
