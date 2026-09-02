import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 760
    height: 620
    color: Theme.canvas

    property int openedCount: 0
    property int activatedCount: 0

    readonly property var messageFixture: [
        {
            id: "message-1", accountId: "account-a",
            author: { name: "First Sender", address: "first@example.test" },
            subject: "First message", snippet: "First preview", read: true
        },
        {
            id: "message-2", accountId: "account-a",
            author: { name: "Second Sender", address: "second@example.test" },
            subject: "Second message", snippet: "Second preview", read: true
        },
        {
            id: "message-3", accountId: "account-a",
            author: { name: "Third Sender", address: "third@example.test" },
            subject: "Third message", snippet: "Third preview", read: true
        }
    ]

    Component.onCompleted: AgendaTranslations.localeOverride = "en_GB"

    function expect(condition, message) {
        if (condition) return
        console.error("MESSAGE NAVIGATION TEST FAILED: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
        const resources = object.resources || []
        for (let index = 0; index < resources.length; ++index)
            descendantsWithName(resources[index], name, result)
    }

    function named(object, name) {
        const result = []
        descendantsWithName(object, name, result)
        return result.length > 0 ? result[0] : null
    }

    QtObject {
        id: store

        property var activeFolder: ({ id: "inbox", name: "Inbox" })
        property string activeFolderId: "inbox"
        property string activeAccountId: "account-a"
        property var messages: window.messageFixture
        property var conversations: messages
        property var selectedMessage: messages[0]
        property bool hasMore: false
        property bool loading: false
        property bool loadingMore: false
        property bool syncing: false
        property bool offline: false
        property string searchText: ""
        property string errorText: ""

        function messageId(message) { return String(message && message.id || "") }
        function threadKey(message) { return messageId(message) }
        function search(query) { searchText = String(query || "") }
        function loadMessages(reset) {}
        function sync() {}
        function openMessage(message) {
            selectedMessage = message
            ++window.openedCount
        }
        function toggleStar(message) {}
        function archive(message) {}
        function trash(message) {}
        function markRead(message, read) {}
    }

    MessageListPane {
        id: listPane
        anchors.fill: parent
        store: store
        shortcutScopeEnabled: true
        onMessageActivated: ++window.activatedCount
    }

    Timer {
        interval: 100
        running: true
        repeat: false
        onTriggered: {
            const messageList = window.named(listPane, "messageListView")
            const nextShortcut = window.named(listPane, "nextMessageShortcut")
            const previousShortcut = window.named(listPane,
                "previousMessageShortcut")
            const search = window.named(listPane, "messageSearchField")

            window.expect(messageList !== null && nextShortcut !== null
                    && previousShortcut !== null && search !== null,
                "message navigation controls were not created")
            window.expect(nextShortcut.enabled && previousShortcut.enabled,
                "message navigation shortcuts were not enabled")

            nextShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-2"
                    && messageList.currentIndex === 1,
                "Down did not select and open the next message")

            nextShortcut.activated()
            nextShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-3"
                    && messageList.currentIndex === 2 && window.openedCount === 2,
                "Down did not stop cleanly at the final message")

            previousShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-2"
                    && messageList.currentIndex === 1,
                "Up did not select and open the previous message")

            store.selectedMessage = null
            nextShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-1"
                    && messageList.currentIndex === 0,
                "Down did not start at the first message without a selection")

            store.selectedMessage = null
            previousShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-3"
                    && messageList.currentIndex === 2,
                "Up did not start at the final message without a selection")
            window.expect(window.openedCount === 5 && window.activatedCount === 5,
                "message shortcut activation counts were incorrect")

            search.forceActiveFocus()
            focusCheck.start()
        }
    }

    Timer {
        id: focusCheck
        interval: 30
        repeat: false
        onTriggered: {
            const nextShortcut = window.named(listPane, "nextMessageShortcut")
            const previousShortcut = window.named(listPane,
                "previousMessageShortcut")
            window.expect(!nextShortcut.enabled && !previousShortcut.enabled,
                "message shortcuts remained active while typing a search")

            listPane.visible = false
            listPane.enabled = false
            listPane.shortcutScopeEnabled = true
            hiddenListCheck.start()
        }
    }

    Timer {
        id: hiddenListCheck
        interval: 30
        repeat: false
        onTriggered: {
            const nextShortcut = window.named(listPane, "nextMessageShortcut")
            const previousShortcut = window.named(listPane,
                "previousMessageShortcut")
            window.expect(nextShortcut.enabled && previousShortcut.enabled,
                "reader navigation stopped when the mobile message list was hidden")

            previousShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-2",
                "Up did not change messages from the mobile reader state")

            listPane.shortcutScopeEnabled = false
            window.expect(!nextShortcut.enabled && !previousShortcut.enabled,
                "the parent shortcut scope did not disable message navigation")
            Qt.exit(0)
        }
    }
}
