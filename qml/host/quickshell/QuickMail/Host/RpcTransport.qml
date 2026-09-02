import QtQuick
import Quickshell.Io as QuickshellIo

QtObject {
    id: root

    readonly property string defaultSocketPath: {
        const runtimeDir = String(PlatformBridge.env("XDG_RUNTIME_DIR") || "").trim()
        return runtimeDir.startsWith("/")
            ? runtimeDir + "/quickmail/daemon.sock" : ""
    }
    property string path: defaultSocketPath
    property bool _connected: false
    readonly property bool connected: _connected

    signal lineReceived(string line)
    signal connectionStateChanged()
    signal errorOccurred(string error)

    function connectSocket() {
        socket.connected = true
    }

    function disconnectSocket() {
        socket.connected = false
    }

    function write(data) {
        socket.write(String(data))
        socket.flush()
    }

    property QuickshellIo.Socket socket: QuickshellIo.Socket {
        path: root.path
        parser: QuickshellIo.SplitParser {
            splitMarker: "\n"
            onRead: data => root.lineReceived(data)
        }
        onConnectionStateChanged: {
            root._connected = socket.connected
            root.connectionStateChanged()
        }
        onError: error => root.errorOccurred(String(error))
    }
}
