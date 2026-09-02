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
    property var openedIds: []
    property int navigationStage: 0
    property var messageList: null
    property var nextShortcut: null
    property var previousShortcut: null
    property var searchField: null

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

    function rowForMessage(id) {
        const rows = []
        descendantsWithName(listPane, "messageRow", rows)
        for (let index = 0; index < rows.length; ++index) {
            if (store.messageId(rows[index].message) === id) return rows[index]
        }
        return null
    }

    function expectDeferredMove(index, loadedId, openCount, description,
            verifyCursorFrame) {
        expect(listPane.messageOpenPending,
            description + " did not queue the target email")
        expect(listPane.cursorIndex === index
                && messageList && messageList.currentIndex === index,
            description + " did not move the list cursor first")
        expect(store.messageId(store.selectedMessage) === loadedId,
            description + " loaded the target email before moving")
        expect(openedCount === openCount && activatedCount === openCount,
            description + " started loading in the key event")
        if (verifyCursorFrame !== false) {
            const targetId = store.messageId(store.conversations[index])
            Qt.callLater(function() {
                const row = window.rowForMessage(targetId)
                window.expect(row && row.selected,
                    description + " did not highlight the moved-to row before loading")
                window.expect(window.openedCount === openCount
                        && window.activatedCount === openCount,
                    description + " loaded before the cursor-only frame")
            })
        }
    }

    QtObject {
        id: store

        property var activeFolder: ({ id: "inbox", name: "Inbox" })
        property string activeFolderId: "inbox"
        property string activeAccountId: "account-a"
        property var messages: window.messageFixture
        property var conversations: messages
        property var selectedMessage: window.messageFixture[0]
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
            const id = messageId(message)
            const index = window.messageFixture.findIndex(
                candidate => messageId(candidate) === id)
            const row = window.rowForMessage(id)
            window.expect(index >= 0 && listPane.cursorIndex === index
                    && row && row.selected,
                "email loading began before the moved-to row was highlighted"
                    + " (index=" + index + ", cursor=" + listPane.cursorIndex
                    + ", row=" + (row !== null) + ", selected="
                    + (row ? row.selected : false) + ")")
            selectedMessage = message
            ++window.openedCount
            window.openedIds = window.openedIds.concat([messageId(message)])
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
        messageOpenDelayMs: 60
        onMessageActivated: ++window.activatedCount
    }

    Timer {
        interval: 100
        running: true
        repeat: false
        onTriggered: {
            window.messageList = window.named(listPane, "messageListView")
            window.nextShortcut = window.named(listPane, "nextMessageShortcut")
            window.previousShortcut = window.named(listPane,
                "previousMessageShortcut")
            window.searchField = window.named(listPane, "messageSearchField")

            window.expect(window.messageList !== null
                    && window.nextShortcut !== null
                    && window.previousShortcut !== null
                    && window.searchField !== null,
                "message navigation controls were not created")
            window.expect(window.nextShortcut.enabled
                    && window.previousShortcut.enabled,
                "message navigation shortcuts were not enabled")

            listPane.moveCursor(1)
            window.expect(listPane.cursorIndex === 1
                    && store.messageId(store.selectedMessage) === "message-1",
                "moving the cursor unexpectedly changed the opened email")
            store.messages = [window.messageFixture[1], window.messageFixture[0],
                window.messageFixture[2]]
            window.expect(listPane.cursorIndex === 0
                    && store.messageId(store.conversations[0]) === "message-2",
                "a conversation reorder did not preserve the cursor by key")
            store.selectedMessage = Object.assign({}, store.selectedMessage,
                { read: false })
            window.expect(listPane.cursorIndex === 0,
                "a same-message refresh snapped the cursor to the reader")
            store.messages = window.messageFixture.slice()
            window.expect(listPane.cursorIndex === 1,
                "a model rebuild snapped the cursor to the opened email")
            listPane.setCursor(0, store.conversations, true)

            window.nextShortcut.activated()
            window.expectDeferredMove(1, "message-1", 0, "Down")
            window.navigationStage = 1
            navigationCheck.restart()
        }
    }

    Timer {
        id: navigationCheck
        interval: 150
        repeat: false
        onTriggered: {
            if (window.navigationStage === 1) {
                window.expect(!listPane.messageOpenPending
                        && store.messageId(store.selectedMessage) === "message-2"
                        && window.messageList.currentIndex === 1
                        && window.openedCount === 1 && window.activatedCount === 1,
                    "Down did not load the moved-to email after the cursor settled")
                window.previousShortcut.activated()
                window.expectDeferredMove(0, "message-2", 1, "Up")
                window.navigationStage = 2
                restart()
                return
            }
            if (window.navigationStage === 2) {
                window.expect(!listPane.messageOpenPending
                        && store.messageId(store.selectedMessage) === "message-1"
                        && window.messageList.currentIndex === 0
                        && window.openedCount === 2 && window.activatedCount === 2,
                    "Up did not load the moved-to email after the cursor settled")
                window.nextShortcut.activated()
                window.expectDeferredMove(1, "message-1", 2,
                    "Down before a reversal", false)
                window.previousShortcut.activated()
                window.expect(!listPane.messageOpenPending
                        && window.messageList.currentIndex === 0
                        && store.messageId(store.selectedMessage) === "message-1"
                        && window.openedCount === 2 && window.activatedCount === 2,
                    "Down then Up did not cancel the redundant email load")
                window.navigationStage = 20
                restart()
                return
            }
            if (window.navigationStage === 20) {
                window.expect(!listPane.messageOpenPending
                        && store.messageId(store.selectedMessage) === "message-1"
                        && window.openedCount === 2 && window.activatedCount === 2,
                    "reversing onto the opened email loaded it again")
                window.nextShortcut.activated()
                window.expectDeferredMove(1, "message-1", 2,
                    "Down before a search", false)
                store.search("replacement query")
                window.expect(!listPane.messageOpenPending
                        && listPane.cursorIndex === -1
                        && window.openedCount === 2,
                    "changing the search did not cancel the queued email")
                window.navigationStage = 21
                restart()
                return
            }
            if (window.navigationStage === 21) {
                window.expect(window.openedCount === 2
                        && window.activatedCount === 2,
                    "a stale pre-search email loaded after the search changed")
                store.search("")
                store.selectedMessage = null
                store.selectedMessage = window.messageFixture[0]
                window.expect(listPane.cursorIndex === 0,
                    "restoring the selection did not restore its cursor")
                window.nextShortcut.activated()
                window.nextShortcut.activated()
                window.expectDeferredMove(2, "message-1", 2,
                    "rapid Down navigation")
                window.navigationStage = 3
                restart()
                return
            }
            if (window.navigationStage === 3) {
                window.expect(!listPane.messageOpenPending
                        && store.messageId(store.selectedMessage) === "message-3"
                        && window.messageList.currentIndex === 2
                        && window.openedCount === 3 && window.activatedCount === 3,
                    "rapid Down navigation did not load only its final target")
                window.expect(JSON.stringify(window.openedIds)
                        === JSON.stringify(["message-2", "message-1", "message-3"]),
                    "rapid navigation loaded an intermediate email")
                window.nextShortcut.activated()
                window.expect(!listPane.messageOpenPending
                        && window.messageList.currentIndex === 2
                        && window.openedCount === 3,
                    "Down reopened the email at the final boundary")
                window.navigationStage = 4
                restart()
                return
            }
            if (window.navigationStage === 4) {
                window.expect(window.openedCount === 3,
                    "a boundary key loaded an email after a delay")
                store.selectedMessage = null
                window.expect(window.messageList.currentIndex === -1,
                    "clearing the opened email did not clear the cursor")
                window.nextShortcut.activated()
                window.expectDeferredMove(0, "", 3,
                    "Down without an opened email")
                window.navigationStage = 5
                restart()
                return
            }
            if (window.navigationStage === 5) {
                window.expect(!listPane.messageOpenPending
                        && store.messageId(store.selectedMessage) === "message-1"
                        && window.openedCount === 4,
                    "Down did not load the first email from an empty selection")
                store.selectedMessage = null
                window.previousShortcut.activated()
                window.expectDeferredMove(2, "", 4,
                    "Up without an opened email")
                window.navigationStage = 6
                restart()
                return
            }

            window.expect(!listPane.messageOpenPending
                    && store.messageId(store.selectedMessage) === "message-3"
                    && window.openedCount === 5 && window.activatedCount === 5,
                "Up did not load the final email from an empty selection")
            window.searchField.forceActiveFocus()
            focusCheck.start()
        }
    }

    Timer {
        id: focusCheck
        interval: 30
        repeat: false
        onTriggered: {
            window.expect(!window.nextShortcut.enabled
                    && !window.previousShortcut.enabled,
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
            window.expect(window.nextShortcut.enabled
                    && window.previousShortcut.enabled,
                "reader navigation stopped when the mobile message list was hidden")

            window.previousShortcut.activated()
            window.expectDeferredMove(1, "message-3", 5,
                "Up from the mobile reader")
            hiddenOpenCheck.start()
        }
    }

    Timer {
        id: hiddenOpenCheck
        interval: 150
        repeat: false
        onTriggered: {
            window.expect(!listPane.messageOpenPending
                    && store.messageId(store.selectedMessage) === "message-2"
                    && window.openedCount === 6 && window.activatedCount === 6,
                "Up did not load after moving from the mobile reader")

            window.nextShortcut.activated()
            window.expectDeferredMove(2, "message-2", 6,
                "Down before leaving mail")
            listPane.shortcutScopeEnabled = false
            window.expect(!window.nextShortcut.enabled
                    && !window.previousShortcut.enabled,
                "the parent shortcut scope did not disable message navigation")
            window.expect(!listPane.messageOpenPending,
                "leaving mail did not cancel the queued email")
            disabledScopeCheck.start()
        }
    }

    Timer {
        id: disabledScopeCheck
        interval: 150
        repeat: false
        onTriggered: {
            window.expect(store.messageId(store.selectedMessage) === "message-2"
                    && window.openedCount === 6 && window.activatedCount === 6,
                "an email loaded after leaving the mail shortcut scope")
            Qt.exit(0)
        }
    }
}
