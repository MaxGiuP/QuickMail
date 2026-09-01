import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    // Keep every daemon method/event string in this file. The Rust RPC contract
    // can evolve without making the visual components provider-aware.
    readonly property var methods: ({
        snapshot: "dashboard.snapshot",
        subscribe: "subscribe",
        accounts: "accounts.list",
        accountAdd: "accounts.add",
        accountRemove: "accounts.remove",
        accountReauth: "accounts.reauth",
        mailboxes: "mailboxes.list",
        mailList: "mail.list",
        mailGet: "mail.get",
        threadGet: "thread.get",
        mailAction: "mail.action",
        draftSave: "draft.save",
        draftList: "draft.list",
        draftGet: "draft.get",
        draftDelete: "draft.delete",
        messageSend: "mail.send",
        attachmentDownload: "attachment.download",
        taskList: "task.list",
        taskCreate: "task.create",
        taskUpdate: "task.update",
        taskComplete: "task.complete",
        taskDelete: "task.delete",
        calendarList: "calendar.list",
        calendarCreate: "calendar.create",
        calendarUpdate: "calendar.update",
        calendarDelete: "calendar.delete",
        agendaSync: "agenda.sync",
        syncStart: "sync.start"
    })
    readonly property var events: ({
        snapshot: "snapshot.changed",
        mail: "mail.changed",
        sync: "sync.changed",
        account: "accounts.changed",
        agenda: "agenda.changed",
        resyncRequired: "system.resync_required"
    })

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    property string socketPath: runtimeDir + "/quickmail/daemon.sock"
    property bool connectRequested: false
    readonly property bool connected: socket.connected
    property bool connecting: !connected && connectRequested
    property string lastError: ""
    property int nextId: 1
    property int retryAttempt: 0
    property int retryDelayMs: 500
    property var pending: ({})
    property var writeQueue: []

    signal notification(string method, var params)
    signal connectionReady()
    signal connectionLost()

    // Account setup can contain passwords. Keep those requests out of the
    // reconnect queue so plaintext credentials are not retained in QML memory
    // or submitted later without a fresh user action.
    function requestConnected(method, params, callback) {
        if (!socket.connected) {
            scheduleReconnect()
            if (typeof callback === "function") {
                Qt.callLater(function() {
                    callback(null, {
                        code: -32000,
                        message: "QuickMail is offline. Reconnect, then try again."
                    })
                })
            }
            return -1
        }
        return request(method, params, callback)
    }

    function request(method, params, callback) {
        const id = nextId++
        const frame = JSON.stringify({
            jsonrpc: "2.0",
            id: id,
            method: String(method),
            params: params || ({})
        }) + "\n"
        const callbacks = pending
        callbacks[String(id)] = typeof callback === "function" ? callback : null
        pending = callbacks
        if (socket.connected) {
            socket.write(frame)
            socket.flush()
        } else {
            const queued = writeQueue.slice()
            queued.push(frame)
            writeQueue = queued
            scheduleReconnect()
        }
        return id
    }

    function failPending(message) {
        const callbacks = pending
        pending = ({})
        writeQueue = []
        const error = { code: -32000, message: String(message || "Mail service unavailable") }
        const keys = Object.keys(callbacks)
        for (let i = 0; i < keys.length; ++i) {
            const callback = callbacks[keys[i]]
            if (typeof callback === "function") callback(null, error)
        }
    }

    function notify(method, params) {
        // A true JSON-RPC notification: the daemon dispatches this id-less
        // frame without generating a response.
        const frame = JSON.stringify({
            jsonrpc: "2.0",
            method: String(method),
            params: params || ({})
        }) + "\n"
        if (socket.connected) {
            socket.write(frame)
            socket.flush()
        } else {
            const queued = writeQueue.slice()
            queued.push(frame)
            writeQueue = queued
            scheduleReconnect()
        }
    }

    function handleLine(line) {
        const raw = String(line || "").trim()
        if (raw === "") return
        let message
        try {
            message = JSON.parse(raw)
        } catch (error) {
            lastError = "The mail service sent an invalid response"
            return
        }
        if (Array.isArray(message)) {
            for (let i = 0; i < message.length; ++i) handleMessage(message[i])
        } else {
            handleMessage(message)
        }
    }

    function handleMessage(message) {
        if (!message || message.jsonrpc !== "2.0") return
        if (message.method !== undefined) {
            notification(String(message.method), message.params || ({}))
            return
        }
        if (message.id === undefined || message.id === null) return
        const key = String(message.id)
        const callback = pending[key]
        const callbacks = pending
        delete callbacks[key]
        pending = callbacks
        if (typeof callback === "function")
            callback(message.result, message.error || null)
    }

    function flushQueue() {
        if (!socket.connected || writeQueue.length === 0) return
        const queued = writeQueue
        writeQueue = []
        for (let i = 0; i < queued.length; ++i) socket.write(queued[i])
        socket.flush()
    }

    function subscribeToEvents() {
        request(methods.subscribe, { topics: ["mail", "accounts", "sync", "agenda"] })
    }

    function scheduleReconnect() {
        if (reconnectTimer.running) return
        connectRequested = false
        if (socket.connected) socket.connected = false
        retryDelayMs = Math.min(30000, 500 * Math.pow(2, Math.min(retryAttempt, 6)))
        retryAttempt += 1
        reconnectTimer.interval = retryDelayMs
        reconnectTimer.restart()
    }

    function attemptConnect() {
        connectRequested = true
        socket.connected = true
    }

    property Socket socket: Socket {
        id: socket
        path: root.socketPath
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handleLine(data)
        }
        onConnectionStateChanged: {
            // The Socket notify signal fires before bindings which mirror its
            // state (including root.connected) are reevaluated. Read the
            // socket directly or a successful connection is mistaken for a
            // disconnect and immediately torn down.
            if (socket.connected) {
                Qt.callLater(function() {
                    if (!socket.connected) return
                    root.retryAttempt = 0
                    root.retryDelayMs = 500
                    root.lastError = ""
                    root.flushQueue()
                    root.subscribeToEvents()
                    root.connectionReady()
                })
            } else {
                root.failPending("The QuickMail service disconnected")
                root.connectionLost()
                root.scheduleReconnect()
            }
        }
        onError: error => {
            root.lastError = "Mail service unavailable"
            root.scheduleReconnect()
        }
    }

    property Timer reconnectTimer: Timer {
        id: reconnectTimer
        repeat: false
        onTriggered: root.attemptConnect()
    }

    Component.onCompleted: attemptConnect()
}
