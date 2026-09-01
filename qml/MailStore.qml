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
    property var threadMessages: []
    property string activeThreadId: ""
    property bool threadLoading: false
    property bool threadTruncated: false
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
    property bool agendaLoading: false
    property bool agendaMutationPending: false
    property bool accountsLoaded: false
    property bool initialLoadInFlight: false
    property bool automaticSyncStarted: false
    property string errorText: ""
    property string view: "mail" // mail | compose | calendar
    property var composeDraft: ({})
    property var attachmentSaveHandler: null
    property int accountsRequestGeneration: 0
    property int mailboxesRequestGeneration: 0
    property int messageListGeneration: 0
    property int readerGeneration: 0
    property int threadGeneration: 0
    property int threadLoadSerial: 0
    property int composeGeneration: 0
    property int draftsRequestGeneration: 0
    property int draftOpenGeneration: 0
    property int agendaRequestGeneration: 0
    property int avatarEpoch: 0
    property int avatarFetchInFlight: 0
    readonly property int avatarFetchLimit: 4
    property var avatarPaths: ({})
    property var avatarFailures: ({})
    property var avatarWaiters: ({})
    property var avatarQueue: []
    property var avatarTokenUrls: ({})
    property int nextAvatarToken: 1

    readonly property var activeAccount: findById(accounts, activeAccountId)
    readonly property var activeFolder: findById(folders, activeFolderId)
    readonly property bool hasMore: nextCursor !== ""
    readonly property var conversations: buildConversations(messages)

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

    function messageMailboxId(message) {
        return String(message ? (message.mailboxId || message.mailbox_id || "") : "")
    }

    function belongsToAccount(message, id) {
        const owner = messageAccountId(message)
        return owner !== "" && owner === String(id)
    }

    function messageThreadId(message) {
        return String(message ? (message.threadId || message.thread_id || "") : "")
    }

    function threadKey(message) {
        const id = messageThreadId(message)
        return id !== "" ? id : messageId(message)
    }

    function isUnread(message) {
        return message && (message.unread === true
            || message.is_read === false || message.read === false)
    }

    function senderName(message) {
        return String(message && (message.from_name || message.sender_name
            || (message.author && (message.author.name || message.author.address))
            || message.from || message.from_address) || "Unknown sender")
    }

    function buildConversations(source) {
        const list = Array.isArray(source) ? source : []
        const result = []
        const indexes = ({})
        for (let i = 0; i < list.length; ++i) {
            const message = list[i]
            const key = threadKey(message)
            if (key === "") continue
            const lookupKey = "$" + key
            let index = indexes[lookupKey]
            if (index === undefined) {
                const first = Object.assign({}, message, {
                    conversationKey: key,
                    conversationCount: 1,
                    conversationMessageIds: [messageId(message)],
                    conversationSenders: [senderName(message)],
                    conversationUnreadCount: isUnread(message) ? 1 : 0
                })
                indexes[lookupKey] = result.length
                result.push(first)
                continue
            }
            const conversation = result[index]
            const ids = conversation.conversationMessageIds.slice()
            const id = messageId(message)
            if (ids.indexOf(id) < 0) ids.push(id)
            const senders = conversation.conversationSenders.slice()
            const sender = senderName(message)
            if (senders.indexOf(sender) < 0) senders.push(sender)
            const unreadCount = Number(conversation.conversationUnreadCount || 0)
                + (isUnread(message) ? 1 : 0)
            result[index] = Object.assign({}, conversation, {
                conversationCount: Number(conversation.conversationCount || 1) + 1,
                conversationMessageIds: ids,
                conversationSenders: senders,
                conversationUnreadCount: unreadCount,
                read: unreadCount === 0,
                is_read: unreadCount === 0,
                unread: unreadCount > 0,
                starred: conversation.starred === true || message.starred === true,
                hasAttachments: conversation.hasAttachments === true
                    || conversation.has_attachments === true
                    || message.hasAttachments === true
                    || message.has_attachments === true
            })
        }
        return result
    }

    function clearThread() {
        ++threadGeneration
        ++threadLoadSerial
        threadMessages = []
        activeThreadId = ""
        threadLoading = false
        threadTruncated = false
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

    function openCalendar() {
        draftsOpen = false
        view = "calendar"
        loadAgenda()
    }

    function openMailSurface() {
        if (view === "compose") return
        view = "mail"
    }

    function loadAgenda() {
        if (!rpc.connected || agendaLoading) return
        const generation = ++agendaRequestGeneration
        agendaLoading = true
        let remaining = 2
        let firstError = null
        function finish(error) {
            if (generation !== root.agendaRequestGeneration) return
            if (error) {
                firstError = firstError || error
            }
            remaining -= 1
            if (remaining > 0) return
            root.agendaLoading = false
            root.offline = !root.rpc.connected
            if (firstError)
                root.errorText = firstError.message || "Could not load the calendar"
        }
        rpc.request(rpc.methods.taskList, { includeDone: true }, function(result, error) {
            if (generation !== root.agendaRequestGeneration) return
            if (!error) root.tasks = root.normalizeArray(result, "tasks")
            finish(error)
        })
        const now = new Date()
        const rangeStart = new Date(now.getFullYear() - 1, 0, 1).getTime()
        const rangeEnd = new Date(now.getFullYear() + 2, 0, 1).getTime()
        rpc.request(rpc.methods.calendarList,
            { startAt: rangeStart, endAt: rangeEnd }, function(result, error) {
                if (generation !== root.agendaRequestGeneration) return
                if (!error) root.events = root.normalizeArray(result, "events")
                finish(error)
            })
    }

    function syncAgenda(accountIdValue) {
        if (!rpc.connected || agendaLoading) return
        agendaLoading = true
        errorText = ""
        rpc.requestConnected(rpc.methods.agendaSync,
            { accountId: String(accountIdValue || "") || null }, function(result, error) {
                root.agendaLoading = false
                if (error) {
                    root.offline = !root.rpc.connected
                    root.errorText = error.message || "Calendar synchronization failed"
                    return
                }
                const errors = result && Array.isArray(result.errors) ? result.errors : []
                if (errors.length > 0)
                    root.errorText = String(errors[0].message || "One calendar account needs attention")
                root.loadAgenda()
            })
    }

    function agendaAccount(accountIdValue) {
        return findById(accounts, String(accountIdValue || ""))
    }

    function agendaProvider(accountIdValue) {
        const account = agendaAccount(accountIdValue)
        return String(account && account.provider || "local").toLowerCase()
    }

    function createTask(payload, callback) {
        const accountIdValue = String(payload && payload.account || "")
        const provider = agendaProvider(accountIdValue)
        const due = Number(payload && payload.dueAt || 0)
        const task = {
            id: "",
            title: String(payload && payload.title || "").trim(),
            description: String(payload && payload.description || "").trim(),
            done: false,
            dueAt: due > 0 ? due : null,
            createdAt: Date.now(),
            source: accountIdValue === "" ? "local"
                : provider === "gmail" ? "google_tasks"
                : (provider === "outlook" || provider === "hotmail"
                    || provider === "microsoft365") ? "microsoft_todo" : provider,
            externalId: "",
            account: accountIdValue
        }
        if (task.title === "") {
            if (typeof callback === "function")
                callback(null, { message: "Task title is required" })
            return
        }
        agendaMutationPending = true
        rpc.requestConnected(rpc.methods.taskCreate, task, function(result, error) {
            root.agendaMutationPending = false
            if (error) root.errorText = error.message || "Could not create the task"
            else root.loadAgenda()
            if (typeof callback === "function") callback(result, error)
        })
    }

    function completeTask(task, completed, callback) {
        const id = String(task && task.id || "")
        if (id === "") return
        agendaMutationPending = true
        rpc.requestConnected(rpc.methods.taskComplete,
            { taskId: id, done: completed === true }, function(result, error) {
                root.agendaMutationPending = false
                if (error) root.errorText = error.message || "Could not update the task"
                else root.loadAgenda()
                if (typeof callback === "function") callback(result, error)
            })
    }

    function deleteTask(task, callback) {
        const id = String(task && task.id || "")
        if (id === "") return
        agendaMutationPending = true
        rpc.requestConnected(rpc.methods.taskDelete, { taskId: id }, function(result, error) {
            root.agendaMutationPending = false
            if (error) root.errorText = error.message || "Could not delete the task"
            else root.loadAgenda()
            if (typeof callback === "function") callback(result, error)
        })
    }

    function createCalendarEvent(payload, callback) {
        const accountIdValue = String(payload && payload.calendarId || "")
        const account = agendaAccount(accountIdValue)
        const start = Number(payload && payload.startAt || 0)
        const end = Number(payload && payload.endAt || 0)
        const event = {
            id: "",
            externalId: "",
            calendarId: accountIdValue === "" ? "local" : accountIdValue,
            calendarName: accountIdValue === "" ? "Local"
                : String(account && (account.displayName || account.address) || "Account"),
            title: String(payload && payload.title || "").trim(),
            description: String(payload && payload.description || "").trim(),
            startAt: start,
            endAt: Math.max(start, end),
            allDay: payload && payload.allDay === true,
            readOnly: false
        }
        if (event.title === "" || start <= 0 || end < start) {
            if (typeof callback === "function")
                callback(null, { message: "Choose a title and a valid event time" })
            return
        }
        agendaMutationPending = true
        rpc.requestConnected(rpc.methods.calendarCreate, event, function(result, error) {
            root.agendaMutationPending = false
            if (error) root.errorText = error.message || "Could not create the event"
            else root.loadAgenda()
            if (typeof callback === "function") callback(result, error)
        })
    }

    function deleteCalendarEvent(event, callback) {
        const id = String(event && event.id || "")
        if (id === "") return
        agendaMutationPending = true
        rpc.requestConnected(rpc.methods.calendarDelete, { eventId: id }, function(result, error) {
            root.agendaMutationPending = false
            if (error) root.errorText = error.message || "Could not delete the event"
            else root.loadAgenda()
            if (typeof callback === "function") callback(result, error)
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
                root.clearThread()
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
                clearThread()
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
        clearThread()
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
        draftsOpen = false
        activeThreadId = threadKey(message)
        threadMessages = [message]
        threadTruncated = false
        const conversationGeneration = ++threadGeneration
        const shouldMarkRead = isUnread(message)
        // Queue the cached message body and conversation lookup before the
        // provider mutation. Even though JSON-RPC responses are correlated by
        // ID, this ordering also keeps the reader responsive with older or
        // strictly serial daemon implementations.
        openThreadMessage(message, true)
        loadThread(id, conversationGeneration, requestedAccountId)
        if (shouldMarkRead) markRead(message, true)
    }

    function loadThread(messageIdValue, generation, requestedAccountId) {
        const serial = ++threadLoadSerial
        threadLoading = true
        rpc.request(rpc.methods.threadGet, { messageId: messageIdValue }, function(result, error) {
            if (generation !== root.threadGeneration
                    || serial !== root.threadLoadSerial
                    || requestedAccountId !== root.activeAccountId) return
            root.threadLoading = false
            if (error) {
                // Reading one message remains useful if the cache does not yet
                // have enough ancestry to assemble a conversation.
                return
            }
            const list = root.normalizeArray(result, "messages").filter(function(item) {
                return root.belongsToAccount(item, requestedAccountId)
            })
            if (list.length > 0) root.threadMessages = list
            root.activeThreadId = String(result && result.id || root.activeThreadId)
            root.threadTruncated = result && result.truncated === true
        })
    }

    function openThreadMessage(message, deferReadMutation) {
        const id = messageId(message)
        const requestedAccountId = activeAccountId
        if (id === "" || !belongsToAccount(message, requestedAccountId)) return
        const shouldMarkRead = isUnread(message)
        const generation = ++readerGeneration
        selectedMessage = message
        readerLoading = true
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
                if (root.belongsToAccount(detail, requestedAccountId)) {
                    const actionIds = []
                    const addActionId = function(value) {
                        const candidate = String(value || "")
                        if (candidate !== "" && actionIds.indexOf(candidate) < 0)
                            actionIds.push(candidate)
                    }
                    const actionMailbox = root.messageMailboxId(message)
                        || root.activeFolderId
                    const originalIds = Array.isArray(message.conversationMessageIds)
                        ? message.conversationMessageIds : []
                    for (let i = 0; i < originalIds.length; ++i)
                        addActionId(originalIds[i])
                    for (let i = 0; i < root.threadMessages.length; ++i) {
                        const member = root.threadMessages[i]
                        if (root.messageMailboxId(member) === actionMailbox)
                            addActionId(root.messageId(member))
                    }
                    addActionId(id)
                    const readState = shouldMarkRead
                        ? { unread: false, is_read: true, read: true } : ({})
                    const conversationDetail = Object.assign({}, detail,
                        { conversationMessageIds: actionIds }, readState)
                    root.selectedMessage = conversationDetail
                    root.patchThreadMessage(id, conversationDetail)
                    const detailThread = root.threadKey(conversationDetail)
                    if (root.threadMessages.length <= 1
                            && detailThread !== root.activeThreadId) {
                        root.activeThreadId = detailThread
                        root.loadThread(id, root.threadGeneration, requestedAccountId)
                    }
                }
            }
        })
        if (shouldMarkRead && deferReadMutation !== true)
            markRead(message, true)
    }

    function patchThreadMessage(id, changes) {
        const list = threadMessages.slice()
        for (let i = 0; i < list.length; ++i) {
            if (messageId(list[i]) !== String(id)) continue
            list[i] = Object.assign({}, list[i], changes)
            threadMessages = list
            return
        }
    }

    function actionMessageIds(message) {
        const source = message && Array.isArray(message.conversationMessageIds)
            ? message.conversationMessageIds : [messageId(message)]
        const result = []
        for (let i = 0; i < source.length; ++i) {
            const id = String(source[i] || "")
            if (id !== "" && result.indexOf(id) < 0) result.push(id)
        }
        return result
    }

    function patchMessage(id, changes) {
        patchMessages([id], changes)
    }

    function patchMessages(ids, changes) {
        const list = messages.slice()
        for (let i = 0; i < list.length; ++i) {
            if (ids.indexOf(messageId(list[i])) < 0) continue
            const copy = Object.assign({}, list[i], changes)
            list[i] = copy
        }
        messages = list
        const thread = threadMessages.slice()
        for (let i = 0; i < thread.length; ++i) {
            if (ids.indexOf(messageId(thread[i])) >= 0)
                thread[i] = Object.assign({}, thread[i], changes)
        }
        threadMessages = thread
        if (selectedMessage && ids.indexOf(messageId(selectedMessage)) >= 0)
            selectedMessage = Object.assign({}, selectedMessage, changes)
    }

    function removeMessage(id) {
        removeMessages([id])
    }

    function removeMessages(ids) {
        messages = messages.filter(message => ids.indexOf(messageId(message)) < 0)
        threadMessages = threadMessages.filter(message => ids.indexOf(messageId(message)) < 0)
        if (selectedMessage && ids.indexOf(messageId(selectedMessage)) >= 0) {
            selectedMessage = null
            clearThread()
        }
        messageListChangedByAction()
    }

    function mutate(method, message, params, optimistic, remove) {
        const id = messageId(message)
        if (id === "" || !belongsToAccount(message, activeAccountId)) {
            errorText = "This message does not belong to the active account"
            return
        }
        const ids = actionMessageIds(message)
        if (remove) removeMessages(ids)
        else if (optimistic) patchMessages(ids, optimistic)
        const requestParams = Object.assign({}, params || ({}), { messageIds: ids })
        rpc.request(method, requestParams, function(result, error) {
            if (error) {
                root.errorText = error.message || "That action could not be completed"
                root.loadMessages(true, !remove)
            }
        })
    }

    function markRead(message, read) {
        mutate(rpc.methods.mailAction, message,
            { kind: "mark_read", read: read },
            { unread: !read, is_read: read, read: read }, false)
    }

    function toggleStar(message) {
        const starred = !(message.starred === true || message.is_starred === true)
        mutate(rpc.methods.mailAction, message,
            { kind: "star", starred: starred },
            { starred: starred, is_starred: starred }, false)
    }

    function archive(message) {
        mutate(rpc.methods.mailAction, message,
            { kind: "archive" }, null, true)
    }
    function trash(message) {
        mutate(rpc.methods.mailAction, message,
            { kind: "trash" }, null, true)
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
        // A new attempt supersedes the previous synchronization error. If it
        // fails, the callback/event below will replace this with the new cause.
        errorText = ""
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
        clearThread()
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
                root.clearThread()
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

    function resolveAvatar(url, callback) {
        const candidate = String(url || "").trim()
        if (candidate.length === 0 || candidate.length > 2048
                || !candidate.toLowerCase().startsWith("https://")) {
            invokeAvatarCallback(callback, "", { message: "Invalid avatar URL" })
            return 0
        }
        const key = "$" + candidate
        if (avatarPaths[key] !== undefined) {
            invokeAvatarCallback(callback, String(avatarPaths[key]), null)
            return 0
        }
        const failedAt = Number(avatarFailures[key] || 0)
        if (failedAt > 0 && Date.now() - failedAt < 5 * 60 * 1000) {
            invokeAvatarCallback(callback, "", { message: "Avatar is unavailable" })
            return 0
        }

        const token = nextAvatarToken++
        const waiter = { token: token, callback: callback }
        const waiters = Object.assign({}, avatarWaiters)
        if (Array.isArray(waiters[key])) {
            const callbacks = waiters[key].slice()
            callbacks.push(waiter)
            waiters[key] = callbacks
            avatarWaiters = waiters
            const tokenUrls = Object.assign({}, avatarTokenUrls)
            tokenUrls["$" + token] = candidate
            avatarTokenUrls = tokenUrls
            return token
        }
        waiters[key] = [waiter]
        avatarWaiters = waiters
        const tokenUrls = Object.assign({}, avatarTokenUrls)
        tokenUrls["$" + token] = candidate
        avatarTokenUrls = tokenUrls
        const queued = avatarQueue.slice()
        queued.push(candidate)
        avatarQueue = queued
        processAvatarQueue()
        return avatarTokenUrls["$" + token] !== undefined ? token : 0
    }

    function invokeAvatarCallback(callback, source, error) {
        if (typeof callback !== "function") return
        callback(source, error)
    }

    function cancelAvatar(token) {
        const tokenKey = "$" + Number(token || 0)
        const candidate = String(avatarTokenUrls[tokenKey] || "")
        if (candidate === "") return false
        const tokenUrls = Object.assign({}, avatarTokenUrls)
        delete tokenUrls[tokenKey]
        avatarTokenUrls = tokenUrls

        const key = "$" + candidate
        const callbacks = Array.isArray(avatarWaiters[key])
            ? avatarWaiters[key].filter(function(waiter) {
                return Number(waiter && waiter.token || 0) !== Number(token)
            }) : []
        const waiters = Object.assign({}, avatarWaiters)
        if (callbacks.length > 0) waiters[key] = callbacks
        else delete waiters[key]
        avatarWaiters = waiters
        if (callbacks.length === 0) {
            avatarQueue = avatarQueue.filter(function(url) {
                return String(url) !== candidate
            })
        }
        return true
    }

    function processAvatarQueue() {
        while (avatarFetchInFlight < avatarFetchLimit && avatarQueue.length > 0) {
            const queued = avatarQueue.slice()
            const candidate = queued.shift()
            avatarQueue = queued
            ++avatarFetchInFlight
            startAvatarRequest(candidate)
        }
    }

    function startAvatarRequest(candidate) {
        if (!rpc.connected) {
            finishAvatarRequest(candidate, "",
                { message: "QuickMail is offline" }, false)
            return
        }
        rpc.requestConnected(rpc.methods.avatarFetch, { url: candidate },
            function(result, error) {
                const source = error ? "" : localAvatarSource(result)
                const invalidResult = !error && source === ""
                    ? { message: "The avatar cache returned an invalid path" } : error
                finishAvatarRequest(candidate, source, invalidResult,
                    shouldCacheAvatarFailure(invalidResult))
            })
    }

    function shouldCacheAvatarFailure(error) {
        const code = Number(error && error.code)
        return code === -32602 || code === -32021
            || code === -32022 || code === -32023
    }

    function localAvatarSource(result) {
        const path = String(result && result.path || "")
        if (path.length === 0 || path.length > 4096 || path[0] !== "/"
                || /[\u0000-\u001f\u007f-\u009f]/.test(path)) return ""
        return encodeURI("file://" + path)
    }

    function finishAvatarRequest(url, source, error, cacheFailure) {
        const key = "$" + String(url || "")
        if (source !== "") {
            const paths = Object.assign({}, avatarPaths)
            paths[key] = source
            avatarPaths = paths
            const failures = Object.assign({}, avatarFailures)
            delete failures[key]
            avatarFailures = failures
        } else if (cacheFailure) {
            const failures = Object.assign({}, avatarFailures)
            failures[key] = Date.now()
            avatarFailures = failures
        }

        const callbacks = Array.isArray(avatarWaiters[key])
            ? avatarWaiters[key].slice() : []
        const waiters = Object.assign({}, avatarWaiters)
        delete waiters[key]
        avatarWaiters = waiters
        avatarFetchInFlight = Math.max(0, avatarFetchInFlight - 1)
        const tokenUrls = Object.assign({}, avatarTokenUrls)
        for (let index = 0; index < callbacks.length; ++index) {
            const waiter = callbacks[index] || ({})
            delete tokenUrls["$" + Number(waiter.token || 0)]
            invokeAvatarCallback(waiter.callback, source, error)
        }
        avatarTokenUrls = tokenUrls
        Qt.callLater(function() { root.processAvatarQueue() })
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
            ++root.avatarEpoch
            root.loadInitial()
        }
        function onConnectionLost() {
            root.offline = true
            root.initialLoadInFlight = false
            ++root.agendaRequestGeneration
            root.agendaLoading = false
            root.agendaMutationPending = false
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
