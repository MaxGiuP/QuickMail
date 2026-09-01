pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property bool mobile: false
    signal menuRequested()
    signal messageActivated()

    color: Theme.canvas

    function displayFolderName(folder) {
        return FolderPresentation.displayName(folder)
    }

    function folderTitle() {
        const folder = store.activeFolder
        if (!folder) {
            const id = String(store.activeFolderId || "inbox")
            return displayFolderName({ id: id, name: id })
        }
        return displayFolderName(folder)
    }

    function moveCursor(delta) {
        if (messageList.count === 0) return
        messageList.currentIndex = Math.max(0,
            Math.min(messageList.count - 1, messageList.currentIndex + delta))
        messageList.positionViewAtIndex(messageList.currentIndex, ListView.Contain)
    }

    function openCursor() {
        if (messageList.currentIndex < 0
                || messageList.currentIndex >= store.conversations.length) return
        store.openMessage(store.conversations[messageList.currentIndex])
        messageActivated()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            Layout.leftMargin: 12
            Layout.rightMargin: 8
            spacing: 8
            IconButton {
                visible: root.mobile
                iconName: "menu"
                tip: "Mailboxes"
                onClicked: root.menuRequested()
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    Layout.fillWidth: true
                    text: root.folderTitle()
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 21
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    visible: store.messages.length > 0
                    text: store.conversations.length + (store.hasMore ? "+ conversations"
                        : store.conversations.length === 1 ? " conversation" : " conversations")
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }
            }
            IconButton {
                iconName: "refresh"
                tip: "Sync now (F5)"
                enabled: !store.syncing
                spinning: store.syncing
                onClicked: store.sync()
            }
            IconButton { iconName: "more"; tip: "More options" }
        }

        LightSearchField {
            id: search
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.bottomMargin: 10
            onSubmitted: query => root.store.search(query)
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            EmptyState {
                anchors.fill: parent
                visible: !store.loading && store.messages.length === 0
                iconName: store.offline ? "offline" : store.searchText !== "" ? "search" : "inbox"
                title: store.offline ? "Mail is offline"
                    : store.searchText !== "" ? "No matches" : "You’re all caught up"
                detail: store.offline ? "QuickMail will reconnect to the local mail service automatically."
                    : store.searchText !== "" ? "Try a different sender, subject, or phrase."
                    : "There are no messages in this mailbox."
            }

            Column {
                anchors.fill: parent
                visible: store.loading && store.messages.length === 0
                spacing: 4
                padding: 8
                Repeater {
                    model: 7
                    Rectangle {
                        required property int index
                        width: parent.width - 16
                        height: 78
                        radius: Theme.radiusSmall
                        color: index % 2 === 0 ? Theme.surface : Theme.surfaceRaised
                        opacity: 0.7
                    }
                }
            }

            ListView {
                id: messageList
                anchors.fill: parent
                anchors.margins: 6
                visible: store.messages.length > 0
                model: store.conversations
                spacing: 2
                clip: true
                focus: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                currentIndex: store.selectedMessage ? Math.max(0, store.conversations.findIndex(
                    message => store.threadKey(message)
                        === store.threadKey(store.selectedMessage))) : 0
                delegate: MessageRow {
                    id: row
                    required property var modelData
                    required property int index
                    width: messageList.width - (messageList.ScrollBar.vertical.visible ? 10 : 0)
                    message: modelData
                    avatarResolver: root.store
                    compact: AppSettings.compactMessageList || root.width < 330
                    selected: store.selectedMessage
                        && store.threadKey(store.selectedMessage) === store.threadKey(modelData)
                    onActivated: {
                        messageList.currentIndex = index
                        store.openMessage(modelData)
                        root.messageActivated()
                    }
                    onStarRequested: store.toggleStar(modelData)
                    onArchiveRequested: store.archive(modelData)
                    onTrashRequested: store.trash(modelData)
                    onReadRequested: read => store.markRead(modelData, read)
                }
                footer: Item {
                    width: messageList.width
                    height: store.hasMore || store.loadingMore ? 56 : 16
                    PrimaryButton {
                        anchors.centerIn: parent
                        visible: store.hasMore
                        enabled: !store.loadingMore
                        text: store.loadingMore ? "Loading…" : "Load more"
                        onClicked: store.loadMessages(false)
                    }
                }
                onAtYEndChanged: {
                    if (atYEnd && store.hasMore && !store.loadingMore) store.loadMessages(false)
                }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
                        root.moveCursor(1); event.accepted = true
                    } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
                        root.moveCursor(-1); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_O) {
                        root.openCursor(); event.accepted = true
                    } else if (event.key === Qt.Key_E && currentIndex >= 0) {
                        store.archive(store.conversations[currentIndex]); event.accepted = true
                    } else if (event.key === Qt.Key_Delete && currentIndex >= 0) {
                        store.trash(store.conversations[currentIndex]); event.accepted = true
                    } else if (event.key === Qt.Key_S && currentIndex >= 0) {
                        store.toggleStar(store.conversations[currentIndex]); event.accepted = true
                    }
                }
            }
        }
    }

    Shortcut { sequence: "Ctrl+K"; onActivated: search.forceActiveFocus() }
    Shortcut { sequence: "/"; onActivated: search.forceActiveFocus() }
    Shortcut { sequence: "F5"; onActivated: store.sync() }
}
