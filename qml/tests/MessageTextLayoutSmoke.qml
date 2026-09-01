import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 900
    height: 680
    color: "#11151b"

    readonly property string hostileSender: "LinkedIn Job\r\nAlerts\tvia   Example"
    readonly property string hostileSubject: "Junior Automation Engineer\nApply faster than normal\rInjected subject"
    readonly property string hostileSnippet: "First preview line\nSecond preview line\r\n"
        + "Third preview line that must never paint into the next fixed-height row "
        + "even when it is much wider than the available message list."

    function expect(condition, message) {
        if (condition) return
        console.error("MESSAGE TEXT LAYOUT TEST FAILED: " + message)
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

    function expectSingleLine(label, description) {
        const value = String(label.text || "")
        expect(value.indexOf("\n") < 0 && value.indexOf("\r") < 0
            && value.indexOf("\t") < 0, description + " retained control whitespace")
        expect(label.lineCount === 1, description + " rendered more than one line")
        expect(label.maximumLineCount === 1,
            description + " is not constrained to a single line")
        expect(label.clip === true, description + " can paint outside its bounds")
    }

    QtObject {
        id: store

        property var selectedMessage: ({
            id: "message-a",
            author: { name: window.hostileSender, address: "sender@example.test" },
            subject: window.hostileSubject,
            snippet: window.hostileSnippet,
            bodyText: "Message body",
            bodyHtml: "",
            timestamp: "2026-09-01T17:59:00Z"
        })
        property var threadMessages: [selectedMessage, ({
            id: "message-b",
            author: { name: "Second\nThread Sender", address: "second@example.test" },
            subject: "Re: " + window.hostileSubject,
            snippet: window.hostileSnippet,
            bodyText: "Earlier body",
            timestamp: "invalid timestamp\nwith a forged second line"
        })]
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

    MessageRow {
        id: messageRow
        x: 12
        y: 12
        width: 370
        message: ({
            conversationSenders: [window.hostileSender, "Another\nSender"],
            conversationCount: 12,
            author: { name: window.hostileSender, address: "alerts@example.test" },
            subject: window.hostileSubject,
            snippet: window.hostileSnippet,
            timestamp: "invalid timestamp\nforged"
        })
    }

    MessageRow {
        id: followingRow
        x: messageRow.x
        y: messageRow.y + messageRow.height + 2
        width: messageRow.width
        message: ({
            from_name: "Following row",
            subject: "This row must remain unobscured",
            snippet: "No previous-row text may overlap this content."
        })
    }

    MessageReaderPane {
        id: reader
        x: 400
        y: 12
        width: 480
        height: 650
        store: store
    }

    Timer {
        interval: 350
        running: true
        repeat: false
        onTriggered: {
            window.expect(messageRow.clip, "the fixed-height message row does not clip")
            window.expect(messageRow.sender === "LinkedIn Job Alerts via Example, Another Sender",
                "conversation senders were not normalized")
            window.expect(messageRow.subject
                    === "Junior Automation Engineer Apply faster than normal Injected subject",
                "the message subject was not normalized")
            window.expect(messageRow.snippet.indexOf("First preview line Second preview line Third") === 0,
                "the message preview was not normalized")

            const rowContents = window.named(messageRow, "messageRowContent")
            window.expect(rowContents.length === 1,
                "could not inspect the message-row spacing")
            if (rowContents.length === 1) {
                const rowContent = rowContents[0]
                window.expect(rowContent.x >= Theme.space3,
                    "message text is too close to the left edge")
                window.expect(messageRow.width - rowContent.x - rowContent.width
                        >= Theme.space3,
                    "message text is too close to the right edge")
            }

            const rowNames = ["messageRowSender", "messageRowSubject", "messageRowSnippet"]
            for (let rowIndex = 0; rowIndex < rowNames.length; ++rowIndex) {
                const labels = window.named(messageRow, rowNames[rowIndex])
                window.expect(labels.length === 1,
                    "could not inspect " + rowNames[rowIndex])
                if (labels.length === 1)
                    window.expectSingleLine(labels[0], rowNames[rowIndex])
            }

            const cards = window.named(reader, "threadCard")
            window.expect(cards.length === 2, "the thread-card fixture did not render")
            for (let cardIndex = 0; cardIndex < cards.length; ++cardIndex)
                window.expect(cards[cardIndex].clip,
                    "a fixed-height thread card does not clip")

            const threadSenders = window.named(reader, "threadCardSender")
            const threadSnippets = window.named(reader, "threadCardSnippet")
            window.expect(threadSenders.length === 2 && threadSnippets.length === 2,
                "thread sender/preview labels were not rendered")
            for (let index = 0; index < threadSenders.length; ++index)
                window.expectSingleLine(threadSenders[index], "thread sender")
            for (let index = 0; index < threadSnippets.length; ++index)
                window.expectSingleLine(threadSnippets[index], "thread preview")

            const rowAvatars = window.named(messageRow, "messageRowAvatar")
            const headerAvatars = window.named(reader, "messageHeaderAvatar")
            const threadAvatars = window.named(reader, "threadCardAvatar")
            window.expect(rowAvatars.length === 1
                    && rowAvatars[0].address === "alerts@example.test",
                "the message row did not receive the sender address for its avatar")
            window.expect(headerAvatars.length === 1
                    && headerAvatars[0].address === "sender@example.test",
                "the reader header did not receive the selected sender avatar")
            window.expect(threadAvatars.length === 2
                    && threadAvatars[1].address === "second@example.test",
                "thread cards did not receive their own sender avatars")

            window.expect(followingRow.y >= messageRow.y + messageRow.height,
                "the following-row fixture is not below the hostile row")
            Qt.quit()
        }
    }
}
