pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property bool mobile: false
    property bool shortcutScopeEnabled: visible && enabled
    property int _composeRequestGeneration: 0
    readonly property string activeAccountKey: String(store.activeAccountId || "")
    readonly property bool messageSelectionShortcutsEnabled:
        shortcutScopeEnabled && !search.activeFocus && !cursorContextMenuVisible()
    signal menuRequested()
    signal messageActivated()
    signal composeRequested(string mode, var message)

    color: Theme.canvas

    onActiveAccountKeyChanged: ++_composeRequestGeneration

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

    function selectedConversationIndex() {
        if (!store.selectedMessage) return -1
        const selectedKey = store.threadKey(store.selectedMessage)
        const conversations = Array.isArray(store.conversations)
            ? store.conversations : []
        for (let index = 0; index < conversations.length; ++index) {
            if (store.threadKey(conversations[index]) === selectedKey) return index
        }
        return -1
    }

    function selectRelativeMessage(delta) {
        const conversations = Array.isArray(store.conversations)
            ? store.conversations : []
        if (conversations.length === 0 || delta === 0) return false

        const selectedIndex = selectedConversationIndex()
        let nextIndex
        if (selectedIndex < 0) {
            nextIndex = delta > 0 ? 0 : conversations.length - 1
        } else {
            nextIndex = Math.max(0, Math.min(conversations.length - 1,
                selectedIndex + delta))
            if (nextIndex === selectedIndex) {
                messageList.currentIndex = selectedIndex
                messageList.positionViewAtIndex(selectedIndex, ListView.Contain)
                return false
            }
        }

        messageList.currentIndex = nextIndex
        messageList.positionViewAtIndex(nextIndex, ListView.Contain)
        store.openMessage(conversations[nextIndex])
        messageActivated()
        return true
    }

    function cursorContextMenuVisible() {
        if (messageList.currentIndex < 0) return false
        const row = messageList.itemAtIndex(messageList.currentIndex)
        return row ? row.contextMenuVisible === true : false
    }

    function showCursorContextMenu() {
        if (messageList.currentIndex < 0) return false
        const row = messageList.itemAtIndex(messageList.currentIndex)
        if (!row || typeof row.showContextMenu !== "function") return false
        row.showContextMenu(Math.max(12, row.width / 2),
            Math.max(12, row.height / 2))
        return true
    }

    function requestCompose(mode, message) {
        const source = message || ({})
        const generation = ++_composeRequestGeneration
        const requestedAccountId = String(store.activeAccountId || "")
        const deliver = function(detail) {
            if (generation !== root._composeRequestGeneration) return
            root.composeRequested(String(mode || "reply"),
                Object.assign({}, detail || ({}), source))
        }
        if (typeof store.requestMessageDetail !== "function") {
            deliver(null)
            return
        }
        store.requestMessageDetail(source, function(detail, error) {
            if (generation !== root._composeRequestGeneration
                    || requestedAccountId !== String(store.activeAccountId || "")) return
            if (error || !detail) {
                store.errorText = error && error.message
                    ? String(error.message)
                    : AgendaTranslations.tr("Could not open this message")
                return
            }
            const sourceId = typeof store.messageId === "function"
                ? String(store.messageId(source) || "") : String(source.id || "")
            const detailId = typeof store.messageId === "function"
                ? String(store.messageId(detail) || "") : String(detail.id || "")
            const detailAccountId = String(detail.accountId
                || detail.account_id || requestedAccountId)
            if (sourceId === "" || detailId !== sourceId
                    || (requestedAccountId !== ""
                        && detailAccountId !== requestedAccountId)) {
                store.errorText = AgendaTranslations.tr(
                    "The mail service sent an invalid response")
                return
            }
            deliver(detail)
        })
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            Layout.leftMargin: Theme.space4
            Layout.rightMargin: Theme.space4
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
            objectName: "messageSearchField"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space4
            Layout.rightMargin: Theme.space4
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
                padding: Theme.space3
                Repeater {
                    model: 7
                    Rectangle {
                        required property int index
                        width: parent.width - Theme.space6
                        height: 78
                        radius: Theme.radiusSmall
                        color: index % 2 === 0 ? Theme.surface : Theme.surfaceRaised
                        opacity: 0.7
                    }
                }
            }

            ListView {
                id: messageList
                objectName: "messageListView"
                anchors.fill: parent
                anchors.margins: Theme.space2
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
                    onContextRequested: {
                        messageList.currentIndex = index
                        messageList.forceActiveFocus()
                    }
                    onSelectionRequested: messageList.currentIndex = index
                    onComposeRequested: mode => root.requestCompose(mode, modelData)
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
                    if (event.key === Qt.Key_Menu
                            || (event.key === Qt.Key_F10
                                && (event.modifiers & Qt.ShiftModifier))) {
                        if (root.showCursorContextMenu()) event.accepted = true
                    } else if (event.key === Qt.Key_J) {
                        root.moveCursor(1); event.accepted = true
                    } else if (event.key === Qt.Key_K) {
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
    Shortcut {
        objectName: "nextMessageShortcut"
        sequence: "Down"
        context: Qt.WindowShortcut
        enabled: root.messageSelectionShortcutsEnabled
            && store.conversations.length > 0
        onActivated: root.selectRelativeMessage(1)
    }
    Shortcut {
        objectName: "previousMessageShortcut"
        sequence: "Up"
        context: Qt.WindowShortcut
        enabled: root.messageSelectionShortcutsEnabled
            && store.conversations.length > 0
        onActivated: root.selectRelativeMessage(-1)
    }
}
