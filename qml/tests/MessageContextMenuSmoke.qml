import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 620
    height: 520
    color: Theme.canvas

    property string openTarget: ""
    property string readTarget: ""
    property bool lastReadValue: false
    property string starTarget: ""
    property string archiveTarget: ""
    property string trashTarget: ""
    property int detailRequests: 0
    property var composeModes: []
    property var lastComposeMessage: null
    property bool deferMessageDetail: false
    property var pendingDetailCallback: null

    readonly property var summaryMessage: ({
        id: "context-target",
        accountId: "account-a",
        mailboxId: "inbox",
        author: { name: "Context Sender", address: "sender@example.test" },
        subject: "Context menu actions",
        snippet: "Summary-only preview",
        timestamp: "2026-09-01T12:00:00Z",
        read: false,
        starred: false
    })
    readonly property var fullMessage: ({
        id: "context-target",
        accountId: "account-a",
        mailboxId: "inbox",
        author: { name: "Context Sender", address: "sender@example.test" },
        to: [{ name: "Recipient", address: "recipient@example.test" }],
        cc: [{ name: "Copy", address: "copy@example.test" }],
        subject: "Context menu actions",
        bodyText: "Full message body",
        attachments: [],
        timestamp: "2026-09-01T12:00:00Z",
        read: false,
        starred: false
    })

    Component.onCompleted: AgendaTranslations.localeOverride = "en_GB"

    function expect(condition, message) {
        if (condition) return
        console.error("MESSAGE CONTEXT MENU TEST FAILED: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
        const resources = object.resources || []
        for (let resourceIndex = 0; resourceIndex < resources.length; ++resourceIndex)
            descendantsWithName(resources[resourceIndex], name, result)
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
        property var messages: [window.summaryMessage]
        property var conversations: [window.summaryMessage]
        property var selectedMessage: ({
            id: "different-message", accountId: "account-a", read: true
        })
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
        function openMessage(message) { window.openTarget = messageId(message) }
        function requestMessageDetail(message, callback) {
            ++window.detailRequests
            if (window.deferMessageDetail) {
                window.pendingDetailCallback = callback
                return
            }
            callback(window.fullMessage, null)
        }
        function markRead(message, read) {
            window.readTarget = messageId(message)
            window.lastReadValue = read
        }
        function toggleStar(message) { window.starTarget = messageId(message) }
        function archive(message) { window.archiveTarget = messageId(message) }
        function trash(message) { window.trashTarget = messageId(message) }
    }

    MessageListPane {
        id: listPane
        anchors.fill: parent
        store: store
        onComposeRequested: (mode, message) => {
            const modes = window.composeModes.slice()
            modes.push(mode)
            window.composeModes = modes
            window.lastComposeMessage = message
        }
    }

    Timer {
        interval: 120
        running: true
        repeat: false
        onTriggered: {
            const row = window.named(listPane, "messageRow")
            const handler = window.named(row, "messageRowContextHandler")
            const longPressHandler = window.named(row,
                "messageRowLongPressHandler")
            const starButton = window.named(row, "messageRowStarButton")
            const messageList = window.named(listPane, "messageListView")
            window.expect(row !== null, "message-list row was not created")
            window.expect(handler !== null
                    && (handler.acceptedButtons & Qt.RightButton) !== 0
                    && handler.parent === row,
                "right-click handler did not cover the complete message row")
            window.expect(longPressHandler !== null
                    && (longPressHandler.acceptedDevices
                        & PointerDevice.TouchScreen) !== 0,
                "touch long-press access was not available on the message row")
            messageList.currentIndex = -1
            starButton.forceActiveFocus()
            window.expect(messageList.currentIndex === 0,
                "focusing a row action did not select its keyboard context target")
            window.expect(row.contextMenuActionCount === 8,
                "context menu did not expose all eight supported actions")
            window.expect(listPane.showCursorContextMenu(),
                "keyboard context-menu entry point did not open the current row")
            openCheck.start()
        }
    }

    Timer {
        id: openCheck
        interval: 60
        repeat: false
        onTriggered: {
            const row = window.named(listPane, "messageRow")
            const menu = window.named(row, "messageActionMenu")
            window.expect(menu !== null && row.contextMenuVisible
                    && menu.title === "Message actions",
                "right click did not open the message actions menu")

            menu.openActionItem.triggered()
            menu.replyActionItem.triggered()
            menu.replyAllActionItem.triggered()
            menu.forwardActionItem.triggered()
            menu.readActionItem.triggered()
            menu.starActionItem.triggered()
            menu.archiveActionItem.triggered()
            menu.trashActionItem.triggered()

            window.expect(window.openTarget === "context-target",
                "Open targeted a different message")
            window.expect(window.composeModes.join(",")
                    === "reply,reply_all,forward" && window.detailRequests === 3,
                "compose actions were missing or did not request full message details")
            window.expect(window.lastComposeMessage
                    && window.lastComposeMessage.id === "context-target"
                    && window.lastComposeMessage.bodyText === "Full message body"
                    && window.lastComposeMessage.to.length === 1
                    && window.lastComposeMessage.cc.length === 1,
                "reply/forward received only the summary instead of the full message")
            window.expect(window.readTarget === "context-target"
                    && window.lastReadValue && window.starTarget === "context-target"
                    && window.archiveTarget === "context-target"
                    && window.trashTarget === "context-target",
                "a mutation targeted selectedMessage instead of the right-clicked row")

            AgendaTranslations.localeOverride = "de_DE"
            languageCheck.start()
        }
    }

    Timer {
        id: languageCheck
        interval: 30
        repeat: false
        onTriggered: {
            const row = window.named(listPane, "messageRow")
            const menu = window.named(row, "messageActionMenu")
            window.expect(menu.title === "E-Mail-Aktionen"
                    && menu.openActionItem.text === "Öffnen"
                    && menu.replyActionItem.text === "Antworten"
                    && menu.replyAllActionItem.text === "Allen antworten"
                    && menu.forwardActionItem.text === "Weiterleiten"
                    && menu.readActionItem.text === "Als gelesen markieren"
                    && menu.starActionItem.text === "Mit Stern markieren"
                    && menu.archiveActionItem.text === "Archivieren"
                    && menu.trashActionItem.text
                        === "In Papierkorb verschieben",
                "German context-menu actions were not fully translated")
            row.message = Object.assign({}, window.summaryMessage,
                { read: true, starred: true })
            germanStateCheck.start()
        }
    }

    Timer {
        id: germanStateCheck
        interval: 30
        repeat: false
        onTriggered: {
            const row = window.named(listPane, "messageRow")
            const menu = window.named(row, "messageActionMenu")
            window.expect(menu.readActionItem.text === "Als ungelesen markieren"
                    && menu.starActionItem.text === "Stern entfernen",
                "German read/star state labels were not translated")
            AgendaTranslations.localeOverride = "it_IT"
            row.message = window.summaryMessage
            italianCheck.start()
        }
    }

    Timer {
        id: italianCheck
        interval: 30
        repeat: false
        onTriggered: {
            const row = window.named(listPane, "messageRow")
            const menu = window.named(row, "messageActionMenu")
            window.expect(menu.title === "Azioni del messaggio"
                    && menu.openActionItem.text === "Apri"
                    && menu.replyActionItem.text === "Rispondi"
                    && menu.replyAllActionItem.text === "Rispondi a tutti"
                    && menu.forwardActionItem.text === "Inoltra"
                    && menu.readActionItem.text === "Segna come letto"
                    && menu.starActionItem.text === "Aggiungi stella"
                    && menu.archiveActionItem.text === "Archivia"
                    && menu.trashActionItem.text === "Sposta nel cestino",
                "Italian context-menu actions were not fully translated")
            row.message = Object.assign({}, window.summaryMessage,
                { read: true, starred: true })
            italianStateCheck.start()
        }
    }

    Timer {
        id: italianStateCheck
        interval: 30
        repeat: false
        onTriggered: {
            const row = window.named(listPane, "messageRow")
            const menu = window.named(row, "messageActionMenu")
            window.expect(menu.readActionItem.text === "Segna come non letto"
                    && menu.starActionItem.text === "Rimuovi stella",
                "Italian read/star state labels were not translated")
            const composeCount = window.composeModes.length
            window.deferMessageDetail = true
            listPane.requestCompose("reply", window.summaryMessage)
            const staleCallback = window.pendingDetailCallback
            store.activeAccountId = "account-b"
            store.activeAccountId = "account-a"
            staleCallback(window.fullMessage, null)
            window.expect(window.composeModes.length === composeCount,
                "an account switch did not cancel a stale compose request")
            AgendaTranslations.localeOverride = ""
            Qt.quit()
        }
    }
}
