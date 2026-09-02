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
    property int cancelledCount: 0
    property bool recordCursorChanges: false
    property var operationLog: []
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

    function record(operation) {
        operationLog = operationLog.concat([String(operation)])
    }

    function expectOperations(expected, description) {
        expect(JSON.stringify(operationLog) === JSON.stringify(expected),
            description + ": " + JSON.stringify(operationLog))
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
        property bool readerLoading: true
        property bool threadLoading: true
        property int readerGeneration: 0
        property string appliedDetailId: ""
        property var pendingLoads: []

        function messageId(message) { return String(message && message.id || "") }
        function threadKey(message) { return messageId(message) }
        function search(query) { searchText = String(query || "") }
        function loadMessages(reset) {}
        function sync() {}

        function cancelMessageLoading() {
            ++readerGeneration
            readerLoading = false
            threadLoading = false
            ++window.cancelledCount
            window.record("cancel")
        }

        function openMessage(message) {
            const id = messageId(message)
            const index = conversations.findIndex(
                candidate => messageId(candidate) === id)
            const row = window.rowForMessage(id)
            window.expect(index >= 0 && listPane.cursorIndex === index
                    && row && row.selected
                    && row.border.width === 2
                    && String(row.border.color) === String(Theme.accent),
                "email loading began before the cursor cue moved to " + id)
            window.expect(window.cancelledCount === window.openedCount + 1,
                "email loading began before the previous load was cancelled")
            window.record("open:" + id)
            selectedMessage = message
            readerLoading = true
            threadLoading = true
            pendingLoads = pendingLoads.concat([{
                id: id,
                generation: readerGeneration,
                message: message
            }])
            ++window.openedCount
        }

        function completeLoad(index) {
            const load = pendingLoads[index]
            if (!load || load.generation !== readerGeneration
                    || messageId(selectedMessage) !== load.id) {
                window.record("ignored:" + (load ? load.id : "missing"))
                return false
            }
            selectedMessage = Object.assign({}, load.message,
                { bodyText: "Loaded " + load.id })
            appliedDetailId = load.id
            readerLoading = false
            threadLoading = false
            window.record("applied:" + load.id)
            return true
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
        onMessageActivated: {
            ++window.activatedCount
            window.record("activated:" + store.messageId(store.selectedMessage))
        }
    }

    Connections {
        target: listPane
        function onCursorIndexChanged() {
            if (window.recordCursorChanges)
                window.record("cursor:" + listPane.cursorIndex)
        }
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

            window.recordCursorChanges = true
            window.operationLog = []
            window.nextShortcut.activated()
            window.expectOperations([
                "cancel", "cursor:1", "open:message-2", "activated:message-2"
            ], "Down did not cancel, move, then load immediately")
            window.expect(store.messageId(store.selectedMessage) === "message-2"
                    && window.messageList.currentIndex === 1
                    && window.openedCount === 1 && window.activatedCount === 1
                    && store.readerLoading,
                "Down did not synchronously start loading the next email")

            window.operationLog = []
            window.nextShortcut.activated()
            window.expectOperations([
                "cancel", "cursor:2", "open:message-3", "activated:message-3"
            ], "rapid Down did not replace the in-flight email immediately")
            window.expect(store.messageId(store.selectedMessage) === "message-3"
                    && window.openedCount === 2 && window.cancelledCount === 2,
                "rapid Down did not start the final email")

            window.operationLog = []
            window.nextShortcut.activated()
            window.expectOperations([], "a boundary Down restarted email loading")
            window.expect(window.openedCount === 2 && window.cancelledCount === 2,
                "a boundary Down cancelled or reopened the final email")

            window.operationLog = []
            window.expect(!store.completeLoad(0)
                    && store.messageId(store.selectedMessage) === "message-3"
                    && store.readerLoading && store.threadLoading
                    && store.appliedDetailId === "",
                "the cancelled message-2 load replaced message-3")
            window.expect(store.completeLoad(1)
                    && store.appliedDetailId === "message-3"
                    && !store.readerLoading,
                "the current message-3 load did not complete")

            window.operationLog = []
            window.previousShortcut.activated()
            window.expectOperations([
                "cancel", "cursor:1", "open:message-2", "activated:message-2"
            ], "Up did not cancel, move, then load immediately")

            window.operationLog = []
            window.nextShortcut.activated()
            window.previousShortcut.activated()
            window.expectOperations([
                "cancel", "cursor:2", "open:message-3", "activated:message-3",
                "cancel", "cursor:1", "open:message-2", "activated:message-2"
            ], "rapid reversal did not replace each in-flight load in order")
            window.expect(store.messageId(store.selectedMessage) === "message-2"
                    && window.messageList.currentIndex === 1
                    && window.openedCount === 5 && window.cancelledCount === 5,
                "a rapid direction reversal did not restart the final target")
            window.operationLog = []
            window.expect(!store.completeLoad(3)
                    && store.messageId(store.selectedMessage) === "message-2"
                    && store.readerLoading && store.threadLoading,
                "a cancelled reversal load replaced the final target")
            window.expect(store.completeLoad(4)
                    && store.appliedDetailId === "message-2"
                    && !store.readerLoading && !store.threadLoading,
                "the final reversal target did not finish loading")

            store.selectedMessage = null
            window.nextShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-1"
                    && window.messageList.currentIndex === 0,
                "Down did not start at the first email without a selection")

            store.selectedMessage = null
            window.previousShortcut.activated()
            window.expect(store.messageId(store.selectedMessage) === "message-3"
                    && window.messageList.currentIndex === 2,
                "Up did not start at the final email without a selection")
            window.expect(window.openedCount === 7
                    && window.cancelledCount === 7
                    && window.activatedCount === 7,
                "message shortcut activation counts were incorrect")

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
            window.expect(store.messageId(store.selectedMessage) === "message-2"
                    && window.messageList.currentIndex === 1
                    && window.openedCount === 8
                    && window.cancelledCount === 8
                    && window.activatedCount === 8,
                "Up did not immediately replace the mobile reader load")

            listPane.shortcutScopeEnabled = false
            window.expect(!window.nextShortcut.enabled
                    && !window.previousShortcut.enabled,
                "the parent shortcut scope did not disable message navigation")
            Qt.exit(0)
        }
    }
}
