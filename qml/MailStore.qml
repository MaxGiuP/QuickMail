import QtQuick

QtObject {
    id: root

    required property var rpc

    property var accounts: []
    property var folders: []
    property var messages: []
    property var recentMail: []
    property var tasks: []
    property var events: []
    property var drafts: []
    property var selectedMessage: null
    property string activeAccountId: ""
    property string activeFolderId: "inbox"
    property string searchText: ""
    property string nextCursor: ""
    property int unreadCount: 0
    property bool loading: false
    property bool loadingMore: false
    property bool readerLoading: false
    property bool mailboxesLoading: false
    property bool syncing: false
    property bool offline: false
    property bool draftsOpen: false
    property bool draftsLoading: false
    property bool accountsLoaded: false
    property bool initialLoadInFlight: false
    property bool automaticSyncStarted: false
    property string errorText: ""
    property string view: "mail" // mail | compose
    property var composeDraft: ({})
    property var attachmentSaveHandler: null
    property int accountsRequestGeneration: 0
    property int mailboxesRequestGeneration: 0
    property int messageListGeneration: 0
    property int readerGeneration: 0
    property int composeGeneration: 0
    property int draftsRequestGeneration: 0
    property int draftOpenGeneration: 0

    readonly property var activeAccount: findById(accounts, activeAccountId)
    readonly property var activeFolder: findById(folders, activeFolderId)
    readonly property bool hasMore: nextCursor !== ""

    signal messageListChangedByAction()
    signal accountStateChanged(var event)

    function findById(items, id) {
        const list = Array.isArray(items) ? items : []
        for (let i = 0; i < list.length; ++i) {
            const item = list[i]
            if (String(item.id || item.account_id || item.folder_id || "") === String(id)) return item
        }
        return null
    }

    function normalizeArray(value, key) {
        if (Array.isArray(value)) return value
        if (value && Array.isArray(value[key])) return value[key]
        return []
    }

    function accountId(account) {
        return String(account ? (account.id || account.account_id || "") : "")
    }

    function messageId(message) {
        return String(message ? (message.id || message.message_id || "") : "")
    }

    function messageAccountId(message) {
        return String(message ? (message.accountId || message.account_id || "") : "")
    }

    function belongsToAccount(message, id) {
        const owner = messageAccountId(message)
        return owner !== "" && owner === String(id)
    }

    function applySnapshot(snapshot) {
        if (!snapshot) return
        if (Array.isArray(snapshot.accounts)) {
            accounts = snapshot.accounts
            if (activeAccountId !== "" && !findById(accounts, activeAccountId))
                activeAccountId = ""
        }
        if (Array.isArray(snapshot.recentMail)) recentMail = snapshot.recentMail
        if (Array.isArray(snapshot.tasks)) tasks = snapshot.tasks
        if (Array.isArray(snapshot.events)) events = snapshot.events
        unreadCount = Number(snapshot.unread_count !== undefined
            ? snapshot.unread_count : countUnread(accounts)) || 0
        if (activeAccountId === "" && accounts.length > 0)
            activeAccountId = accountId(accounts[0])
    }

    function countUnread(items) {
        let total = 0
        const list = Array.isArray(items) ? items : []
        for (let i = 0; i < list.length; ++i)
            total += Number(list[i].unread_count || list[i].unread || 0)
        return total
    }

    function loadInitial() {
        offline = !rpc.connected
        if (!rpc.connected || initialLoadInFlight) return
        initialLoadInFlight = true
        loadSnapshot()
        loadAccounts()
    }

    function loadSnapshot() {
        rpc.request(rpc.methods.snapshot, {}, function(result, error) {
            if (error) {
                root.offline = !root.rpc.connected
                if (!root.offline) root.errorText = error.message || "Could not load the dashboard"
                return
            }
            root.offline = false
            root.applySnapshot(result || ({}))
        })
    }

    function loadAccounts(preserveSelection) {
        const generation = ++accountsRequestGeneration
        rpc.request(rpc.methods.accounts, {}, function(result, error) {
            if (generation !== root.accountsRequestGeneration) return
            root.initialLoadInFlight = false
            if (error) {
                root.offline = !root.rpc.connected
                return
            }
            root.offline = false
            const list = root.normalizeArray(result, "accounts")
            root.accounts = list
            root.accountsLoaded = true
            if (root.activeAccountId !== "" && !root.findById(list, root.activeAccountId))
                root.activeAccountId = ""
            if (root.activeAccountId === "" && list.length > 0) {
                root.activeAccountId = root.accountId(list[0])
            }
            if (root.activeAccountId === "") {
                ++root.mailboxesRequestGeneration
                ++root.messageListGeneration
                ++root.readerGeneration
                root.folders = []
                root.messages = []
                root.selectedMessage = null
                root.loading = false
                root.loadingMore = false
                root.readerLoading = false
                root.mailboxesLoading = false
                return
            }
            root.loadMailboxes(function() {
                if (root.draftsOpen) root.loadDrafts()
                else root.loadMessages(true, preserveSelection === true)
                if (!root.automaticSyncStarted) {
                    root.automaticSyncStarted = true
                    Qt.callLater(function() { root.syncAccount("") })
                }
            })
        })
    }

    function reloadAll(preserveSelection) {
        if (!rpc.connected) {
            offline = true
            initialLoadInFlight = false
            return
        }
        // Starting a fresh accounts generation makes any pre-resync account
        // response harmless. The nested mailbox/message loaders carry their
        // own generation and active-account guards.
        initialLoadInFlight = true
        loadSnapshot()
        loadAccounts(preserveSelection === true)
    }

    function loadMailboxes(callback) {
        if (activeAccountId === "") {
            if (typeof callback === "function") callback()
            return
        }
        const requestedAccountId = activeAccountId
        const generation = ++mailboxesRequestGeneration
        mailboxesLoading = true
        rpc.request(rpc.methods.mailboxes, { accountId: requestedAccountId }, function(result, error) {
            if (generation !== root.mailboxesRequestGeneration
                    || requestedAccountId !== root.activeAccountId) return
            root.mailboxesLoading = false
            if (!error) {
                root.folders = root.normalizeArray(result, "mailboxes").filter(function(mailbox) {
                    const owner = String(mailbox.accountId || mailbox.account_id || "")
                    return owner === requestedAccountId
                })
                if (root.folders.length > 0) {
                    let preferred = null
                    for (let i = 0; i < root.folders.length; ++i) {
                        if (String(root.folders[i].role || "") === "inbox") {
                            preferred = root.folders[i]
                            break
                        }
                    }
                    if (!root.findById(root.folders, root.activeFolderId))
                        root.activeFolderId = String((preferred || root.folders[0]).id || "")
                }
            } else {
                root.errorText = error.message || "Could not load mailboxes"
                root.offline = !root.rpc.connected
            }
            if (typeof callback === "function") callback()
        })
    }

    function loadMessages(reset, preserveSelection) {
        if (activeAccountId === "") return
        if (!reset && (loading || loadingMore)) return
        const requestedAccountId = activeAccountId
        const requestedMailboxId = activeFolderId
        const requestedSearch = searchText
        const selectedId = reset && preserveSelection ? messageId(selectedMessage) : ""
        const generation = reset ? ++messageListGeneration : messageListGeneration
        if (reset) {
            loading = true
            loadingMore = false
            nextCursor = ""
            if (!preserveSelection) {
                selectedMessage = null
                readerLoading = false
                ++readerGeneration
            }
        } else {
            if (nextCursor === "") return
            loadingMore = true
        }
        errorText = ""
        rpc.request(rpc.methods.mailList, {
            accountId: requestedAccountId,
            mailboxId: requestedMailboxId || null,
            search: requestedSearch || null,
            cursor: reset ? null : nextCursor,
            limit: 50
        }, function(result, error) {
            if (generation !== root.messageListGeneration
                    || requestedAccountId !== root.activeAccountId
                    || requestedMailboxId !== root.activeFolderId
                    || requestedSearch !== root.searchText) return
            root.loading = false
            root.loadingMore = false
            if (error) {
                root.errorText = error.message || "Could not load messages"
                root.offline = !root.rpc.connected
                return
            }
            root.offline = false
            const page = root.normalizeArray(result, "messages").filter(function(message) {
                return root.belongsToAccount(message, requestedAccountId)
            })
            root.messages = reset ? page : root.messages.concat(page)
            if (selectedId !== "" && root.selectedMessage
                    && root.messageId(root.selectedMessage) === selectedId) {
                let summary = null
                for (let i = 0; i < page.length; ++i) {
                    if (root.messageId(page[i]) === selectedId) {
                        summary = page[i]
                        break
                    }
                }
                if (summary) root.selectedMessage = Object.assign({}, root.selectedMessage, summary)
                else {
                    root.selectedMessage = null
                    root.readerLoading = false
                    ++root.readerGeneration
                }
            }
            root.nextCursor = String(result && (result.next_cursor || result.nextCursor) || "")
            if (result && Array.isArray(result.folders)) {
                root.folders = result.folders.filter(function(mailbox) {
                    return String(mailbox.accountId || mailbox.account_id || "")
                        === requestedAccountId
                })
            }
        })
    }

    function selectAccount(id) {
        if (activeAccountId === String(id)) return
        ++messageListGeneration
        ++readerGeneration
        activeAccountId = String(id)
        activeFolderId = ""
        folders = []
        messages = []
        selectedMessage = null
        readerLoading = false
        loading = false
        loadingMore = false
        nextCursor = ""
        loadMailboxes(function() {
            if (root.draftsOpen) root.loadDrafts()
            else root.loadMessages(true)
        })
    }

    function selectFolder(id) {
        draftsOpen = false
        if (activeFolderId === String(id)) return
        activeFolderId = String(id)
        loadMessages(true)
    }

    function folderIdForRole(role) {
        const expectedRole = String(role || "").toLowerCase()
        if (expectedRole === "") return ""
        const list = Array.isArray(folders) ? folders : []
        for (let i = 0; i < list.length; ++i) {
            if (String(list[i].role || "").toLowerCase() !== expectedRole) continue
            return String(list[i].id || list[i].folder_id || "")
        }
        return ""
    }

    function selectFolderRole(role) {
        const id = folderIdForRole(role)
        if (id === "") return false
        selectFolder(id)
        return true
    }

    function search(query) {
        searchText = String(query || "").trim()
        loadMessages(true)
    }

    function openMessage(message) {
        const id = messageId(message)
        const requestedAccountId = activeAccountId
        if (id === "" || !belongsToAccount(message, requestedAccountId)) return
        const generation = ++readerGeneration
        draftsOpen = false
        selectedMessage = message
        readerLoading = true
        if (message.unread === true || message.is_read === false || message.read === false)
            markRead(message, true)
        rpc.request(rpc.methods.mailGet, {
            messageId: id
        }, function(result, error) {
            if (generation !== root.readerGeneration
                    || requestedAccountId !== root.activeAccountId
                    || !root.selectedMessage
                    || root.messageId(root.selectedMessage) !== id) return
            root.readerLoading = false
            if (error) {
                root.errorText = error.message || "Could not open this message"
                return
            }
            if (result) {
                const detail = result.message || result
                if (root.belongsToAccount(detail, requestedAccountId))
                    root.selectedMessage = detail
            }
        })
    }

    function patchMessage(id, changes) {
        const list = messages.slice()
        for (let i = 0; i < list.length; ++i) {
            if (messageId(list[i]) !== String(id)) continue
            const copy = Object.assign({}, list[i], changes)
            list[i] = copy
            if (selectedMessage && messageId(selectedMessage) === String(id))
                selectedMessage = Object.assign({}, selectedMessage, changes)
            break
        }
        messages = list
    }

    function removeMessage(id) {
        messages = messages.filter(message => messageId(message) !== String(id))
        if (selectedMessage && messageId(selectedMessage) === String(id)) selectedMessage = null
        messageListChangedByAction()
    }

    function mutate(method, message, params, optimistic, remove) {
        const id = messageId(message)
        if (id === "" || !belongsToAccount(message, activeAccountId)) {
            errorText = "This message does not belong to the active account"
            return
        }
        if (remove) removeMessage(id)
        else if (optimistic) patchMessage(id, optimistic)
        rpc.request(method, params || ({}), function(result, error) {
            if (error) {
                root.errorText = error.message || "That action could not be completed"
                root.loadMessages(true, !remove)
            }
        })
    }

    function markRead(message, read) {
        mutate(rpc.methods.mailAction, message,
            { kind: "mark_read", messageIds: [messageId(message)], read: read },
            { unread: !read, is_read: read, read: read }, false)
    }

    function toggleStar(message) {
        const starred = !(message.starred === true || message.is_starred === true)
        mutate(rpc.methods.mailAction, message,
            { kind: "star", messageIds: [messageId(message)], starred: starred },
            { starred: starred, is_starred: starred }, false)
    }

    function archive(message) {
        mutate(rpc.methods.mailAction, message,
            { kind: "archive", messageIds: [messageId(message)] }, null, true)
    }
    function trash(message) {
        mutate(rpc.methods.mailAction, message,
            { kind: "trash", messageIds: [messageId(message)] }, null, true)
    }

    function sync(callback) {
        syncAccount(activeAccountId, callback)
    }

    function syncAccount(accountIdOverride, callback) {
        if (syncing) {
            if (typeof callback === "function")
                Qt.callLater(function() { callback({ accepted: true, alreadyRunning: true }, null) })
            return
        }
        const requestedAccountId = String(accountIdOverride || "")
        syncing = true
        rpc.requestConnected(rpc.methods.syncStart,
            { accountId: requestedAccountId || null }, function(result, error) {
            if (error) {
                root.syncing = false
                root.errorText = error.message || "Sync could not start"
            } else if (!result || result.completed === true
                    || result.backgroundStarted !== true) {
                root.syncing = false
            }
            if (typeof callback === "function") callback(result, error)
        })
    }

    function runPeriodicSync() {
        if (!rpc.connected || !accountsLoaded || accounts.length === 0
                || offline || syncing) return false
        syncAccount("")
        return true
    }

    function addressValue(value) {
        if (value === undefined || value === null) return ""
        if (typeof value === "object")
            return String(value.address || value.email || "").trim()
        let text = String(value).trim()
        const bracketed = text.match(/<([^<>]+)>/)
        if (bracketed && bracketed.length > 1) text = bracketed[1].trim()
        return text
    }

    function addressValues(value) {
        const source = Array.isArray(value) ? value : [value]
        const values = []
        for (let i = 0; i < source.length; ++i) {
            if (typeof source[i] === "string" && /[,;]/.test(source[i])) {
                const pieces = source[i].split(/[,;]/)
                for (let j = 0; j < pieces.length; ++j) {
                    const piece = addressValue(pieces[j])
                    if (piece !== "") values.push(piece)
                }
            } else {
                const address = addressValue(source[i])
                if (address !== "") values.push(address)
            }
        }
        return values
    }

    function appendUniqueAddress(target, seen, value, excluded) {
        const address = addressValue(value)
        const key = address.toLowerCase()
        if (address === "" || key === excluded || seen[key]) return
        seen[key] = true
        target.push(address)
    }

    function htmlToPlainText(value) {
        return String(value || "")
            .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
            .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
            .replace(/<\s*br\s*\/?\s*>/gi, "\n")
            .replace(/<\/(p|div|li|tr|h[1-6])\s*>/gi, "\n")
            .replace(/<li\b[^>]*>/gi, "• ")
            .replace(/<[^>]+>/g, "")
            .replace(/&nbsp;/gi, " ")
            .replace(/&amp;/gi, "&")
            .replace(/&lt;/gi, "<")
            .replace(/&gt;/gi, ">")
            .replace(/&quot;/gi, "\"")
            .replace(/&#39;|&apos;/gi, "'")
            .replace(/\n{3,}/g, "\n\n")
            .trim()
    }

    function messageBodyText(message) {
        const source = message || ({})
        const plain = String(source.bodyText || source.body_text || source.text
            || source.body || "")
        if (plain !== "") return plain
        const html = String(source.bodyHtml || source.body_html || "")
        if (html !== "") return htmlToPlainText(html)
        return String(source.snippet || "")
    }

    function forwardedBody(message) {
        const source = message || ({})
        const lines = ["", "", "---------- Forwarded message ----------"]
        const sender = addressValue(source.author || source.from_address || source.from)
        const recipients = addressValues(source.to_display || source.to).join(", ")
        const timestamp = source.date_display || source.received_display
            || source.timestamp || source.received_at || ""
        if (sender !== "") lines.push("From: " + sender)
        if (timestamp !== "") lines.push("Date: " + String(timestamp))
        if (source.subject) lines.push("Subject: " + String(source.subject))
        if (recipients !== "") lines.push("To: " + recipients)
        lines.push("")
        lines.push(messageBodyText(source))
        return lines.join("\n")
    }

    function startCompose(replyMode, message) {
        const source = message || ({})
        let to = ""
        let cc = ""
        let subject = ""
        let bodyText = ""
        if (replyMode === "reply" || replyMode === "reply_all") {
            const replyAddress = addressValue(source.reply_to || source.replyTo
                || source.author || source.from_address || source.from)
            if (replyMode === "reply_all") {
                const selfAddress = addressValue(activeAccount).toLowerCase()
                const seen = ({})
                const toAddresses = []
                const ccAddresses = []
                appendUniqueAddress(toAddresses, seen, replyAddress, selfAddress)
                const originalTo = addressValues(source.to)
                for (let i = 0; i < originalTo.length; ++i)
                    appendUniqueAddress(toAddresses, seen, originalTo[i], selfAddress)
                const originalCc = addressValues(source.cc)
                for (let i = 0; i < originalCc.length; ++i)
                    appendUniqueAddress(ccAddresses, seen, originalCc[i], selfAddress)
                to = toAddresses.join(", ")
                cc = ccAddresses.join(", ")
            } else {
                to = replyAddress
            }
            subject = String(source.subject || "")
            if (!/^re:/i.test(subject)) subject = "Re: " + subject
        } else if (replyMode === "forward") {
            subject = String(source.subject || "")
            if (!/^fwd:/i.test(subject)) subject = "Fwd: " + subject
            bodyText = forwardedBody(source)
        }
        ++composeGeneration
        draftsOpen = false
        composeDraft = {
            accountId: activeAccountId,
            mode: replyMode || "compose",
            inReplyTo: replyMode === "reply" || replyMode === "reply_all"
                ? messageId(source) || null : null,
            to: to,
            cc: cc,
            bcc: "",
            subject: subject,
            bodyText: bodyText
        }
        view = "compose"
    }

    function closeCompose() {
        ++composeGeneration
        composeDraft = ({})
        view = "mail"
    }

    function decodeMailtoPart(value, plusAsSpace) {
        let encoded = String(value || "")
        if (plusAsSpace) encoded = encoded.replace(/\+/g, " ")
        try {
            return decodeURIComponent(encoded)
        } catch (error) {
            return ""
        }
    }

    function composeMailto(uri) {
        const text = String(uri || "")
        if (!/^mailto:/i.test(text) || text.length > 262144) return false
        const payload = text.substring(7)
        const separator = payload.indexOf("?")
        const path = separator < 0 ? payload : payload.substring(0, separator)
        const query = separator < 0 ? "" : payload.substring(separator + 1)
        const fields = { to: decodeMailtoPart(path, false), cc: "", bcc: "", subject: "", bodyText: "" }
        const pairs = query === "" ? [] : query.split("&")
        for (let i = 0; i < pairs.length; ++i) {
            const equals = pairs[i].indexOf("=")
            const rawKey = equals < 0 ? pairs[i] : pairs[i].substring(0, equals)
            const rawValue = equals < 0 ? "" : pairs[i].substring(equals + 1)
            const key = decodeMailtoPart(rawKey, true).toLowerCase()
            const value = decodeMailtoPart(rawValue, true)
            if (key === "to" || key === "cc" || key === "bcc") {
                fields[key] = fields[key] === "" ? value : fields[key] + ", " + value
            } else if (key === "subject" || key === "body") {
                fields[key === "body" ? "bodyText" : key] = value
            }
        }
        ++composeGeneration
        draftsOpen = false
        composeDraft = {
            accountId: activeAccountId,
            mode: "compose",
            inReplyTo: null,
            to: fields.to,
            cc: fields.cc,
            bcc: fields.bcc,
            subject: fields.subject,
            bodyText: fields.bodyText
        }
        view = "compose"
        return true
    }

    function saveDraft(draft, callback) {
        const generation = composeGeneration
        rpc.request(rpc.methods.draftSave, {
            draftId: composeDraft.draftId || null,
            message: draft
        }, function(result, error) {
            if (!error && generation === root.composeGeneration && root.view === "compose") {
                const saved = result && (result.draft || result)
                const draftId = String(saved && (saved.draftId || saved.draft_id) || "")
                if (draftId !== "")
                    root.composeDraft = Object.assign({}, root.composeDraft, { draftId: draftId })
            }
            if (typeof callback === "function") callback(result, error)
        })
    }

    function draftId(draft) {
        return String(draft ? (draft.draftId || draft.draft_id || draft.id || "") : "")
    }

    function loadDrafts() {
        const requestedAccountId = activeAccountId
        const generation = ++draftsRequestGeneration
        draftsLoading = true
        rpc.request(rpc.methods.draftList,
            { accountId: requestedAccountId || null }, function(result, error) {
            if (generation !== root.draftsRequestGeneration
                    || requestedAccountId !== root.activeAccountId) return
            root.draftsLoading = false
            if (error) {
                root.errorText = error.message || "Could not load saved drafts"
                root.offline = !root.rpc.connected
                return
            }
            const list = root.normalizeArray(result, "drafts")
            root.drafts = list.filter(function(draft) {
                if (requestedAccountId === "") return true
                const message = draft && draft.message || ({})
                return String(message.accountId || message.account_id || "")
                    === requestedAccountId
            })
        })
    }

    function openDrafts() {
        ++readerGeneration
        selectedMessage = null
        readerLoading = false
        draftsOpen = true
        view = "mail"
        loadDrafts()
    }

    function closeDrafts() {
        draftsOpen = false
    }

    function openDraft(draft) {
        const id = draftId(draft)
        if (id === "") {
            errorText = "This draft has no identifier"
            return
        }
        const requestedAccountId = activeAccountId
        const generation = ++draftOpenGeneration
        rpc.request(rpc.methods.draftGet, { draftId: id }, function(result, error) {
            if (generation !== root.draftOpenGeneration
                    || requestedAccountId !== root.activeAccountId) return
            if (error) {
                root.errorText = error.message || "Could not open this draft"
                return
            }
            const record = result && (result.draft || result)
            const message = record && record.message || ({})
            const account = String(message.accountId || message.account_id || "")
            if (requestedAccountId !== "" && account !== requestedAccountId) {
                root.errorText = "This draft does not belong to the active account"
                return
            }
            ++root.composeGeneration
            root.composeDraft = Object.assign({}, message, {
                draftId: root.draftId(record) || id,
                mode: "draft"
            })
            root.draftsOpen = false
            root.view = "compose"
        })
    }

    function deleteDraft(draft, callback) {
        const id = draftId(draft)
        if (id === "") {
            if (typeof callback === "function")
                callback(null, { message: "This draft has no identifier" })
            return
        }
        rpc.requestConnected(rpc.methods.draftDelete, { draftId: id }, function(result, error) {
            if (!error)
                root.drafts = root.drafts.filter(item => root.draftId(item) !== id)
            if (typeof callback === "function") callback(result, error)
        })
    }

    function addAccount(values, callback) {
        rpc.requestConnected(rpc.methods.accountAdd, values || ({}), callback)
    }

    function reauthAccount(account, callback) {
        rpc.requestConnected(rpc.methods.accountReauth, {
            accountId: accountId(account)
        }, callback)
    }

    function removeAccount(account, callback) {
        rpc.requestConnected(rpc.methods.accountRemove,
            { accountId: accountId(account) }, function(result, error) {
            if (!error) {
                root.activeAccountId = ""
                root.folders = []
                root.messages = []
                root.drafts = []
                root.loadAccounts()
            }
            if (typeof callback === "function") callback(result, error)
        })
    }

    function downloadAttachment(attachment, openWhenReady, callback) {
        if (!selectedMessage || !attachment
                || !belongsToAccount(selectedMessage, activeAccountId)) {
            if (typeof callback === "function")
                callback(null, { message: "Select an attachment from the active account" })
            return
        }
        const attachmentId = String(attachment.id || attachment.attachmentId
            || attachment.attachment_id || "")
        if (attachmentId === "") {
            if (typeof callback === "function")
                callback(null, { message: "This attachment has no download identifier" })
            return
        }
        rpc.request(rpc.methods.attachmentDownload, {
            messageId: messageId(selectedMessage),
            attachmentId: attachmentId,
            disposition: openWhenReady ? "open" : "download"
        }, function(result, error) {
            if (typeof callback === "function") callback(result, error)
        })
    }

    function saveAttachmentTo(source, destination, callback) {
        if (typeof attachmentSaveHandler !== "function") {
            if (typeof callback === "function")
                callback({ message: "Attachment saving is unavailable" })
            return
        }
        attachmentSaveHandler(String(source || ""), String(destination || ""), callback)
    }

    function sendMessage(draft, callback) {
        const outgoingAccountId = String(draft && draft.accountId || "")
        if (outgoingAccountId === "" || !findById(accounts, outgoingAccountId)) {
            if (typeof callback === "function")
                callback(null, { message: "Choose a valid sending account" })
            return
        }
        rpc.requestConnected(rpc.methods.messageSend, draft, function(result, error) {
            if (!error) root.closeCompose()
            if (typeof callback === "function") callback(result, error)
        })
    }

    property Connections rpcConnections: Connections {
        target: rpc
        function onConnectionReady() {
            root.offline = false
            root.loadInitial()
        }
        function onConnectionLost() {
            root.offline = true
            root.initialLoadInFlight = false
            root.automaticSyncStarted = false
            root.syncing = false
        }
        function onNotification(method, params) {
            if (method === rpc.events.snapshot) root.applySnapshot(params.snapshot || params)
            else if (method === rpc.events.mail) {
                // Account counts and the title badge live in the dashboard /
                // account results, not the mailbox page alone.
                root.reloadAll(true)
            }
            else if (method === rpc.events.account) {
                root.accountStateChanged({ method: method, params: params || ({}) })
                root.reloadAll(false)
            }
            else if (method === rpc.events.agenda) {
                root.loadSnapshot()
            }
            else if (method === rpc.events.resyncRequired) {
                root.reloadAll(true)
            }
            else if (method === rpc.events.sync) {
                const state = String(params && (params.status || params.state) || "")
                const remaining = Number(params && params.backgroundRemaining || 0)
                root.syncing = state !== "error" && params
                    && (params.running === true || remaining > 0 || state === "running")
                if (state === "error") {
                    root.errorText = String(params.error || "Mail synchronization failed")
                    root.syncing = false
                }
            }
        }
    }

    // A local Unix socket can connect before a sibling QML component has
    // finished installing its signal handlers. Recover that startup race, and
    // any later missed reconnect edge, without polling once state is healthy.
    property Timer connectionRecoveryTimer: Timer {
        interval: 500
        repeat: true
        running: !root.accountsLoaded || root.offline
        onTriggered: {
            if (root.rpc.connected) root.loadInitial()
        }
    }

    property Timer periodicSyncTimer: Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.rpc.connected && root.accountsLoaded && root.accounts.length > 0
        onTriggered: root.runPeriodicSync()
    }

    Component.onCompleted: loadInitial()
}
