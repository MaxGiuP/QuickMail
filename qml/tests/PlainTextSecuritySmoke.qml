import QtQuick
import QtQuick.Controls
import "../components"

Item {
    id: root

    width: 4200
    height: 900

    property string marker: "<b>UNTRUSTED-AUTOTEXT-MARKER</b>"
    property int protectedSurfaces: 0
    property bool failed: false

    function fail(message) {
        failed = true
        console.error("PLAIN TEXT SECURITY TEST FAILED: " + message)
    }

    function inspect(object) {
        if (!object) return
        if (object.text !== undefined
                && String(object.text).indexOf(root.marker) >= 0
                && object.textFormat !== undefined) {
            ++root.protectedSurfaces
            if (object.textFormat !== Text.PlainText)
                root.fail("untrusted text kept AutoText/rich rendering in " + object)
        }
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            inspect(children[index])
    }

    QtObject {
        id: store

        property var accounts: [{
            id: "account-a",
            address: root.marker,
            displayName: root.marker,
            provider: root.marker
        }]
        property var folders: [{ id: "inbox", name: root.marker, unread: 1 }]
        property var messages: [selectedMessage]
        property var conversations: messages
        property var threadMessages: [selectedMessage]
        property bool threadLoading: false
        property bool threadTruncated: false
        property var recentMail: []
        property var tasks: []
        property var events: []
        property var drafts: [{
            draftId: "draft-a",
            updatedAt: root.marker,
            message: {
                accountId: "account-a",
                subject: root.marker,
                to: [{ address: root.marker }],
                bodyText: root.marker
            }
        }]
        property var selectedMessage: ({
            id: "account-a:message-a",
            accountId: "account-a",
            author: { name: root.marker, address: root.marker },
            to: [{ address: root.marker }],
            subject: root.marker,
            snippet: root.marker,
            timestamp: root.marker,
            bodyText: root.marker,
            bodyHtml: "",
            attachments: [{
                id: "part-a",
                messageId: "account-a:message-a",
                filename: root.marker,
                size: 1
            }]
        })
        property var activeFolder: folders[0]
        property string activeAccountId: "account-a"
        property string activeFolderId: "inbox"
        property string searchText: ""
        property string nextCursor: ""
        property int unreadCount: 1
        property bool loading: false
        property bool loadingMore: false
        property bool readerLoading: false
        property bool mailboxesLoading: false
        property bool syncing: false
        property bool offline: false
        property bool draftsOpen: false
        property bool draftsLoading: false
        property bool accountsLoaded: true
        property string errorText: ""
        property string view: "mail"
        property var composeDraft: ({
            mode: "compose",
            accountId: "account-a",
            to: [{ address: root.marker }],
            cc: [],
            bcc: [],
            subject: root.marker,
            bodyText: root.marker
        })
        readonly property bool hasMore: false

        function messageId(message) { return String(message && message.id || "") }
        function threadKey(message) { return messageId(message) }
        function messageBodyText(message) { return String(message && message.bodyText || "") }
        function selectFolder(folderId) { activeFolderId = String(folderId) }
        function selectAccount(accountId) { activeAccountId = String(accountId) }
        function loadDrafts() {}
        function openDraft(record) {}
        function deleteDraft(record, callback) { if (callback) callback({}, null) }
        function sync(callback) { if (callback) callback({}, null) }
        function search(query) { searchText = String(query) }
        function openMessage(message) { selectedMessage = message }
        function openThreadMessage(message) { selectedMessage = message }
        function toggleStar(message) {}
        function archive(message) {}
        function trash(message) {}
        function markRead(message, read) {}
        function loadMessages(replace) {}
        function startCompose(mode, message) {}
        function downloadAttachment(attachment, open, callback) {}
        function saveAttachmentTo(source, destination, callback) {}
        function addAccount(payload, callback) { if (callback) callback({}, null) }
        function reauthAccount(account, callback) { if (callback) callback({}, null) }
        function removeAccount(account, callback) { if (callback) callback({}, null) }
        function syncAccount(accountId, callback) { if (callback) callback({}, null) }
        function loadAccounts() {}
        function saveDraft(draft, callback) { if (callback) callback({}, null) }
        function closeCompose() {}
        function sendMessage(draft, callback) { if (callback) callback({}, null) }
    }

    StatusBanner {
        x: 0
        width: 420
        message: root.marker
    }

    MessageRow {
        x: 430
        width: 420
        message: store.selectedMessage
    }

    EmptyState {
        x: 860
        width: 420
        height: 300
        title: root.marker
        detail: root.marker
        actionText: root.marker
    }

    PrimaryButton {
        x: 1290
        text: root.marker
    }

    MessageListPane {
        x: 1500
        width: 420
        height: 700
        store: store
    }

    NavigationPane {
        x: 1930
        width: 320
        height: 700
        store: store
    }

    DraftsPane {
        x: 2260
        width: 420
        height: 700
        store: store
    }

    MessageReaderPane {
        x: 2690
        width: 500
        height: 700
        store: store
    }

    AccountSetupPane {
        x: 3200
        width: 480
        height: 700
        store: store
        errorText: root.marker
    }

    ComposePane {
        x: 3690
        width: 500
        height: 700
        store: store
        statusText: root.marker
    }

    Timer {
        interval: 900
        running: true
        repeat: false
        onTriggered: {
            root.inspect(root)
            if (root.protectedSurfaces < 20)
                root.fail("only found " + root.protectedSurfaces
                    + " protected untrusted text surfaces")
            Qt.quit()
        }
    }
}
