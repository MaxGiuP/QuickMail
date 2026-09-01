import QtQuick
import QtQuick.Controls
import ".."

ApplicationWindow {
    id: window
    visible: true
    width: 1180
    height: 760
    color: Theme.canvas
    property var accountFixture: [{
        id: "personal", address: "alex@example.com", displayName: "Alex Morgan",
        provider: "Gmail", unread: 4
    }]

    function expect(condition, message) {
        if (condition) return
        console.error("UI SMOKE TEST FAILED: " + message)
        Qt.exit(1)
    }

    QtObject {
        id: fakeStore
        property var accounts: window.accountFixture
        property var folders: [
            { id: "inbox", accountId: "personal", name: "Inbox", unread: 4 },
            { id: "sent", accountId: "personal", name: "Sent", unread: 0 },
            { id: "archive", accountId: "personal", name: "Archive", unread: 0 }
        ]
        property var messages: [
            { id: "m1", accountId: "personal", author: { name: "Maya Chen", address: "maya@example.com" },
                subject: "Design review tomorrow", snippet: "I pulled the latest notes together…",
                timestamp: "2026-09-01T09:42:00Z", read: false, starred: true },
            { id: "m2", accountId: "personal", author: { name: "Rail Tickets", address: "travel@example.com" },
                subject: "Your journey confirmation", snippet: "London to Edinburgh is confirmed.",
                timestamp: "2026-08-31T18:04:00Z", read: true, starred: false }
        ]
        property var selectedMessage: messages[0]
        property var drafts: [{
            draftId: "draft-1",
            message: {
                accountId: "personal",
                to: [{ address: "pat@example.com" }],
                subject: "Finish the release notes",
                bodyText: "Draft body"
            },
            updatedAt: 1788220800000
        }]
        property var activeAccount: accounts[0]
        property var activeFolder: folders[0]
        property string activeAccountId: "personal"
        property string activeFolderId: "inbox"
        property string searchText: ""
        property bool hasMore: true
        property int unreadCount: 4
        property bool loading: false
        property bool loadingMore: false
        property bool readerLoading: false
        property bool syncing: false
        property bool offline: false
        property bool draftsOpen: false
        property bool draftsLoading: false
        property bool accountsLoaded: true
        property string errorText: ""
        property string view: "mail"
        property var composeDraft: ({})

        function messageId(message) { return message ? String(message.id || "") : "" }
        function messageBodyText(message) { return String(message && (message.bodyText || message.snippet) || "") }
        function selectAccount(id) { activeAccountId = id }
        function selectFolder(id) { activeFolderId = id }
        function search(query) { searchText = query }
        function loadMessages(reset) { loadingMore = false }
        function openMessage(message) { selectedMessage = message }
        function toggleStar(message) { message.starred = !message.starred }
        function markRead(message, read) { message.read = read }
        function archive(message) {}
        function trash(message) {}
        function sync(callback) { syncing = !syncing; if (callback) callback({ completed: true }, null) }
        function openDrafts() { draftsOpen = true }
        function closeDrafts() { draftsOpen = false }
        function loadDrafts() {}
        function openDraft(draft) {}
        function deleteDraft(draft, callback) { if (callback) callback({}, null) }
        function startCompose(mode, message) {
            composeDraft = { mode: mode, to: "", subject: "", bodyText: "" }
            view = "compose"
        }
        function closeCompose() { view = "mail" }
        function saveDraft(draft, callback) { callback({}, null) }
        function sendMessage(draft, callback) { callback({}, null); closeCompose() }
    }

    MainWindow {
        id: mainWindow
        anchors.fill: parent
        store: fakeStore
    }

    Timer {
        interval: 20
        running: true
        repeat: false
        onTriggered: {
            fakeStore.accounts = []
            fakeStore.accountsLoaded = false
        }
    }
    Timer {
        interval: 50
        running: true
        repeat: false
        onTriggered: {
            window.expect(!mainWindow.accountSetupVisible,
                "account setup appeared before saved accounts finished loading")
            fakeStore.accountsLoaded = true
        }
    }
    Timer {
        interval: 80
        running: true
        repeat: false
        onTriggered: {
            window.expect(mainWindow.accountSetupVisible,
                "account setup did not appear after a successful empty account list")
            fakeStore.accounts = window.accountFixture
        }
    }

    Timer {
        interval: 100
        running: true
        repeat: false
        onTriggered: window.width = 620
    }
    Timer {
        interval: 180
        running: true
        repeat: false
        onTriggered: fakeStore.startCompose("reply", fakeStore.selectedMessage)
    }
    Timer {
        interval: 270
        running: true
        repeat: false
        onTriggered: fakeStore.closeCompose()
    }
    Timer {
        interval: 340
        running: true
        repeat: false
        onTriggered: fakeStore.openDrafts()
    }
    Timer {
        interval: 520
        running: true
        repeat: false
        onTriggered: Qt.quit()
    }
}
