import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 1040
    height: 720
    color: "#111318"

    readonly property var threadFixture: [{
        id: "message-oldest",
        author: { name: "Alex Rivera", address: "alex@example.test" },
        subject: "Quarterly planning",
        snippet: "The first message in the conversation.",
        bodyText: "First body",
        timestamp: "2026-09-01T08:00:00Z",
        read: false
    }, {
        id: "message-current",
        author: { name: "Jamie Chen", address: "jamie@example.test" },
        subject: "Re: Quarterly planning",
        snippet: "The currently open reply.",
        bodyText: "Current body",
        timestamp: "2026-09-01T09:00:00Z",
        read: true
    }, {
        id: "message-newest",
        author: { name: "Morgan Lee", address: "morgan@example.test" },
        subject: "Re: Quarterly planning",
        snippet: "The newest unread reply.",
        bodyText: "Newest body",
        timestamp: "2026-09-01T10:00:00Z",
        read: false
    }]

    function expect(condition, message) {
        if (condition) return
        console.error("QML SMOKE TEST FAILED: thread presentation: " + message)
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

    function visibleNamed(object, name) {
        return named(object, name).filter(function(item) { return item.visible })
    }

    function textContains(item, expected) {
        return String(item && item.text || "").toLowerCase()
            .indexOf(String(expected).toLowerCase()) >= 0
    }

    function accessibleNameContains(item, expected) {
        return String(item && item.Accessible.name || "").toLowerCase()
            .indexOf(String(expected).toLowerCase()) >= 0
    }

    QtObject {
        id: store

        property var selectedMessage: window.threadFixture[1]
        property var threadMessages: window.threadFixture
        property bool threadLoading: false
        property bool threadTruncated: false
        property bool readerLoading: false
        property string errorText: ""
        property int avatarEpoch: 1

        function messageId(message) { return String(message && message.id || "") }
        function messageBodyText(message) { return String(message && message.bodyText || "") }
        function openThreadMessage(message) { selectedMessage = message }
        function archive(message) {}
        function toggleStar(message) {}
        function trash(message) {}
        function downloadAttachment(attachment, open, callback) {}
        function saveAttachmentTo(source, destination, callback) {}
    }

    MessageRow {
        id: threadedRow
        x: 16
        y: 16
        width: 390
        selected: true
        message: ({
            id: "conversation-quarterly",
            conversationCount: 3,
            conversationUnreadCount: 2,
            conversationSenders: ["Alex Rivera", "Jamie Chen", "Morgan Lee"],
            author: { name: "Morgan Lee", address: "morgan@example.test" },
            subject: "Quarterly planning",
            snippet: "Three people replied to the planning thread.",
            timestamp: "2026-09-01T10:00:00Z",
            read: false
        })
    }

    MessageRow {
        id: singletonRow
        x: threadedRow.x
        y: threadedRow.y + threadedRow.height + 8
        width: threadedRow.width
        message: ({
            id: "single-message",
            conversationCount: 1,
            author: { name: "Solo Sender", address: "solo@example.test" },
            subject: "One standalone message",
            snippet: "This is not a conversation.",
            timestamp: "2026-09-01T11:00:00Z",
            read: true
        })
    }

    MessageReaderPane {
        id: reader
        x: 430
        y: 16
        width: window.width - x - 16
        height: window.height - 32
        store: store
    }

    Timer {
        interval: 300
        running: true
        repeat: false
        onTriggered: {
            const threadedBadges = window.visibleNamed(
                threadedRow, "messageRowThreadBadge")
            const singletonBadges = window.visibleNamed(
                singletonRow, "messageRowThreadBadge")
            window.expect(threadedBadges.length === 1,
                "a multi-message list row has no explicit thread badge")
            window.expect(singletonBadges.length === 0,
                "a singleton list row was presented as a thread")

            const badgeLabels = window.visibleNamed(
                threadedRow, "messageRowThreadBadgeText")
            window.expect(badgeLabels.length === 1
                    && window.textContains(badgeLabels[0], "3"),
                "the list thread badge does not expose its message count")
            window.expect(threadedRow.Accessible.role === Accessible.ListItem,
                "the threaded message row is not exposed as a list item")
            window.expect(threadedRow.Accessible.selected === true,
                "the selected conversation is not exposed as selected")
            window.expect(window.accessibleNameContains(threadedRow, "3 messages")
                    && window.accessibleNameContains(threadedRow, "Quarterly planning")
                    && window.accessibleNameContains(threadedRow, "Unread"),
                "the threaded row accessible name omits count, subject, or unread state")
            window.expect(singletonRow.Accessible.role === Accessible.ListItem
                    && !window.accessibleNameContains(singletonRow, "2 messages")
                    && !window.accessibleNameContains(singletonRow, "3 messages"),
                "the singleton row has incorrect accessible conversation semantics")

            const banners = window.visibleNamed(reader, "threadConversationBannerText")
            window.expect(banners.length === 1
                    && window.textContains(banners[0], "conversation")
                    && window.textContains(banners[0], "3"),
                "the reader has no explicit three-message conversation banner")

            const cards = window.named(reader, "threadCard")
            window.expect(cards.length === 3,
                "the reader timeline did not render all three messages")
            for (let index = 0; index < cards.length; ++index) {
                const role = cards[index].Accessible.role
                window.expect(role === Accessible.ListItem || role === Accessible.Button,
                    "thread timeline item " + index + " has no actionable accessible role")
                window.expect(window.accessibleNameContains(cards[index],
                        (index + 1) + " of 3")
                        && window.accessibleNameContains(cards[index],
                            window.threadFixture[index].author.name),
                    "thread timeline item " + index
                        + " omits its position or sender from its accessible name")
                if (index > 0)
                    window.expect(cards[index].y > cards[index - 1].y,
                        "thread timeline items are not displayed in chronological order")
            }

            const currentMarkers = window.visibleNamed(reader, "threadCardCurrentMarker")
            window.expect(currentMarkers.length === 1,
                "the timeline does not have exactly one visible current-message marker")
            window.expect(window.visibleNamed(cards[1], "threadCardCurrentMarker").length === 1
                    && cards[1].Accessible.selected === true
                    && cards[0].Accessible.selected !== true
                    && cards[2].Accessible.selected !== true,
                "the current marker or accessible selection is on the wrong message")

            window.expect(window.visibleNamed(reader, "threadCardUnreadMarker").length === 2
                    && window.visibleNamed(cards[0], "threadCardUnreadMarker").length === 1
                    && window.visibleNamed(cards[1], "threadCardUnreadMarker").length === 0
                    && window.visibleNamed(cards[2], "threadCardUnreadMarker").length === 1,
                "the timeline unread markers do not match the message read states")

            store.openThreadMessage(window.threadFixture[0])
            movedSelectionCheck.start()
        }
    }

    Timer {
        id: movedSelectionCheck
        interval: 40
        repeat: false
        onTriggered: {
            const cards = window.named(reader, "threadCard")
            window.expect(window.visibleNamed(cards[0], "threadCardCurrentMarker").length === 1
                    && window.visibleNamed(cards[1], "threadCardCurrentMarker").length === 0
                    && cards[0].Accessible.selected === true
                    && cards[1].Accessible.selected !== true,
                "the current marker and accessible selection did not follow the open message")
            cards[2].forceActiveFocus()
            focusCheck.start()
        }
    }

    Timer {
        id: focusCheck
        interval: 40
        repeat: false
        onTriggered: {
            const cards = window.named(reader, "threadCard")
            window.expect(cards[2].activeFocus === true && cards[2].border.width >= 2,
                "keyboard focus on a timeline message is not visibly outlined")
            store.threadTruncated = true
            truncatedCountCheck.start()
        }
    }

    Timer {
        id: truncatedCountCheck
        interval: 40
        repeat: false
        onTriggered: {
            const cards = window.named(reader, "threadCard")
            const positions = window.visibleNamed(cards[2], "threadCardPosition")
            window.expect(window.accessibleNameContains(cards[2], "at least 3")
                    && positions.length === 1
                    && window.textContains(positions[0], "3+"),
                "a truncated timeline presented its bounded count as exact")
            Qt.quit()
        }
    }
}
