import QtQuick
import ".."
import "../components"

Item {
    id: root

    width: 620
    height: 760
    property var savedPayload: null
    property var sentPayload: null
    property string originalBody: "Line one\nLine two & <literal>"

    function expect(condition, message) {
        if (condition) return
        console.error("COMPOSE FORMATTING TEST FAILED: " + message)
        Qt.exit(1)
    }

    QtObject {
        id: store

        property var accounts: [{ id: "account-a", address: "a@example.com" }]
        property string activeAccountId: "account-a"
        property string view: "compose"
        property var composeDraft: ({
            mode: "compose",
            accountId: "account-a",
            to: [{ name: "", address: "person@example.com" }],
            cc: [],
            bcc: [],
            subject: "Formatted message",
            bodyText: root.originalBody,
            bodyHtml: null,
            inReplyTo: null
        })

        function startCompose(mode, message) {}
        function composeMailto(uri) { return false }
        function closeCompose() { view = "mail" }
        function deleteDraft(draft, callback) { callback({}, null) }
        function saveDraft(draft, callback) {
            root.savedPayload = draft
            composeDraft = Object.assign({}, composeDraft, { draftId: "draft-rich" })
            callback({ draft: { draftId: "draft-rich" } }, null)
        }
        function sendMessage(draft, callback) {
            root.sentPayload = draft
            closeCompose()
            callback({}, null)
        }
    }

    ComposePane {
        id: composer
        anchors.fill: parent
        store: store
        open: store.view === "compose"
    }

    Timer {
        interval: 100
        running: true
        repeat: false
        onTriggered: {
            root.expect(composer.editorBodyText === root.originalBody,
                "plain draft line breaks or literal markup changed on load")
            root.expect(composer.editorBodyHtml.indexOf("&lt;literal&gt;") >= 0
                    && composer.editorBodyHtml.indexOf("<literal>") < 0,
                "plain draft markup was interpreted as HTML")

            const toolbarState = composer.formattingExpanded
            AppSettings.composeFormattingExpanded = !toolbarState
            root.expect(composer.formattingExpanded === !toolbarState,
                "formatting toolbar visibility was not adjustable")
            AppSettings.composeFormattingExpanded = toolbarState

            composer.selectBodyText(0, 4)
            composer.formatBodyBold()
            composer.selectBodyText(0, 4)
            composer.formatBodyUnderline()
            composer.selectBodyText(0, 4)
            composer.formatBodySize(18)
            composer.selectBodyText(0, 4)
            composer.formatBodyColor("#ef5350")
            composer.selectBodyText(14, 17)
            composer.highlightBody("#fff2a8")

            root.expect(composer.editorBodyText === root.originalBody,
                "formatting changed the message's plain-text fallback")
            root.expect(composer.editorBodyHtml.indexOf("font-weight:700") >= 0,
                "bold formatting was not retained as HTML")
            root.expect(composer.editorBodyHtml.indexOf("text-decoration: underline") >= 0,
                "underline formatting was not retained as HTML")
            root.expect(composer.editorBodyHtml.indexOf("font-size:18px") >= 0,
                "adjustable text size was not retained as HTML")
            root.expect(composer.editorBodyHtml.indexOf("color:#ef5350") >= 0,
                "text colour was not retained as HTML")
            root.expect(composer.editorBodyHtml.indexOf("background-color:#fff2a8") >= 0,
                "highlight colour was not retained as HTML")

            composer.save(false)
            root.expect(root.savedPayload !== null
                    && root.savedPayload.bodyText === root.originalBody
                    && String(root.savedPayload.bodyHtml).indexOf("font-weight:700") >= 0,
                "rich HTML and plain text were not saved together")

            composer.selectBodyText(0, 4)
            root.expect(composer.clearBodyFormatting(),
                "clear formatting rejected selected text")
            root.expect(composer.editorBodyText === root.originalBody
                    && composer.editorBodyHtml.indexOf("font-weight:700") < 0,
                "clear formatting damaged text or retained bold styling")

            store.view = "mail"
            store.composeDraft = Object.assign({}, root.savedPayload, {
                draftId: "draft-rich", mode: "draft"
            })
            store.view = "compose"
        }
    }

    Timer {
        interval: 220
        running: true
        repeat: false
        onTriggered: {
            root.expect(composer.editorBodyHtml.indexOf("font-weight:700") >= 0
                    && composer.editorBodyText === root.originalBody,
                "reopened draft lost rich formatting or its plain fallback")
            composer.send()
            root.expect(root.sentPayload !== null
                    && root.sentPayload.bodyText === root.originalBody
                    && String(root.sentPayload.bodyHtml).indexOf("font-weight:700") >= 0,
                "send payload omitted rich HTML or plain text")
            Qt.quit()
        }
    }
}
