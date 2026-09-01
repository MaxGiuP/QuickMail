import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 620
    height: 360
    color: "#111318"

    readonly property int messageCount: 80
    readonly property int viewportAvatarLimit: Math.ceil(height / 56) + 4
    property var messages: makeMessages()

    function makeMessages() {
        const result = []
        for (let index = 0; index < messageCount; ++index) {
            result.push({
                id: "message-" + index,
                author: {
                    name: "Sender " + index,
                    address: "sender-" + index + "@example.com"
                },
                subject: "A long conversation",
                snippet: "Message preview " + index,
                bodyText: "Message body",
                bodyHtml: "",
                timestamp: "2026-09-01T17:59:00Z"
            })
        }
        return result
    }

    function expect(condition, message) {
        if (condition) return
        console.error("READER AVATAR LAZY TEST FAILED: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
    }

    function named(object, name) {
        const result = []
        descendantsWithName(object, name, result)
        return result
    }

    function activeAvatarLoaders(reader) {
        return named(reader, "threadCardAvatarLoader").filter(function(loader) {
            return loader.active
        })
    }

    QtObject {
        id: testStore

        property var selectedMessage: window.messages[0]
        property var threadMessages: window.messages
        property bool threadLoading: false
        property bool threadTruncated: false
        property bool readerLoading: false
        property string errorText: ""

        function messageId(message) { return String(message && message.id || "") }
        function messageBodyText(message) { return String(message && message.bodyText || "") }
        function openThreadMessage(message) { selectedMessage = message }
        function archive(message) {}
        function toggleStar(message) {}
        function trash(message) {}
        function downloadAttachment(attachment, open, callback) {}
        function saveAttachmentTo(source, destination, callback) {}
    }

    MessageReaderPane {
        id: reader
        anchors.fill: parent
        store: testStore

        Component.onCompleted: {
            const loaders = window.named(reader, "threadCardAvatarLoader")
            const active = window.activeAvatarLoaders(reader)
            const avatars = window.named(reader, "threadCardAvatar")
            window.expect(loaders.length === window.messageCount,
                "the full thread fixture did not create its delegate loaders")
            window.expect(reader.threadAvatarLayoutReady === false,
                "the reader did not defer avatars until its first layout polish")
            window.expect(active.length === 0,
                "initial layout activated " + active.length
                    + " avatar loaders before their positions were final")
            window.expect(avatars.length === 0,
                "initial layout instantiated " + avatars.length
                    + " avatars before their positions were final")
            settledCheck.start()
        }
    }

    Timer {
        id: settledCheck
        interval: 250
        repeat: false
        onTriggered: {
            const active = window.activeAvatarLoaders(reader)
            const avatars = window.named(reader, "threadCardAvatar")
            window.expect(reader.threadAvatarLayoutReady === true,
                "the avatar layout gate did not open after layout polish")
            window.expect(active.length > 0,
                "the settled viewport did not activate any avatar loaders")
            window.expect(active.length <= window.viewportAvatarLimit,
                "the settled viewport retained too many active avatar loaders")
            window.expect(avatars.length === active.length
                    && avatars.length <= window.viewportAvatarLimit,
                "the settled reader instantiated offscreen avatars")
            Qt.quit()
        }
    }
}
