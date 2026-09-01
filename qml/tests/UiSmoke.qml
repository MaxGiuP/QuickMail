import QtQuick
import QtQuick.Controls
import ".."

ApplicationWindow {
    id: window
    visible: true
    width: 620
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
                bodyHtml: "<div style='background-color:#102030'>First HTML message</div>",
                timestamp: "2026-09-01T09:42:00Z", read: false, starred: true },
            { id: "m2", accountId: "personal", author: { name: "Rail Tickets", address: "travel@example.com" },
                subject: "Your journey confirmation", snippet: "London to Edinburgh is confirmed.",
                bodyHtml: "<div style='background-color:#405060'>Second HTML message</div>",
                timestamp: "2026-08-31T18:04:00Z", read: true, starred: false }
        ]
        property var selectedMessage: messages[0]
        property var conversations: messages
        property var threadMessages: selectedMessage ? [selectedMessage] : []
        property bool threadLoading: false
        property bool threadTruncated: false
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
        property int savedDrafts: 0
        property int deletedDrafts: 0
        property int closedComposers: 0
        property int startedComposers: 0
        property bool delayDraftSave: false
        property var pendingDraftSave: null

        function messageId(message) { return message ? String(message.id || "") : "" }
        function threadKey(message) { return messageId(message) }
        function messageBodyText(message) { return String(message && (message.bodyText || message.snippet) || "") }
        function selectAccount(id) { activeAccountId = id }
        function selectFolder(id) { activeFolderId = id }
        function search(query) { searchText = query }
        function loadMessages(reset) { loadingMore = false }
        function openMessage(message) { selectedMessage = message }
        function openThreadMessage(message) { selectedMessage = message }
        function toggleStar(message) { message.starred = !message.starred }
        function markRead(message, read) { message.read = read }
        function archive(message) {}
        function trash(message) {}
        function sync(callback) { syncing = !syncing; if (callback) callback({ completed: true }, null) }
        function openDrafts() { draftsOpen = true }
        function closeDrafts() { draftsOpen = false }
        function loadDrafts() {}
        function openDraft(draft) {}
        function deleteDraft(draft, callback) { ++deletedDrafts; if (callback) callback({}, null) }
        function startCompose(mode, message) {
            ++startedComposers
            composeDraft = {
                mode: mode,
                to: message ? [{ address: message.author.address }] : "",
                subject: message ? "Re: " + message.subject : "",
                bodyText: message ? "Thanks — I will take a look." : ""
            }
            view = "compose"
        }
        function closeCompose() { ++closedComposers; composeDraft = ({}); view = "mail" }
        function saveDraft(draft, callback) {
            ++savedDrafts
            if (delayDraftSave) {
                delayDraftSave = false
                pendingDraftSave = callback
            } else callback({}, null)
        }
        function finishPendingDraftSave() {
            const callback = pendingDraftSave
            pendingDraftSave = null
            if (callback) callback({}, null)
        }
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
        onTriggered: window.expect(mainWindow.mobile,
            "smoke fixture did not enter the responsive layout")
    }
    Timer {
        interval: 125
        running: true
        repeat: false
        onTriggered: {
            window.expect(mainWindow.renderedMessageHtml === fakeStore.messages[0].bodyHtml,
                "reader did not render the initially selected HTML message")
            fakeStore.selectedMessage = fakeStore.messages[1]
        }
    }
    Timer {
        interval: 155
        running: true
        repeat: false
        onTriggered: {
            window.expect(mainWindow.renderedMessageHtml === fakeStore.messages[1].bodyHtml,
                "reader kept stale HTML when switching messages with an active loader")
            fakeStore.selectedMessage = fakeStore.messages[0]
        }
    }
    Timer {
        interval: 180
        running: true
        repeat: false
        onTriggered: fakeStore.startCompose("reply", fakeStore.selectedMessage)
    }
    Timer {
        interval: 250
        running: true
        repeat: false
        onTriggered: {
            window.expect(mainWindow.composeVisible,
                "floating composer did not open")
            window.expect(mainWindow.composeRendered,
                "floating composer was not rendered while open")
            window.expect(mainWindow.mailSurfaceVisible,
                "mail disappeared behind the composer")
            window.expect(!mainWindow.mailSurfaceInteractive,
                "mail shortcuts remained active while editing a draft")
            window.expect(mainWindow.composePanelWidth <= window.width - 12
                && mainWindow.composePanelWidth >= window.width - 32,
                "mobile composer did not fit the window ("
                    + mainWindow.composePanelWidth + " of " + window.width
                    + ", surface " + mainWindow.width + ", mobile "
                    + mainWindow.mobile + ")")
            window.expect(mainWindow.composePanelHeight > 400,
                "expanded composer was not tall enough to edit")
            mainWindow.minimizeCompose()
        }
    }
    Timer {
        interval: 490
        running: true
        repeat: false
        onTriggered: {
            window.expect(mainWindow.composeMinimized,
                "composer did not become a bottom tab")
            window.expect(mainWindow.composePanelHeight <= 50,
                "minimized composer retained its expanded height")
            window.expect(mainWindow.composePanelWidth <= 341,
                "minimized compose tab remained full width")
            window.expect(mainWindow.mailSurfaceVisible,
                "mail was not browseable with a minimized draft")
            window.expect(mainWindow.mailSurfaceInteractive,
                "mail stayed disabled behind the minimized compose tab")
            mainWindow.startNewCompose()
            window.expect(fakeStore.startedComposers === 1,
                "restoring a compose tab replaced the existing draft")
        }
    }
    Timer {
        interval: 600
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftSave = true
            mainWindow.saveCompose()
            mainWindow.startContextCompose("forward", fakeStore.selectedMessage)
            window.expect(fakeStore.startedComposers === 1,
                "an in-flight save was not allowed to finish before replacement")
            fakeStore.finishPendingDraftSave()
            window.expect(fakeStore.savedDrafts === 2,
                "starting a reply did not save the newest draft revision")
            window.expect(fakeStore.startedComposers === 2,
                "starting a reply did not replace the saved compose tab")
            window.expect(String(fakeStore.composeDraft.mode) === "forward",
                "replacement compose mode was not loaded into the editor")
        }
    }
    Timer {
        interval: 730
        running: true
        repeat: false
        onTriggered: {
            window.expect(!mainWindow.composeMinimized,
                "composer did not restore from its tab")
            window.expect(mainWindow.composePanelHeight > 400,
                "restored composer did not animate back to editing size")
            mainWindow.requestComposeClose()
            window.expect(fakeStore.savedDrafts === 3,
                "closing a populated composer did not save its draft")
            window.expect(fakeStore.closedComposers === 1,
                "save-and-close did not close exactly one composer")
            window.expect(!mainWindow.composeVisible,
                "composer stayed logically open after save-and-close")
            window.expect(mainWindow.composeRendered && mainWindow.composeOpacity > 0,
                "composer disappeared without its close animation")
        }
    }
    Timer {
        interval: 970
        running: true
        repeat: false
        onTriggered: {
            window.expect(!mainWindow.composeRendered,
                "composer remained rendered after its close animation")
            fakeStore.composeDraft = {
                mode: "draft", draftId: "draft-2", to: "", subject: "Temporary",
                bodyText: "Remove me"
            }
            fakeStore.view = "compose"
        }
    }
    Timer {
        interval: 1040
        running: true
        repeat: false
        onTriggered: mainWindow.discardCompose()
    }
    Timer {
        interval: 1090
        running: true
        repeat: false
        onTriggered: {
            window.expect(fakeStore.deletedDrafts === 1,
                "explicit discard did not delete the saved draft")
            window.expect(fakeStore.view === "mail",
                "discard did not close the composer")
            window.expect(fakeStore.closedComposers === 2,
                "discard did not close exactly one composer")
            fakeStore.openDrafts()
        }
    }
    Timer {
        interval: 1250
        running: true
        repeat: false
        onTriggered: Qt.quit()
    }
}
