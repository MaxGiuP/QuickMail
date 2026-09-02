import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 760
    height: 720
    color: Theme.canvas
    property string originalLocale: ""

    function expect(condition, message) {
        if (condition) return
        console.error("TEXT CONTEXT MENU TEST FAILED: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
        const resources = object.resources || []
        for (let resourceIndex = 0; resourceIndex < resources.length; ++resourceIndex)
            descendantsWithName(resources[resourceIndex], name, result)
    }

    function named(object, name) {
        const result = []
        descendantsWithName(object, name, result)
        return result.length > 0 ? result[0] : null
    }

    QtObject {
        id: store

        property var selectedMessage: ({
            id: "plain-message",
            author: { name: "Reader", address: "reader@example.test" },
            subject: "Plain selection",
            bodyText: "Plain context text",
            bodyHtml: "",
            timestamp: "2026-09-03T10:00:00Z"
        })
        property var threadMessages: [selectedMessage]
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
        function markRead(message, read) {}
        function downloadAttachment(attachment, open, callback) {}
        function saveAttachmentTo(source, destination, callback) {}
    }

    RichTextArea {
        id: composer
        x: 12
        y: 12
        width: 350
        height: 110
    }

    HtmlMessageView {
        id: htmlReader
        x: 390
        y: 12
        width: 350
        height: 150
        html: "<p>Readable HTML selection</p>"
        trustedSanitizedHtml: true
    }

    MessageReaderPane {
        id: plainReader
        x: 0
        y: 180
        width: 760
        height: 520
        store: store
    }

    Timer {
        interval: 180
        running: true
        repeat: false
        onTriggered: {
            window.originalLocale = AgendaTranslations.localeOverride
            AgendaTranslations.localeOverride = "en_GB"
            composer.loadMessageBody("Alpha beta gamma", "")

            const composeArea = window.named(composer, "composeTextContextArea")
            const htmlArea = window.named(htmlReader, "htmlTextContextArea")
            const plainArea = window.named(plainReader, "plainTextContextArea")
            window.expect(composeArea !== null && htmlArea !== null && plainArea !== null,
                "not every selectable mail surface received a context menu")
            if (!composeArea || !htmlArea || !plainArea) return
            window.expect((composeArea.contextHandler.acceptedButtons
                    & Qt.RightButton) !== 0
                    && (htmlArea.contextHandler.acceptedButtons
                        & Qt.RightButton) !== 0
                    && (plainArea.contextHandler.acceptedButtons
                        & Qt.RightButton) !== 0,
                "a text context handler did not accept right clicks")

            composer.select(0, 5)
            composeArea.showAt(20, 20)
            editableCheck.start()
        }
    }

    Timer {
        id: editableCheck
        interval: 60
        repeat: false
        onTriggered: {
            const area = window.named(composer, "composeTextContextArea")
            const menu = area.menu
            window.expect(area.menuVisible && area.actionCount === 6,
                "editable text menu did not open with all actions")
            window.expect(menu.cutActionItem.visible && menu.cutActionItem.enabled
                    && menu.copyActionItem.enabled
                    && menu.deleteActionItem.visible
                    && menu.pasteActionItem.visible,
                "editable selection actions were missing")
            menu.copyActionItem.triggered()
            window.expect(composer.selectedText === "Alpha",
                "copying unexpectedly cleared the highlighted text")
            menu.deleteActionItem.triggered()
            window.expect(composer.bodyText === " beta gamma",
                "delete selection did not edit the composer")
            menu.close()

            const htmlArea = window.named(htmlReader, "htmlTextContextArea")
            htmlArea.editor.select(0, 8)
            htmlArea.showAt(20, 20)
            htmlCheck.start()
        }
    }

    Timer {
        id: htmlCheck
        interval: 60
        repeat: false
        onTriggered: {
            const area = window.named(htmlReader, "htmlTextContextArea")
            const menu = area.menu
            window.expect(area.menuVisible && !area.editable && area.actionCount === 3,
                "HTML selection did not open a read-only text menu")
            window.expect(menu.copyActionItem.enabled
                    && !menu.cutActionItem.visible
                    && !menu.pasteActionItem.visible
                    && !menu.deleteActionItem.visible,
                "HTML text menu exposed unsafe editing actions")
            menu.selectAllActionItem.triggered()
            window.expect(area.editor.selectionStart === 0
                    && area.editor.selectionEnd === area.editor.length,
                "Select all did not select the HTML message text")
            menu.deselectActionItem.triggered()
            window.expect(area.editor.selectionStart === area.editor.selectionEnd,
                "Deselect did not clear the HTML highlight")
            menu.close()

            const plainArea = window.named(plainReader, "plainTextContextArea")
            plainArea.editor.select(0, 5)
            plainArea.showAt(20, 20)
            plainCheck.start()
        }
    }

    Timer {
        id: plainCheck
        interval: 60
        repeat: false
        onTriggered: {
            const area = window.named(plainReader, "plainTextContextArea")
            const menu = area.menu
            window.expect(area.menuVisible && menu.copyActionItem.enabled,
                "plain-text highlight did not open a copy-capable menu")
            window.expect(menu.copyActionItem.icon.name === "edit-copy"
                    && menu.selectAllActionItem.icon.name === "edit-select-all",
                "text actions did not expose system icons")
            AgendaTranslations.localeOverride = "de_DE"
            window.expect(menu.title === "Textaktionen"
                    && menu.copyActionItem.text === "Kopieren"
                    && menu.selectAllActionItem.text === "Alles auswählen",
                "text context actions were not translated")
            menu.close()
            AgendaTranslations.localeOverride = window.originalLocale
            Qt.quit()
        }
    }
}
