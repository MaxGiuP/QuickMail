pragma ComponentBehavior: Bound

import QtQuick
import ".."
import "../components"

Item {
    id: root
    width: 800
    height: 600
    property bool reconnectRecoveryPending: false
    property int avatarCallbackCount: 0
    property string avatarCallbackSource: ""
    property int cancelledAvatarCallbackCount: 0

    function expect(condition, message) {
        if (condition) return
        console.error("STORE CONTRACT TEST FAILED: " + message)
        Qt.exit(1)
    }

    QtObject {
        id: fakeRpc
        property bool connected: true
        property var requests: []
        property bool delayMail: false
        property bool delayThread: false
        property bool delayActions: false
        property bool syncFailure: false
        property var threadResult: null
        property var mailDetail: null
        property var delayedMail: []
        property var delayedThreads: []
        property var delayedActions: []
        property var delayedAvatars: []
        property bool delayAvatars: false
        property var snapshotResult: ({})
        property var methods: ({
            snapshot: "dashboard.snapshot",
            accounts: "accounts.list",
            mailboxes: "mailboxes.list",
            mailList: "mail.list",
            mailGet: "mail.get",
            threadGet: "thread.get",
            mailAction: "mail.action",
            draftSave: "draft.save",
            draftList: "draft.list",
            draftGet: "draft.get",
            draftDelete: "draft.delete",
            accountAdd: "accounts.add",
            accountRemove: "accounts.remove",
            accountReauth: "accounts.reauth",
            attachmentDownload: "attachment.download",
            avatarFetch: "avatar.fetch",
            messageSend: "mail.send",
            syncStart: "sync.start"
        })
        property var events: ({
            snapshot: "snapshot.changed",
            mail: "mail.changed",
            account: "accounts.changed",
            sync: "sync.changed",
            agenda: "agenda.changed",
            resyncRequired: "system.resync_required"
        })

        signal connectionReady()
        signal connectionLost()
        signal notification(string method, var params)

        function record(method, params) {
            const copy = requests.slice()
            copy.push({ method: method, params: params })
            requests = copy
        }

        function request(method, params, callback) {
            record(method, params)
            if (method === methods.snapshot) callback(snapshotResult, null)
            else if (method === methods.accounts) callback([
                { id: "account-a", address: "a@example.com" },
                { id: "account-b", address: "b@example.com" }
            ], null)
            else if (method === methods.mailboxes)
                callback([{ id: "inbox", role: "inbox", accountId: params.accountId }], null)
            else if (method === methods.mailList && delayMail) {
                const pending = delayedMail.slice()
                pending.push({ params: params, callback: callback })
                delayedMail = pending
            } else if (method === methods.mailList)
                callback({ messages: [], nextCursor: null }, null)
            else if (method === methods.threadGet && delayThread) {
                const pending = delayedThreads.slice()
                pending.push({ params: params, callback: callback })
                delayedThreads = pending
            } else if (method === methods.threadGet)
                callback(threadResult || ({ messages: [], truncated: false }), null)
            else if (method === methods.mailGet)
                callback(mailDetail || ({}), null)
            else if (method === methods.mailAction && delayActions) {
                const pending = delayedActions.slice()
                pending.push({ params: params, callback: callback })
                delayedActions = pending
            }
            else if (method === methods.draftSave)
                callback({ draft: { draftId: "draft-returned" }, revision: 2 }, null)
            else if (method === methods.draftList)
                callback([{
                    draftId: "draft-returned",
                    message: {
                        draftId: "draft-returned", accountId: "account-a",
                        to: [{ name: "", address: "draft@example.com" }],
                        cc: [], bcc: [], subject: "Saved draft",
                        bodyText: "Draft body", inReplyTo: null
                    },
                    updatedAt: 1788220800000
                }], null)
            else if (method === methods.draftGet)
                callback({
                    draftId: params.draftId,
                    message: {
                        draftId: params.draftId, accountId: "account-a",
                        to: [{ name: "", address: "draft@example.com" }],
                        cc: [], bcc: [], subject: "Saved draft",
                        bodyText: "Draft body", inReplyTo: null
                    },
                    updatedAt: 1788220800000
                }, null)
            else if (method === methods.draftDelete)
                callback({ revision: 3 }, null)
            else if (method === methods.syncStart && syncFailure)
                callback(null, { message: "sync failed" })
            else if (method === methods.syncStart)
                callback({ accepted: true, completed: true, backgroundStarted: false }, null)
            else if (method === methods.attachmentDownload)
                callback({ path: "/tmp/quickmail-test.txt", filename: "test.txt" }, null)
            else if (method === methods.avatarFetch && delayAvatars) {
                const pending = delayedAvatars.slice()
                pending.push({ params: params, callback: callback })
                delayedAvatars = pending
            }
            else if (method === methods.avatarFetch)
                callback({ path: "/tmp/quickmail-avatar-test" }, null)
            else callback({}, null)
            return requests.length
        }

        function requestConnected(method, params, callback) {
            return request(method, params, callback)
        }
    }

    MailStore {
        id: store
        rpc: fakeRpc
    }

    HtmlMessageView {
        id: htmlView
        visible: false
        width: 600
        allowRemoteContent: false
        html: "<p onclick=\"bad()\">Hello <b>world</b></p>"
            + "<img src=\"https://tracker.invalid/pixel\">"
            + "<style>p{background-image:url(https://tracker.invalid/bg)}</style>"
            + "<script>bad()</script>"
        property int externalOpenRequests: 0
        onExternalLinkRequested: ++externalOpenRequests
    }

    QtObject {
        id: setupStore
        property var accounts: []
        property string errorText: ""
        property int syncCalls: 0
        property int loadCalls: 0
        property int removeCalls: 0
        property string lastSyncedAccountId: ""
        function addAccount(values, callback) { callback({}, null) }
        function reauthAccount(account, callback) { callback({}, null) }
        function syncAccount(accountId, callback) {
            ++syncCalls
            lastSyncedAccountId = String(accountId || "")
            callback({ completed: true }, null)
        }
        function loadAccounts() { ++loadCalls }
        function removeAccount(account, callback) { ++removeCalls; callback({}, null) }
    }

    AccountSetupPane {
        id: setupPane
        visible: false
        width: 600
        height: 500
        store: setupStore
    }

    Timer {
        interval: 50
        running: true
        repeat: false
        onTriggered: {
            root.expect(htmlView.renderedHtml.indexOf("tracker.invalid") < 0,
                "remote-content toggle left a remote resource in rich HTML")
            root.expect(htmlView.renderedHtml.indexOf("<b>world</b>") >= 0,
                "rich HTML formatting was discarded")
            root.expect(htmlView.renderedHtml.indexOf("<script") < 0
                && htmlView.renderedHtml.indexOf("onclick") < 0,
                "executable HTML survived sanitization")
            htmlView.requestExternalOpen("javascript:bad()")
            htmlView.requestExternalOpen("file:///tmp/private")
            htmlView.requestExternalOpen("https://example.com")
            root.expect(htmlView.externalOpenRequests === 1,
                "rich-message links allowed a non-web external scheme")

            let request = null
            for (let i = 0; i < fakeRpc.requests.length; ++i) {
                if (fakeRpc.requests[i].method === fakeRpc.methods.mailList)
                    request = fakeRpc.requests[i]
            }
            root.expect(request !== null, "initial mail request was not sent")
            root.expect(request.params.accountId === "account-a", "mail.list omitted accountId")
            root.expect(request.params.mailboxId === "inbox", "mail.list omitted mailboxId")
            root.expect(store.accountsLoaded,
                "account setup would be forced before saved accounts finished loading")

            store.folders = [
                { id: "Server/INBOX", accountId: "account-a", role: "inbox" },
                { id: "Server/Flagged", accountId: "account-a", role: "starred" }
            ]
            store.activeFolderId = "previous-folder"
            root.expect(store.selectFolderRole("inbox")
                && store.activeFolderId === "Server/INBOX",
                "folder shortcut did not resolve the provider Inbox ID")
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.mailList
                && request.params.mailboxId === "Server/INBOX",
                "folder shortcut sent a role alias instead of the provider mailbox ID")
            const requestsBeforeMailReturn = fakeRpc.requests.length
            store.view = "calendar"
            store.selectFolder("Server/INBOX")
            root.expect(store.view === "mail"
                    && fakeRpc.requests.length === requestsBeforeMailReturn,
                "selecting the current folder did not return from calendar to mail")
            store.view = "calendar"
            store.selectAccount("account-a")
            root.expect(store.view === "calendar",
                "automatic account selection overrode an explicit calendar surface")
            store.view = "mail"
            const requestsBeforeMissingRole = fakeRpc.requests.length
            root.expect(!store.selectFolderRole("unread")
                && store.activeFolderId === "Server/INBOX"
                && fakeRpc.requests.length === requestsBeforeMissingRole,
                "missing mailbox role changed folders or issued an RPC")
            root.expect(store.selectFolderRole("starred")
                && store.activeFolderId === "Server/Flagged",
                "available mailbox role did not resolve its provider ID")

            store.activeAccountId = "account-a"
            const actionMessage = {
                id: "account-a:message-a", accountId: "account-a", read: false
            }
            store.messages = [actionMessage]
            store.markRead(actionMessage, true)
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.mailAction
                && request.params.kind === "mark_read"
                && request.params.messageIds[0] === "account-a:message-a"
                && request.params.message_ids === undefined,
                "mail.action did not use the camelCase wire contract")

            // A slow conversation lookup and an in-flight provider mutation
            // must not keep an already-cached body behind the reader spinner.
            const cachedUnread = {
                id: "account-a:cached-unread", accountId: "account-a",
                mailboxId: "inbox", threadId: "account-a:cached-thread",
                subject: "Cached reader", read: false, snippet: "Cached summary"
            }
            const readerRequestStart = fakeRpc.requests.length
            fakeRpc.delayThread = true
            fakeRpc.delayActions = true
            fakeRpc.delayedThreads = []
            fakeRpc.delayedActions = []
            fakeRpc.mailDetail = Object.assign({}, cachedUnread, {
                bodyText: "Cached body is immediately available"
            })
            store.messages = [cachedUnread]
            store.openMessage(cachedUnread)
            root.expect(!store.readerLoading
                && store.selectedMessage.bodyText === "Cached body is immediately available",
                "thread or mark-read work blocked a cached reader body")
            root.expect(store.threadLoading && fakeRpc.delayedThreads.length === 1
                && fakeRpc.delayedActions.length === 1,
                "reader blocking fixture did not leave thread and action work pending")
            root.expect(fakeRpc.requests.length === readerRequestStart + 3
                && fakeRpc.requests[readerRequestStart].method === fakeRpc.methods.mailGet
                && fakeRpc.requests[readerRequestStart + 1].method === fakeRpc.methods.threadGet
                && fakeRpc.requests[readerRequestStart + 2].method === fakeRpc.methods.mailAction,
                "cached body was not prioritized ahead of thread and provider work")
            fakeRpc.delayedThreads[0].callback({
                id: "account-a:cached-thread", messages: [cachedUnread], truncated: false
            }, null)
            fakeRpc.delayedActions[0].callback({}, null)
            fakeRpc.delayThread = false
            fakeRpc.delayActions = false

            const threadFirst = {
                id: "account-a:message-1", accountId: "account-a",
                mailboxId: "inbox",
                threadId: "account-a:thread-1", subject: "Threaded mail",
                author: { name: "Alex", address: "alex@example.com" },
                timestamp: 1788220800000, read: true, snippet: "First"
            }
            const threadSecond = {
                id: "account-a:message-2", accountId: "account-a",
                mailboxId: "inbox",
                threadId: "account-a:thread-1", subject: "Re: Threaded mail",
                author: { name: "Jamie", address: "jamie@example.com" },
                timestamp: 1788224400000, read: true, starred: true, snippet: "Second"
            }
            store.messages = [threadSecond, threadFirst]
            root.expect(store.conversations.length === 1
                && store.conversations[0].conversationCount === 2
                && store.conversations[0].conversationMessageIds.length === 2
                && store.conversations[0].starred === true,
                "message list did not group and aggregate a conversation")
            const threadSent = Object.assign({}, threadSecond, {
                id: "account-a:sent-message", mailboxId: "sent", snippet: "Sent copy"
            })
            fakeRpc.threadResult = {
                id: "account-a:thread-1",
                messages: [threadFirst, threadSecond, threadSent], truncated: false
            }
            fakeRpc.mailDetail = Object.assign({}, threadSecond, { bodyText: "Second body" })
            store.openMessage(store.conversations[0])
            root.expect(store.threadMessages.length === 3
                && store.activeThreadId === "account-a:thread-1",
                "thread.get did not populate the chronological conversation")
            request = null
            for (let i = fakeRpc.requests.length - 1; i >= 0; --i) {
                if (fakeRpc.requests[i].method === fakeRpc.methods.threadGet) {
                    request = fakeRpc.requests[i]
                    break
                }
            }
            root.expect(request && request.method === fakeRpc.methods.threadGet
                && request.params.messageId === "account-a:message-2",
                "opening a conversation did not request its thread")
            fakeRpc.mailDetail = Object.assign({}, threadFirst, { bodyText: "First body" })
            store.openThreadMessage(threadFirst)
            root.expect(store.messageId(store.selectedMessage) === "account-a:message-1"
                && store.selectedMessage.bodyText === "First body",
                "a different message in the thread could not be opened")
            root.expect(store.selectedMessage.conversationMessageIds.length === 2,
                "mail.get mixed cross-mailbox IDs into a conversation action")
            store.toggleStar(store.selectedMessage)
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.params.messageIds.length === 2,
                "reader actions did not apply consistently to the conversation")
            let automaticSync = null
            for (let i = 0; i < fakeRpc.requests.length; ++i) {
                if (fakeRpc.requests[i].method === fakeRpc.methods.syncStart)
                    automaticSync = fakeRpc.requests[i]
            }
            root.expect(automaticSync !== null && automaticSync.params.accountId === null,
                "saved accounts were not refreshed automatically after startup")

            const gmail = setupPane.gmailPayload("person@gmail.com", "Person")
            root.expect(Object.keys(gmail).length === 3, "Gmail setup contains unexpected fields")
            root.expect(gmail.provider === "gmail" && gmail.address === "person@gmail.com"
                && gmail.displayName === "Person", "Gmail setup payload is incompatible")

            const outlook = setupPane.microsoftPayload(" person@outlook.com ", "Person")
            root.expect(Object.keys(outlook).length === 3,
                "Microsoft setup contains credentials or unexpected fields")
            root.expect(outlook.provider === "outlook"
                && outlook.address === "person@outlook.com"
                && outlook.displayName === "Person"
                && outlook.imap === undefined && outlook.smtp === undefined,
                "Outlook setup payload is incompatible")
            root.expect(setupPane.microsoftPayload("person@hotmail.co.uk", "").provider
                === "hotmail", "Hotmail address did not use the brokered alias")
            root.expect(setupPane.microsoftPayload("person@company.example", "").provider
                === "microsoft365", "organization address did not use Microsoft 365")

            store.activeAccountId = "account-a"
            store.startCompose("reply", {
                id: "message-a",
                accountId: "account-a",
                author: { name: "Alex", address: "alex@example.com" },
                subject: "Hello"
            })
            root.expect(store.composeDraft.to === "alex@example.com", "reply ignored author.address")

            store.startCompose("reply_all", {
                id: "message-a",
                accountId: "account-a",
                author: { name: "Alex", address: "alex@example.com" },
                to: [
                    { address: "a@example.com" },
                    { address: "team@example.com" }
                ],
                cc: [
                    { address: "team@example.com" },
                    { address: "copy@example.com" }
                ],
                subject: "Hello"
            })
            root.expect(store.composeDraft.to === "alex@example.com, team@example.com",
                "reply all omitted recipients or included the sending account")
            root.expect(store.composeDraft.cc === "copy@example.com",
                "reply all did not deduplicate Cc recipients")

            store.startCompose("forward", {
                id: "message-a", accountId: "account-a",
                author: { address: "alex@example.com" },
                to: [{ address: "a@example.com" }],
                subject: "Hello", bodyHtml: "<p>Original <b>body</b></p>"
            })
            root.expect(store.composeDraft.bodyText.indexOf("Original body") >= 0,
                "forward omitted the original message body")
            root.expect(store.composeDraft.inReplyTo === null,
                "forward incorrectly set inReplyTo")

            root.expect(store.composeMailto("mailto:one@example.com?cc=two%40example.com&subject=Hello+there&body=Line%201"),
                "valid mailto URI was rejected")
            root.expect(store.composeDraft.to === "one@example.com", "mailto recipient was not parsed")
            root.expect(store.composeDraft.cc === "two@example.com", "mailto Cc was not parsed")
            root.expect(store.composeDraft.subject === "Hello there", "mailto subject was not decoded")

            store.saveDraft({
                accountId: "account-a", to: [], cc: [], bcc: [],
                subject: "Draft", bodyText: "Body", inReplyTo: null
            }, function(result, error) {})
            root.expect(store.composeDraft.draftId === "draft-returned", "returned draft ID was not retained")

            store.openDrafts()
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.draftList
                && request.params.accountId === "account-a", "draft.list was not account scoped")
            root.expect(store.drafts.length === 1, "saved drafts were not exposed")
            store.openDraft(store.drafts[0])
            root.expect(store.composeDraft.draftId === "draft-returned"
                && store.composeDraft.subject === "Saved draft", "saved draft could not be reopened")
            const outgoing = Object.assign({}, store.composeDraft)
            store.sendMessage(outgoing, function(result, error) {})
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.messageSend
                && request.params.draftId === "draft-returned",
                "mail.send omitted the saved draft ID")
            store.openDrafts()
            store.deleteDraft(store.drafts[0], function(result, error) {})
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.draftDelete
                && request.params.draftId === "draft-returned",
                "draft.delete omitted draftId")
            root.expect(store.drafts.length === 0, "deleted draft remained visible")

            setupPane.requestFinished({ accountId: "account-b" }, null)
            root.expect(setupStore.syncCalls === 1 && setupStore.loadCalls === 1
                && setupStore.lastSyncedAccountId === "account-b",
                "second-account setup synced the previously active account")
            setupPane.account = { id: "account-a", provider: "gmail" }
            setupPane.removeCurrentAccount()
            root.expect(setupStore.removeCalls === 1 && setupStore.loadCalls === 2,
                "editing account could not be removed")
            root.expect(!setupPane.busy && setupPane.errorText === "",
                "successful account removal left the setup pane busy or failed")

            fakeRpc.syncFailure = true
            store.sync()
            root.expect(!store.syncing && store.errorText === "sync failed",
                "sync callback error left the activity state stuck")
            fakeRpc.syncFailure = false
            store.syncAccount("account-b")
            root.expect(store.errorText === "",
                "a successful retry left the previous sync error visible")
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.syncStart
                && request.params.accountId === "account-b",
                "explicit account sync ignored its accountId override")

            fakeRpc.requests = []
            store.offline = false
            store.syncing = false
            root.expect(store.runPeriodicSync(),
                "periodic sync did not run while an account was ready")
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.method === fakeRpc.methods.syncStart
                && request.params.accountId === null,
                "periodic refresh was not an all-account sync")
            store.offline = true
            root.expect(!store.runPeriodicSync(),
                "periodic sync ran while the store was offline")
            store.offline = false
            store.closeDrafts()

            fakeRpc.snapshotResult = {
                accounts: [
                    { id: "account-a", address: "a@example.com", unread: 7 },
                    { id: "account-b", address: "b@example.com", unread: 2 }
                ],
                recentMail: [], tasks: [], events: []
            }
            fakeRpc.requests = []
            fakeRpc.notification(fakeRpc.events.mail, { revision: 10 })
            root.expect(store.unreadCount === 9,
                "mail.changed did not refresh dashboard unread state")
            root.expect(fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.snapshot
            }) && fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.accounts
            }) && fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.mailboxes
            }) && fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.mailList
            }), "mail.changed did not refresh snapshot, accounts, and active mail")

            fakeRpc.snapshotResult = {
                accounts: fakeRpc.snapshotResult.accounts,
                recentMail: [],
                tasks: [{ id: "task-a", title: "Updated task" }],
                events: []
            }
            fakeRpc.requests = []
            fakeRpc.notification(fakeRpc.events.agenda, { revision: 11 })
            root.expect(store.tasks.length === 1 && store.tasks[0].id === "task-a",
                "agenda.changed did not refresh the dashboard snapshot")
            root.expect(fakeRpc.requests.length === 1
                && fakeRpc.requests[0].method === fakeRpc.methods.snapshot,
                "agenda.changed triggered the wrong refresh contract")

            fakeRpc.requests = []
            fakeRpc.notification(fakeRpc.events.resyncRequired, { skipped: 3 })
            root.expect(fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.snapshot
            }) && fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.accounts
            }) && fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.mailboxes
            }) && fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.mailList
            }), "system.resync_required did not perform a full reload")

            store.syncing = true
            fakeRpc.notification(fakeRpc.events.sync, {
                status: "running", running: true, backgroundRemaining: 2
            })
            root.expect(store.syncing,
                "aggregate sync state stopped while background accounts remained")
            fakeRpc.notification(fakeRpc.events.sync, {
                status: "running", running: true, backgroundRemaining: 1
            })
            root.expect(store.syncing,
                "first background completion stopped an aggregate sync")
            fakeRpc.notification(fakeRpc.events.sync, {
                status: "idle", running: false, backgroundRemaining: 0
            })
            root.expect(!store.syncing,
                "aggregate sync state did not clear after the final background account")
            store.syncing = true
            fakeRpc.notification(fakeRpc.events.sync, {
                status: "error", running: true, backgroundRemaining: 1,
                error: "background failed"
            })
            root.expect(!store.syncing,
                "background sync error did not clear activity")
            root.expect(store.errorText === "background failed",
                "background sync error was not surfaced: " + store.errorText)
            fakeRpc.notification(fakeRpc.events.sync, {
                status: "idle", running: false, backgroundRemaining: 0
            })
            root.expect(store.errorText === "background failed",
                "a later aggregate completion erased the sync error")

            store.selectedMessage = { id: "message-a", accountId: "account-a" }
            store.downloadAttachment({ id: "part-1" }, false, function(result, error) {})
            request = fakeRpc.requests[fakeRpc.requests.length - 1]
            root.expect(request.params.disposition === "download", "save used the wrong attachment disposition")

            fakeRpc.delayAvatars = true
            fakeRpc.delayedAvatars = []
            const avatarUrl = "https://www.gravatar.com/avatar/"
                + "0ce273d3249291c620af81403b14b3c1?d=blank&s=128"
            store.resolveAvatar(avatarUrl, function(source, error) {
                if (!error) {
                    ++root.avatarCallbackCount
                    root.avatarCallbackSource = source
                }
            })
            store.resolveAvatar(avatarUrl, function(source, error) {
                if (!error) ++root.avatarCallbackCount
            })
            root.expect(fakeRpc.delayedAvatars.length === 1
                    && store.avatarFetchInFlight === 1,
                "duplicate visible senders issued more than one avatar fetch")
            fakeRpc.delayedAvatars[0].callback({
                path: "/tmp/quickmail-avatar-test"
            }, null)

            fakeRpc.delayedAvatars = []
            const cancelledTokens = []
            for (let avatarIndex = 0; avatarIndex < 5; ++avatarIndex) {
                cancelledTokens.push(store.resolveAvatar(
                    "https://icons.duckduckgo.com/ip3/company-"
                        + avatarIndex + ".dev.ico", function(source, error) {
                            ++root.cancelledAvatarCallbackCount
                        }))
            }
            root.expect(fakeRpc.delayedAvatars.length === 4
                    && store.avatarQueue.length === 1,
                "avatar RPC concurrency was not bounded before cancellation")
            root.expect(store.cancelAvatar(cancelledTokens[4])
                    && store.avatarQueue.length === 0,
                "an offscreen avatar remained in the pending network queue")
            for (let tokenIndex = 0; tokenIndex < 4; ++tokenIndex)
                root.expect(store.cancelAvatar(cancelledTokens[tokenIndex]),
                    "an active avatar consumer could not detach safely")
            for (let delayedIndex = 0;
                    delayedIndex < fakeRpc.delayedAvatars.length; ++delayedIndex) {
                fakeRpc.delayedAvatars[delayedIndex].callback({
                    path: "/tmp/quickmail-cancelled-avatar-" + delayedIndex
                }, null)
            }
            root.expect(root.cancelledAvatarCallbackCount === 0
                    && store.avatarFetchInFlight === 0
                    && Object.keys(store.avatarTokenUrls).length === 0,
                "a cancelled or destroyed avatar received a late callback")
            fakeRpc.delayAvatars = false

            fakeRpc.delayMail = true
            fakeRpc.delayedMail = []
            store.selectedMessage = {
                id: "message-a", accountId: "account-a", bodyText: "Full body", read: false
            }
            store.loadMessages(true, true)
            fakeRpc.delayedMail[0].callback({
                messages: [{ id: "message-a", accountId: "account-a", read: true }],
                nextCursor: null
            }, null)
            root.expect(store.selectedMessage && store.selectedMessage.bodyText === "Full body"
                && store.selectedMessage.read === true,
                "mail refresh discarded the open message")

            fakeRpc.delayedMail = []
            store.activeAccountId = "account-a"
            store.activeFolderId = "inbox"
            store.loadMessages(true)
            store.activeAccountId = "account-b"
            store.loadMessages(true)
            root.expect(fakeRpc.delayedMail.length === 2, "generation test did not queue two requests")
            fakeRpc.delayedMail[1].callback({
                messages: [
                    { id: "message-b", accountId: "account-b" },
                    { id: "cross-account", accountId: "account-a" }
                ],
                nextCursor: null
            }, null)
            fakeRpc.delayedMail[0].callback({
                messages: [{ id: "message-a", accountId: "account-a" }], nextCursor: null
            }, null)
            root.expect(store.messages.length === 1 && store.messages[0].id === "message-b",
                "stale account response replaced the active message list")

            // A daemon restart must re-arm the one-shot startup sync. Otherwise
            // reconnecting can leave mail stale until the periodic timer fires.
            fakeRpc.requests = []
            store.automaticSyncStarted = true
            fakeRpc.connected = false
            fakeRpc.connectionLost()
            root.expect(!store.automaticSyncStarted && store.offline,
                "connection loss did not re-arm immediate reconnect sync")
            fakeRpc.connected = true
            fakeRpc.connectionReady()

            // Simulate the Unix socket becoming connected before the store
            // observes a connectionReady edge. The recovery timer must still
            // restore saved accounts instead of leaving the login pane forced.
            fakeRpc.connected = false
            store.accountsLoaded = false
            store.offline = true
            fakeRpc.connected = true
            root.reconnectRecoveryPending = true
        }
    }

    Timer {
        interval: 900
        running: true
        repeat: false
        onTriggered: {
            root.expect(root.reconnectRecoveryPending,
                "reconnect recovery test did not run")
            root.expect(store.accountsLoaded && !store.offline,
                "a missed connection edge left saved accounts offline")
            root.expect(fakeRpc.requests.some(function(item) {
                return item.method === fakeRpc.methods.syncStart
                    && item.params.accountId === null
            }), "reconnect did not trigger an immediate all-account sync")
            root.expect(root.avatarCallbackCount === 2
                    && root.avatarCallbackSource
                        === "file:///tmp/quickmail-avatar-test"
                    && store.avatarFetchInFlight === 0,
                "the single avatar result was not shared through the local-file cache")
            root.expect(root.cancelledAvatarCallbackCount === 0
                    && store.avatarQueue.length === 0,
                "cancelled avatar work survived until the end of the test")
            Qt.quit()
        }
    }
}
