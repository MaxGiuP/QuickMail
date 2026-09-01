import QtQuick
import QtQuick.Controls
import ".."

ApplicationWindow {
    id: window
    visible: true
    width: 620
    height: 760
    color: Theme.canvas
    property int windowCloseReadyCount: 0
    property int scenarioDeletedBefore: 0
    property int scenarioMailtosBefore: 0
    property int scenarioSentBefore: 0
    property int scenarioStartedBefore: 0
    property int scenarioSavedBefore: 0
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
        property bool failNextDraftSave: false
        property var pendingDraftSave: null
        property bool delayDraftDelete: false
        property var pendingDraftDelete: null
        property bool delaySend: false
        property bool failPendingSend: false
        property var pendingSend: null
        property int sentMessages: 0
        property int composedMailtos: 0

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
        function deleteDraft(draft, callback) {
            ++deletedDrafts
            if (delayDraftDelete) {
                delayDraftDelete = false
                pendingDraftDelete = callback
            } else if (callback) callback({}, null)
        }
        function finishPendingDraftDelete(error) {
            const callback = pendingDraftDelete
            pendingDraftDelete = null
            if (callback) callback({}, error || null)
        }
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
        function decodeMailtoPart(value, plusAsSpace) {
            let encoded = String(value || "")
            if (plusAsSpace) encoded = encoded.replace(/\+/g, " ")
            try { return decodeURIComponent(encoded) } catch (error) { return "" }
        }
        function composeMailto(uri) {
            const text = String(uri || "")
            if (!/^mailto:/i.test(text) || text.length > 262144) return false
            const payload = text.substring(7)
            const separator = payload.indexOf("?")
            const path = separator < 0 ? payload : payload.substring(0, separator)
            const query = separator < 0 ? "" : payload.substring(separator + 1)
            const fields = { to: decodeMailtoPart(path, false), subject: "", bodyText: "" }
            const pairs = query === "" ? [] : query.split("&")
            for (let i = 0; i < pairs.length; ++i) {
                const equals = pairs[i].indexOf("=")
                const key = decodeMailtoPart(equals < 0 ? pairs[i]
                    : pairs[i].substring(0, equals), true).toLowerCase()
                const value = decodeMailtoPart(equals < 0 ? ""
                    : pairs[i].substring(equals + 1), true)
                if (key === "subject") fields.subject = value
                else if (key === "body") fields.bodyText = value
            }
            ++composedMailtos
            composeDraft = {
                accountId: activeAccountId, mode: "compose", inReplyTo: null,
                to: fields.to, cc: "", bcc: "", subject: fields.subject,
                bodyText: fields.bodyText
            }
            view = "compose"
            return true
        }
        function saveDraft(draft, callback) {
            ++savedDrafts
            if (failNextDraftSave) {
                failNextDraftSave = false
                callback({}, { message: "simulated draft save failure" })
                return
            }
            if (delayDraftSave) {
                delayDraftSave = false
                pendingDraftSave = callback
            } else callback({}, null)
        }
        function finishPendingDraftSave(error) {
            const callback = pendingDraftSave
            pendingDraftSave = null
            if (callback) callback({}, error || null)
        }
        function sendMessage(draft, callback) {
            ++sentMessages
            if (delaySend) {
                delaySend = false
                pendingSend = callback
                return
            }
            closeCompose()
            callback({}, null)
        }
        function finishPendingSend() {
            const callback = pendingSend
            const failed = failPendingSend
            pendingSend = null
            failPendingSend = false
            if (!callback) return
            if (failed) callback({}, { message: "simulated send failure" })
            else {
                closeCompose()
                callback({}, null)
            }
        }
    }

    MainWindow {
        id: mainWindow
        anchors.fill: parent
        store: fakeStore
        onWindowCloseReady: ++window.windowCloseReadyCount
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
        onTriggered: {
            window.expect(mainWindow.mobile,
                "smoke fixture did not enter the responsive layout")
            window.expect(mainWindow.navigationRailVisible
                    && mainWindow.navigationRailWidth >= 60,
                "compressed layout hid or collapsed the navigation rail")
            window.expect(mainWindow.mailListLeftEdge
                    >= mainWindow.navigationRailWidth,
                "compressed mail content covered the navigation rail")
            window.expect(!mainWindow.draftsBackButtonVisible,
                "persistent navigation left the drafts title offset by a back button")
        }
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
            fakeStore.composeDraft = {
                mode: "draft", draftId: "draft-3", to: "",
                subject: "Save before closing", bodyText: "Still editing"
            }
            fakeStore.view = "compose"
        }
    }
    Timer {
        interval: 1140
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftSave = true
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "window close did not wait for an in-flight draft save")
            window.expect(window.windowCloseReadyCount === 0,
                "window close completed before the draft save callback")
            window.expect(fakeStore.pendingDraftSave !== null,
                "window close did not start the final draft save")
        }
    }
    Timer {
        interval: 1190
        running: true
        repeat: false
        onTriggered: {
            mainWindow.cancelWindowClose()
            window.expect(!mainWindow.windowClosePending,
                "reopening did not cancel a pending window close")
            fakeStore.finishPendingDraftSave()
            window.expect(!mainWindow.windowClosePending,
                "cancelled window close became pending again after draft save")
            window.expect(window.windowCloseReadyCount === 0,
                "a reopened window quit after its delayed draft save completed")
            window.expect(mainWindow.composeVisible,
                "reopening allowed the delayed save to close the composer")
            window.expect(fakeStore.closedComposers === 2,
                "reopening closed the composer unexpectedly")
            window.expect(mainWindow.safeToReplace,
                "a fully saved reopened draft was not safe for stale-UI replacement")

            fakeStore.failNextDraftSave = true
            mainWindow.prepareWindowClose()
            window.expect(!mainWindow.windowClosePending,
                "a failed final draft save left window close permanently pending")
            window.expect(mainWindow.composeVisible,
                "a failed final draft save discarded the composer")
            window.expect(window.windowCloseReadyCount === 0,
                "a failed final draft save allowed the window to quit")

            mainWindow.prepareWindowClose()
            window.expect(window.windowCloseReadyCount === 1,
                "retrying window close did not complete after a successful save")
            window.expect(fakeStore.closedComposers === 3,
                "retrying window close did not close the saved composer")
        }
    }
    Timer {
        interval: 1250
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "old@example.com",
                subject: "Unsaved before mailto", bodyText: "Keep this first"
            }
            fakeStore.view = "compose"
        }
    }
    Timer {
        interval: 1300
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftSave = true
            const accepted = mainWindow.startMailto(
                "mailto:new@example.com?subject=Mailto%20subject&body=Mailto%20body")
            window.expect(accepted, "a valid mailto request was rejected")
            window.expect(mainWindow.composeReplacementQueued,
                "mailto did not queue behind the active draft save")
            window.expect(fakeStore.pendingDraftSave !== null,
                "mailto replaced an unsaved draft without saving it first")
            window.expect(mainWindow.composeSubjectText === "Unsaved before mailto",
                "mailto changed editor fields before the prior draft was saved")
        }
    }
    Timer {
        interval: 1350
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftSave()
            window.expect(fakeStore.composedMailtos === 1,
                "saved mailto replacement was not applied")
            window.expect(mainWindow.composeRecipientText === "new@example.com"
                    && mainWindow.composeSubjectText === "Mailto subject"
                    && mainWindow.composeBodyText === "Mailto body",
                "mailto replacement did not reload the visible editor fields")
            mainWindow.requestComposeClose()
        }
    }
    Timer {
        interval: 1400
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "queued@example.com",
                subject: "Close beats replacement", bodyText: "Persist me"
            }
            fakeStore.view = "compose"
        }
    }
    Timer {
        interval: 1450
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftSave = true
            mainWindow.startContextCompose("forward", fakeStore.selectedMessage)
            window.expect(mainWindow.composeReplacementQueued,
                "replacement fixture was not queued")
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "native close did not wait behind the queued replacement save")
            window.expect(!mainWindow.composeReplacementQueued,
                "native close did not cancel the queued replacement")
        }
    }
    Timer {
        interval: 1500
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftSave()
            window.expect(window.windowCloseReadyCount === 2,
                "native close did not resolve after overriding a replacement")
            window.expect(fakeStore.startedComposers === 2,
                "a cancelled replacement started after native close")
            window.expect(!mainWindow.composeVisible,
                "composer remained open after close overrode replacement")
        }
    }
    Timer {
        interval: 1550
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "send@example.com",
                subject: "Do not send old draft", bodyText: "Queued replacement"
            }
            fakeStore.view = "compose"
        }
    }
    Timer {
        interval: 1600
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftSave = true
            mainWindow.startContextCompose("reply", fakeStore.selectedMessage)
            mainWindow.sendCompose()
            window.expect(!mainWindow.composeSending && fakeStore.sentMessages === 0,
                "send started while a replacement save was queued")
            fakeStore.finishPendingDraftSave()
            window.expect(!mainWindow.composeSending,
                "replacement completion left the composer wedged in sending state")
            window.expect(fakeStore.startedComposers === 3,
                "guarded send prevented the queued replacement from completing")
            mainWindow.requestComposeClose()
        }
    }
    Timer {
        interval: 1700
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "failure@example.com",
                subject: "Retry after send failure", bodyText: "Unsent message"
            }
            fakeStore.view = "compose"
        }
    }
    Timer {
        interval: 1750
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delaySend = true
            fakeStore.failPendingSend = true
            mainWindow.sendCompose()
            window.expect(mainWindow.composeSending && fakeStore.pendingSend !== null,
                "send failure fixture did not remain in flight")
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "native close did not wait for the in-flight send")
        }
    }
    Timer {
        interval: 1800
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingSend()
            window.expect(!mainWindow.windowClosePending,
                "send failure left native close permanently pending")
            window.expect(mainWindow.composeVisible && !mainWindow.composeSending,
                "send failure discarded or wedged the composer")
            window.expect(window.windowCloseReadyCount === 2,
                "send failure incorrectly completed native close")
            mainWindow.prepareWindowClose()
            window.expect(window.windowCloseReadyCount === 3,
                "native close was not retryable after send failure")
        }
    }
    Timer {
        interval: 1850
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "save-error@example.com",
                subject: "Keep mailto queued", bodyText: "Save this before replacing"
            }
            fakeStore.view = "compose"
            window.scenarioMailtosBefore = fakeStore.composedMailtos
            window.scenarioSentBefore = fakeStore.sentMessages
            fakeStore.failNextDraftSave = true
            const accepted = mainWindow.startMailto(
                "mailto:after-save-error@example.com?subject=Still%20queued")
            window.expect(accepted && mainWindow.composeReplacementQueued,
                "a mailto was lost when its replacement save failed")
            window.expect(fakeStore.composedMailtos === window.scenarioMailtosBefore,
                "a mailto replaced a draft whose save failed")
            // This is the same direct path used by Ctrl+Enter; the disabled
            // button alone is not enough to serialize a pending transition.
            mainWindow.sendCompose()
            window.expect(!mainWindow.composeSending
                    && fakeStore.sentMessages === window.scenarioSentBefore,
                "direct send bypassed a queued mailto after save failure")
            mainWindow.saveCompose()
            window.expect(fakeStore.composedMailtos
                    === window.scenarioMailtosBefore + 1,
                "a queued mailto did not recover after retrying its draft save")
            window.expect(mainWindow.composeRecipientText
                    === "after-save-error@example.com",
                "recovered mailto did not reload the visible composer")
            mainWindow.requestComposeClose()
        }
    }
    Timer {
        interval: 1950
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "send@example.com",
                subject: "Mailto after send", bodyText: "Send this first"
            }
            fakeStore.view = "compose"
            window.scenarioMailtosBefore = fakeStore.composedMailtos
            window.scenarioSentBefore = fakeStore.sentMessages
        }
    }
    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delaySend = true
            mainWindow.sendCompose()
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "send fixture did not leave native close pending")
            const accepted = mainWindow.startMailto(
                "mailto:after-send@example.com?subject=Opened%20after%20send")
            window.expect(accepted && mainWindow.composeReplacementQueued,
                "IPC-style mailto was rejected or lost during send")
            window.expect(!mainWindow.windowClosePending,
                "accepted mailto did not override the pending native close")
            window.expect(fakeStore.pendingSend !== null
                    && fakeStore.sentMessages === window.scenarioSentBefore + 1,
                "mailto interfered with the provider-visible send")
        }
    }
    Timer {
        interval: 2050
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingSend()
            window.expect(fakeStore.composedMailtos
                    === window.scenarioMailtosBefore + 1,
                "mailto queued during send was silently dropped")
            window.expect(mainWindow.composeVisible
                    && mainWindow.composeRecipientText === "after-send@example.com",
                "mailto queued during send did not open after completion")
            window.expect(window.windowCloseReadyCount === 3,
                "overridden send-close request still completed native close")
            mainWindow.requestComposeClose()
        }
    }
    Timer {
        interval: 2100
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "draft", draftId: "draft-discard-mailto",
                to: "", subject: "Discard before mailto", bodyText: "Remove once"
            }
            fakeStore.view = "compose"
            window.scenarioDeletedBefore = fakeStore.deletedDrafts
            window.scenarioMailtosBefore = fakeStore.composedMailtos
        }
    }
    Timer {
        interval: 2150
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftDelete = true
            mainWindow.discardCompose()
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "discard fixture did not leave native close pending")
            const accepted = mainWindow.startMailto(
                "mailto:after-discard@example.com?subject=Opened%20after%20discard")
            window.expect(accepted && mainWindow.composeReplacementQueued,
                "IPC-style mailto was rejected or lost during discard")
            window.expect(!mainWindow.windowClosePending,
                "accepted mailto did not override discard's pending native close")
            window.expect(fakeStore.deletedDrafts
                    === window.scenarioDeletedBefore + 1,
                "mailto started a duplicate draft deletion")
        }
    }
    Timer {
        interval: 2200
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftDelete(null)
            window.expect(fakeStore.composedMailtos
                    === window.scenarioMailtosBefore + 1,
                "mailto queued during discard was silently dropped")
            window.expect(mainWindow.composeVisible
                    && mainWindow.composeRecipientText === "after-discard@example.com",
                "mailto queued during discard did not open after completion")
            window.expect(fakeStore.deletedDrafts
                    === window.scenarioDeletedBefore + 1,
                "completed discard deleted its draft more than once")
            window.expect(window.windowCloseReadyCount === 3,
                "overridden discard-close request still completed native close")
            mainWindow.requestComposeClose()
        }
    }
    Timer {
        interval: 2250
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "draft", draftId: "draft-async-discard",
                to: "", subject: "Discard in progress", bodyText: "Remove once"
            }
            fakeStore.view = "compose"
            window.scenarioDeletedBefore = fakeStore.deletedDrafts
            window.scenarioSavedBefore = fakeStore.savedDrafts
        }
    }
    Timer {
        interval: 2300
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftDelete = true
            mainWindow.discardCompose()
            window.expect(mainWindow.composeDiscarding
                    && fakeStore.pendingDraftDelete !== null,
                "discard fixture did not remain in flight")
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "native close did not wait for the in-flight discard")
            window.expect(fakeStore.deletedDrafts
                    === window.scenarioDeletedBefore + 1,
                "native close started a second draft deletion")
            window.expect(fakeStore.savedDrafts === window.scenarioSavedBefore,
                "native close started a concurrent save during discard")
        }
    }
    Timer {
        interval: 2350
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftDelete(null)
            window.expect(!mainWindow.composeDiscarding && !mainWindow.composeVisible,
                "completed discard did not close the composer")
            window.expect(fakeStore.deletedDrafts
                    === window.scenarioDeletedBefore + 1,
                "async discard deleted the same draft more than once")
            window.expect(window.windowCloseReadyCount === 4,
                "native close did not complete after async discard")
        }
    }
    Timer {
        interval: 2400
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "draft", draftId: "draft-discard-failure",
                to: "", subject: "Retry failed discard", bodyText: "Keep on error"
            }
            fakeStore.view = "compose"
            window.scenarioDeletedBefore = fakeStore.deletedDrafts
        }
    }
    Timer {
        interval: 2450
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftDelete = true
            mainWindow.discardCompose()
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending,
                "failed-discard fixture did not leave native close pending")
        }
    }
    Timer {
        interval: 2500
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftDelete(
                { message: "simulated draft delete failure" })
            window.expect(!mainWindow.windowClosePending,
                "failed discard left native close permanently pending")
            window.expect(mainWindow.composeVisible && !mainWindow.composeDiscarding,
                "failed discard closed or wedged the draft")
            window.expect(window.windowCloseReadyCount === 4,
                "failed discard incorrectly completed native close")
            window.expect(fakeStore.deletedDrafts
                    === window.scenarioDeletedBefore + 1,
                "failed discard performed duplicate deletions")

            fakeStore.delayDraftDelete = true
            mainWindow.discardCompose()
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending
                    && fakeStore.deletedDrafts === window.scenarioDeletedBefore + 2,
                "discard/native-close was not retryable after delete failure")
        }
    }
    Timer {
        interval: 2550
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftDelete(null)
            window.expect(!mainWindow.composeVisible
                    && window.windowCloseReadyCount === 5,
                "retried discard did not complete native close")
            window.expect(fakeStore.deletedDrafts
                    === window.scenarioDeletedBefore + 2,
                "discard retry deleted more than once per attempt")
        }
    }
    Timer {
        interval: 2600
        running: true
        repeat: false
        onTriggered: {
            fakeStore.composeDraft = {
                mode: "compose", to: "replacement-close@example.com",
                subject: "Replacement close failure", bodyText: "Do not lose me"
            }
            fakeStore.view = "compose"
            window.scenarioStartedBefore = fakeStore.startedComposers
        }
    }
    Timer {
        interval: 2650
        running: true
        repeat: false
        onTriggered: {
            fakeStore.delayDraftSave = true
            mainWindow.startContextCompose("reply", fakeStore.selectedMessage)
            mainWindow.prepareWindowClose()
            window.expect(mainWindow.windowClosePending
                    && !mainWindow.composeReplacementQueued,
                "native close did not override the failing queued replacement")
        }
    }
    Timer {
        interval: 2700
        running: true
        repeat: false
        onTriggered: {
            fakeStore.finishPendingDraftSave(
                { message: "simulated queued close save failure" })
            window.expect(!mainWindow.windowClosePending,
                "queued-replacement save failure left native close pending")
            window.expect(mainWindow.composeVisible,
                "queued-replacement save failure discarded the current draft")
            window.expect(fakeStore.startedComposers
                    === window.scenarioStartedBefore,
                "cancelled replacement started after its close-save failed")
            mainWindow.prepareWindowClose()
            window.expect(window.windowCloseReadyCount === 6,
                "native close was not retryable after replacement save failure")
        }
    }
    Timer {
        interval: 2800
        running: true
        repeat: false
        onTriggered: Qt.quit()
    }
}
