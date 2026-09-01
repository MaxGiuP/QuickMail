import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 760
    height: 560
    color: Theme.canvas
    property int originalZoomPercent: 100
    property bool originalThemeColors: true
    property string originalDocument: ""
    property real originalRenderedHeight: 0
    property real expectedScrollRatio: 0
    property bool started: false

    function expect(condition, message) {
        if (condition) return
        console.error("READER ZOOM TEST FAILED: " + message)
        Qt.exit(1)
    }

    function longHtml(label) {
        let result = "<div><h2>" + label + "</h2><table style='width:700px'>"
            + "<tr><td>Fixed-width content</td></tr></table>"
        for (let index = 0; index < 80; ++index)
            result += "<p>Reader zoom keeps every part of an HTML message readable.</p>"
        return result + "</div>"
    }

    function longText(label) {
        let result = label
        for (let index = 0; index < 40; ++index)
            result += "\nPlain-text messages use the same persistent reader zoom."
        return result
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
        const resources = object.resources || []
        for (let index = 0; index < resources.length; ++index)
            descendantsWithName(resources[index], name, result)
    }

    function named(object, name) {
        const result = []
        descendantsWithName(object, name, result)
        return result
    }

    QtObject {
        id: store

        property var selectedMessage: ({
            id: "html-a",
            author: { name: "HTML Sender", address: "html@example.test" },
            subject: "Zoomable HTML",
            bodyText: "HTML fallback",
            bodyHtml: window.longHtml("Zoomable HTML"),
            timestamp: "2026-09-01T12:00:00Z"
        })
        property var threadMessages: [selectedMessage]
        property bool threadLoading: false
        property bool threadTruncated: false
        property bool readerLoading: false
        property string errorText: ""
        property int markReadCalls: 0
        property bool lastReadValue: true

        function messageId(message) { return String(message && message.id || "") }
        function messageBodyText(message) {
            return String(message && (message.bodyText || message.snippet) || "")
        }
        function openThreadMessage(message) { selectedMessage = message }
        function archive(message) {}
        function toggleStar(message) {}
        function trash(message) {}
        function markRead(message, read) {
            ++markReadCalls
            lastReadValue = read
        }
        function downloadAttachment(attachment, open, callback) {}
        function saveAttachmentTo(source, destination, callback) {}
    }

    MessageReaderPane {
        id: reader
        width: 760
        height: 300
        store: store
    }

    Timer {
        interval: 20
        running: true
        repeat: true
        onTriggered: {
            if (!AppSettings.ready || window.started) return
            window.started = true
            window.originalZoomPercent = AppSettings.readerZoomPercent
            window.originalThemeColors = AppSettings.useThemeEmailColors
            window.expect(window.originalZoomPercent === 100
                    && window.originalThemeColors,
                "reader preference defaults were not 100% and theme-aware")
            AppSettings.readerZoomPercent = 100
            AppSettings.useThemeEmailColors = true
            stageOne.start()
        }
    }

    Timer {
        id: stageOne
        interval: 180
        repeat: false
        onTriggered: {
            const htmlViews = window.named(reader, "messageHtmlView")
            window.expect(htmlViews.length === 1,
                "the HTML reader was not created")
            if (htmlViews.length !== 1) return
            const htmlView = htmlViews[0]
            window.expect(reader.messageZoomPercent === 100
                    && Math.abs(htmlView.effectiveZoomFactor - 1) < 0.001,
                "reader zoom did not start at 100%")
            const indicator = window.named(reader, "readerZoomIndicator")[0]
            const loader = window.named(reader, "messageHtmlLoader")[0]
            const wheelHandlers = window.named(reader, "readerZoomWheelHandler")
            window.expect(indicator && indicator.visible
                    && indicator.text === "100%" && !indicator.enabled,
                "the stable zoom indicator did not show the default scale")
            window.expect(loader
                    && Math.abs(loader.renderedHeight - htmlView.rendererHeight) < 1,
                "the reader loader did not adopt the HTML document height")
            window.expect(wheelHandlers.length === 1
                    && Number(wheelHandlers[0].acceptedModifiers)
                        === Number(Qt.ControlModifier)
                    && wheelHandlers[0].blocking,
                "the reader-wide Ctrl+wheel handler was missing or misconfigured")
            window.originalDocument = htmlView.renderedHtml
            window.originalRenderedHeight = htmlView.rendererHeight
            reader.setMessageZoomPercent(150)
            stageTwo.start()
        }
    }

    Timer {
        id: stageTwo
        interval: 80
        repeat: false
        onTriggered: {
            const htmlView = window.named(reader, "messageHtmlView")[0]
            const loader = window.named(reader, "messageHtmlLoader")[0]
            window.expect(reader.messageZoomPercent === 150
                    && Math.abs(htmlView.effectiveZoomFactor - 1.5) < 0.001,
                "HTML message did not receive 150% zoom")
            const indicator = window.named(reader, "readerZoomIndicator")[0]
            window.expect(indicator && indicator.text === "150%" && indicator.enabled,
                "the zoom indicator did not update without shifting the toolbar")
            window.expect(htmlView.renderedHtml === window.originalDocument,
                "zoom rebuilt or changed the sanitized HTML document")
            window.expect(htmlView.rendererHeight > window.originalRenderedHeight
                    && loader
                    && Math.abs(loader.renderedHeight - htmlView.rendererHeight) < 1,
                "full-document zoom did not enlarge and reflow the message (height "
                    + window.originalRenderedHeight + " -> "
                    + htmlView.rendererHeight + ")")

            reader.resetZoom()
            window.expect(reader.handleReaderZoomWheel(120, 0,
                    Qt.ControlModifier), "Ctrl+wheel-up was not consumed")
            window.expect(reader.messageZoomPercent === 110,
                "Ctrl+wheel-up did not zoom in by one step")
            window.expect(!reader.handleReaderZoomWheel(-120, 0, Qt.NoModifier)
                    && reader.messageZoomPercent === 110,
                "ordinary wheel scrolling changed reader zoom")
            window.expect(reader.handleReaderZoomWheel(0, -40,
                    Qt.ControlModifier) && reader.messageZoomPercent === 100,
                "high-resolution Ctrl+wheel did not zoom out")

            reader.resetZoomWheelAccumulator()
            for (let index = 0; index < 11; ++index)
                window.expect(reader.handleReaderZoomWheel(10, 0,
                    Qt.ControlModifier), "precision Ctrl+wheel was not consumed")
            window.expect(reader.messageZoomPercent === 100,
                "partial precision-wheel deltas changed zoom too early")
            reader.handleReaderZoomWheel(10, 0, Qt.ControlModifier)
            window.expect(reader.messageZoomPercent === 110,
                "precision-wheel deltas were not accumulated into one zoom step")
            reader.resetZoom()
            window.expect(!reader.handleReaderZoomWheel(0, 0,
                    Qt.ControlModifier), "an empty wheel event was consumed")

            reader.setMessageZoomPercent(999)
            window.expect(reader.messageZoomPercent === 200 && !reader.canZoomIn,
                "maximum reader zoom was not clamped")
            reader.zoomIn()
            window.expect(reader.messageZoomPercent === 200,
                "zoom-in moved beyond the maximum")
            reader.setMessageZoomPercent(-999)
            window.expect(reader.messageZoomPercent === 50 && !reader.canZoomOut,
                "minimum reader zoom was not clamped")
            reader.zoomOut()
            window.expect(reader.messageZoomPercent === 50,
                "zoom-out moved beyond the minimum")
            reader.setMessageZoomPercent(130)
            stageScroll.start()
        }
    }

    Timer {
        id: stageScroll
        interval: 100
        repeat: false
        onTriggered: {
            const flick = window.named(reader, "readerBodyFlick")[0]
            reader.scrollReaderToEnd()
            window.expect(reader.maximumReaderScroll() > 0,
                "long-message fixture was not vertically scrollable (content "
                    + flick.contentHeight + ", viewport " + flick.height + ")")
            reader.scrollReaderToStart()
            reader.scrollReaderPage(1)
            window.expect(flick.contentY > 0,
                "Page Down helper did not advance the reader")
            reader.scrollReaderToStart()
            window.expect(flick.contentY === 0,
                "Home helper did not return to the message start")
            reader.scrollReaderToEnd()
            window.expect(Math.abs(flick.contentY
                    - reader.maximumReaderScroll()) < 1,
                "End helper did not reach the message end")
            const endPosition = flick.contentY
            reader.scrollReaderPage(-1)
            window.expect(flick.contentY < endPosition,
                "Page Up helper did not move toward the message start")

            reader.setReaderScroll(reader.maximumReaderScroll() * 0.45)
            window.expectedScrollRatio = flick.contentY
                / reader.maximumReaderScroll()
            reader.setMessageZoomPercent(140)
            window.expect(reader.messageZoomPercent === 140,
                "mid-message zoom did not update before restoring the scroll")
            stageAnchor.start()
        }
    }

    Timer {
        id: stageAnchor
        interval: 120
        repeat: false
        onTriggered: {
            const flick = window.named(reader, "readerBodyFlick")[0]
            const currentRatio = flick.contentY / reader.maximumReaderScroll()
            window.expect(Math.abs(currentRatio - window.expectedScrollRatio) < 0.08,
                "zooming lost the reader's relative scroll position")
            const sameMessagePosition = flick.contentY
            store.selectedMessage = Object.assign({}, store.selectedMessage,
                { starred: true })
            window.expect(Math.abs(flick.contentY - sameMessagePosition) < 1,
                "a same-message state update reset the reader scroll")
            store.selectedMessage = {
                id: "plain-b",
                author: { name: "Plain Sender", address: "plain@example.test" },
                subject: "Zoomable plain text",
                bodyText: window.longText("Plain text"),
                bodyHtml: "",
                timestamp: "2026-09-01T13:00:00Z"
            }
            stageThree.start()
        }
    }

    Timer {
        id: stageThree
        interval: 100
        repeat: false
        onTriggered: {
            const flicks = window.named(reader, "readerBodyFlick")
            const plainBodies = window.named(reader, "plainMessageBody")
            window.expect(flicks.length === 1 && flicks[0].contentY === 0,
                "opening another message retained the previous scroll position")
            window.expect(reader.messageZoomPercent === 140,
                "switching messages discarded the preferred zoom (got "
                    + reader.messageZoomPercent + "%)")
            window.expect(plainBodies.length === 1 && plainBodies[0].visible
                    && Math.abs(plainBodies[0].font.pixelSize - 21) < 0.01,
                "plain-text message did not share HTML reader zoom (font "
                    + (plainBodies.length ? plainBodies[0].font.pixelSize : -1)
                    + ")")

            plainBodies[0].forceActiveFocus()
            window.expect(reader.readerShortcutsEnabled,
                "reader shortcuts did not activate when the message had focus")
            window.contentItem.forceActiveFocus()
            window.expect(!reader.readerShortcutsEnabled,
                "reader shortcuts remained active in a sibling focus scope")
            plainBodies[0].forceActiveFocus()
            reader.setMessageZoomPercent(160)
            window.expect(Math.abs(plainBodies[0].font.pixelSize - 24) < 0.01,
                "plain-text zoom did not update live")
            reader.setMessageZoomPercent(140)

            reader.markUnread()
            window.expect(store.markReadCalls === 1 && !store.lastReadValue,
                "mark-as-unread did not use the existing read mutation")
            store.selectedMessage = Object.assign({}, store.selectedMessage,
                { unread: true, read: false, is_read: false })
            reader.markUnread()
            window.expect(store.markReadCalls === 1,
                "an already-unread message triggered a redundant mutation")
            reader.enabled = false
            window.expect(!reader.readerShortcutsEnabled,
                "hidden or disabled reader shortcuts remained active")
            reader.enabled = true

            AppSettings.useThemeEmailColors = false
            store.selectedMessage = {
                id: "html-c",
                author: { name: "Original Sender", address: "original@example.test" },
                subject: "Original colours",
                bodyText: "Original colour fallback",
                bodyHtml: "<div style='background:#ffffff;color:#111111'>Original</div>",
                timestamp: "2026-09-01T14:00:00Z"
            }
            stageFour.start()
        }
    }

    Timer {
        id: stageFour
        interval: 100
        repeat: false
        onTriggered: {
            const htmlViews = window.named(reader, "messageHtmlView")
            window.expect(htmlViews.length === 1 && !htmlViews[0].useThemeColors,
                "Reader settings could not restore original email colours")
            AgendaTranslations.localeOverride = "de_DE"
            window.expect(AgendaTranslations.tr("Zoom in") === "Vergrößern"
                    && AgendaTranslations.tr("Mark as unread (Shift+U)")
                        .indexOf("ungelesen") >= 0,
                "German reader controls were not translated")
            AgendaTranslations.localeOverride = "it_IT"
            window.expect(AgendaTranslations.tr("Zoom out") === "Riduci"
                    && AgendaTranslations.tr("Always match app colours")
                        .indexOf("colori") >= 0,
                "Italian reader controls were not translated")
            AgendaTranslations.localeOverride = ""
            store.threadMessages = []
            store.selectedMessage = null
            window.expect(!reader.readerShortcutsEnabled,
                "reader shortcuts remained active without a selected message")
            AppSettings.readerZoomPercent = window.originalZoomPercent
            AppSettings.useThemeEmailColors = window.originalThemeColors
            finishTimer.start()
        }
    }

    Timer {
        id: finishTimer
        interval: 180
        repeat: false
        onTriggered: Qt.quit()
    }

    Timer {
        interval: 3000
        running: true
        repeat: false
        onTriggered: {
            window.expect(false, "reader zoom test timed out")
        }
    }
}
