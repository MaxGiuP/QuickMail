import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property bool open: true
    property bool minimized: false
    property bool sending: false
    property bool saving: false
    property bool saveQueued: false
    property bool closeAfterSave: false
    property bool closeAfterSend: false
    property bool closeAfterDiscard: false
    property bool sendAfterSave: false
    property bool discarding: false
    property bool loadingDraft: false
    property bool recipientDetailsOpen: false
    property bool replacementQueued: false
    property string replacementMode: ""
    property var replacementMessage: null
    property string deferredMailtoUri: ""
    property int editRevision: 0
    property int persistedRevision: -1
    property string statusText: ""
    signal closeOperationFailed()
    readonly property int headerHeight: 48
    readonly property string modeTitle: store.composeDraft.mode === "reply" ? "Reply"
        : store.composeDraft.mode === "reply_all" ? "Reply all"
        : store.composeDraft.mode === "forward" ? "Forward"
        : store.composeDraft.mode === "draft" ? "Edit draft" : "New message"
    readonly property string tabTitle: minimized && subjectField.text.trim() !== ""
        ? subjectField.text.trim() : modeTitle
    readonly property string recipientText: toField.text
    readonly property string subjectText: subjectField.text
    readonly property string editorBodyText: bodyField.bodyText
    readonly property string editorBodyHtml: bodyField.bodyHtml
    readonly property bool formattingExpanded: AppSettings.composeFormattingExpanded
    readonly property bool transitionQueued: replacementQueued
        || deferredMailtoUri !== ""
    readonly property bool safeToReplace: !transitionQueued && (!open
        || (!saving && !sending && !discarding
        && (persistedRevision === editRevision
            || (!hasDraftContent(draftPayload())
                && String(store.composeDraft.draftId || "") === ""))))

    color: Theme.surfaceRaised
    radius: Theme.radius
    border.width: 1
    border.color: Theme.border
    clip: true
    enabled: open
    visible: open || opacity > 0.01
    opacity: open ? 1 : 0
    focus: open

    transform: Translate {
        y: root.open ? 0 : 18
        Behavior on y {
            enabled: Theme.animationsEnabled
            NumberAnimation {
                duration: Theme.motionMedium
                easing.type: Easing.OutCubic
            }
        }
    }
    Behavior on opacity {
        enabled: Theme.animationsEnabled
        NumberAnimation { duration: Theme.motionMedium }
    }

    function parseAddresses(value) {
        return String(value || "").split(/[,;]/).map(function(part) {
            const address = part.trim()
            return address === "" ? null : { name: "", address: address }
        }).filter(function(entry) { return entry !== null })
    }

    function addressText(value) {
        if (!Array.isArray(value)) return String(value || "")
        return value.map(function(entry) {
            return String(entry && (entry.address || entry.name) || "")
        }).filter(function(address) { return address !== "" }).join(", ")
    }

    function draftPayload() {
        return {
            draftId: store.composeDraft.draftId || null,
            accountId: String(store.composeDraft.accountId || store.activeAccountId || ""),
            to: parseAddresses(toField.text),
            cc: parseAddresses(ccField.text),
            bcc: parseAddresses(bccField.text),
            subject: subjectField.text,
            bodyText: bodyField.bodyText,
            bodyHtml: bodyField.bodyHtml === "" ? null : bodyField.bodyHtml,
            inReplyTo: store.composeDraft.inReplyTo || null
        }
    }

    function captureDraft() {
        const payload = draftPayload()
        store.composeDraft = Object.assign({}, store.composeDraft, payload)
        return payload
    }

    function loadDraftFields() {
        loadingDraft = true
        toField.text = addressText(store.composeDraft.to)
        ccField.text = addressText(store.composeDraft.cc)
        bccField.text = addressText(store.composeDraft.bcc)
        subjectField.text = String(store.composeDraft.subject || "")
        bodyField.loadMessageBody(store.composeDraft.bodyText
            || store.composeDraft.body_text || "", store.composeDraft.bodyHtml
            || store.composeDraft.body_html || "")
        recipientDetailsOpen = ccField.text !== "" || bccField.text !== ""
        loadingDraft = false
    }

    function selectBodyText(start, end) {
        const first = Math.max(0, Math.min(bodyField.length, Number(start)))
        const last = Math.max(first, Math.min(bodyField.length, Number(end)))
        bodyField.select(first, last)
        bodyField.forceActiveFocus()
    }

    function formatBodyBold() { return bodyField.applyBold() }
    function formatBodyItalic() { return bodyField.applyItalic() }
    function formatBodyUnderline() { return bodyField.applyUnderline() }
    function formatBodyStrikeout() { return bodyField.applyStrikeout() }
    function formatBodySize(pixelSize) { return bodyField.applyFontSize(pixelSize) }
    function formatBodyColor(value) { return bodyField.applyTextColor(value) }
    function highlightBody(value) { return bodyField.applyHighlight(value) }
    function clearBodyFormatting() { return bodyField.clearSelectionFormatting() }

    function toggleFormattingOptions() {
        AppSettings.composeFormattingExpanded
            = !AppSettings.composeFormattingExpanded
    }

    function adjustBodyTextSize(direction) {
        const step = Number(direction)
        if (!Number.isFinite(step) || step === 0) return false
        const next = Math.max(0, Math.min(textSize.model.length - 1,
            textSize.currentIndex + (step < 0 ? -1 : 1)))
        if (next === textSize.currentIndex) return false
        textSize.currentIndex = next
        return bodyField.applyFontSize(textSize.model[next].size)
    }

    function openBodyTextColorMenu() {
        if (!bodyField.activeFocus) return false
        textColorMenu.open()
        return true
    }

    function openBodyHighlightMenu() {
        if (!bodyField.activeFocus) return false
        highlightMenu.open()
        return true
    }

    function focusComposer() {
        if (!open || minimized) return
        if (toField.text.trim() === "") toField.forceActiveFocus()
        else bodyField.forceActiveFocus()
    }

    function prepareOpen() {
        autosave.stop()
        minimized = false
        saving = false
        saveQueued = false
        closeAfterSave = false
        closeAfterSend = false
        closeAfterDiscard = false
        sendAfterSave = false
        sending = false
        discarding = false
        editRevision = 0
        persistedRevision = String(store.composeDraft.draftId || "") !== "" ? 0 : -1
        statusText = ""
        loadDraftFields()
        Qt.callLater(focusComposer)
    }

    function minimize() {
        if (!open || minimized) return
        captureDraft()
        minimized = true
        headerTitle.forceActiveFocus()
    }

    function restore() {
        if (!open) return
        minimized = false
        Qt.callLater(focusComposer)
    }

    function finishReplacement() {
        const mode = replacementMode
        const message = replacementMessage
        clearReplacement()
        if (mode === "mailto") {
            applyMailto(String(message || ""))
            return
        } else {
            store.startCompose(mode, message)
        }
        // `open` remains true while switching between the saved draft and the
        // new reply/mailto draft, so explicitly reload the editor fields.
        prepareOpen()
    }

    function applyMailto(uri) {
        if (!store.composeMailto(String(uri || ""))) {
            statusText = "This email link could not be opened"
            return false
        }
        // `open` can remain true when replacing a draft, so do not rely only
        // on onOpenChanged to refresh the editor controls.
        prepareOpen()
        return true
    }

    function clearReplacement() {
        replacementQueued = false
        replacementMode = ""
        replacementMessage = null
    }

    function clearAllReplacements() {
        clearReplacement()
        deferredMailtoUri = ""
    }

    function applyDeferredMailto() {
        const uri = deferredMailtoUri
        if (uri === "") return false
        deferredMailtoUri = ""
        return applyMailto(uri)
    }

    function continueDeferredMailto() {
        const uri = deferredMailtoUri
        if (uri === "") return false
        deferredMailtoUri = ""
        return queueReplacement("mailto", uri)
    }

    function queueReplacement(mode, message) {
        if (!open) {
            if (mode === "mailto") return store.composeMailto(String(message || ""))
            store.startCompose(mode, message)
            return true
        }
        restore()
        if (sending || discarding || closeAfterSave
                || closeAfterSend || closeAfterDiscard) {
            statusText = "Finish the current draft first"
            return false
        }
        replacementQueued = true
        replacementMode = String(mode || "compose")
        replacementMessage = message === undefined ? null : message
        autosave.stop()
        const payload = captureDraft()
        const hasSavedDraft = String(store.composeDraft.draftId || "") !== ""
        if (!hasDraftContent(payload) && !hasSavedDraft) {
            finishReplacement()
            return true
        }
        if (saving) {
            // The in-flight request may represent an older edit revision.
            // Force one final save of the captured fields before replacing
            // this tab, even when no text-change signal raced with us.
            saveQueued = true
            statusText = "Saving current draft…"
            return true
        }
        save(false)
        return true
    }

    function startAnother(mode, message) {
        return queueReplacement(String(mode || "compose"), message || null)
    }

    function acceptsMailto(uri) {
        const text = String(uri || "")
        return /^mailto:/i.test(text) && text.length <= 262144
    }

    function startMailto(uri) {
        const text = String(uri || "")
        if (!acceptsMailto(text)) return false
        if (sending || discarding) {
            // Sending and deleting are already provider-visible operations and
            // cannot be cancelled safely. Keep the URI until their callback,
            // then open it without losing either request.
            deferredMailtoUri = text
            statusText = sending ? "Opening email link after send…"
                : "Opening email link after discard…"
            return true
        }
        return queueReplacement("mailto", text)
    }

    function toggleMinimized() {
        if (minimized) restore()
        else minimize()
    }

    function hasDraftContent(payload) {
        return payload.to.length > 0 || payload.cc.length > 0 || payload.bcc.length > 0
            || payload.subject !== "" || String(payload.bodyText || "") !== ""
    }

    function noteEdited() {
        if (loadingDraft) return
        captureDraft()
        ++editRevision
        statusText = ""
        autosave.restart()
    }

    function save(closeWhenDone) {
        if (sending) return
        if (closeWhenDone === true) closeAfterSave = true
        const payload = captureDraft()
        if (!hasDraftContent(payload)
                && String(store.composeDraft.draftId || "") === "") {
            if (closeAfterSave) {
                closeAfterSave = false
                store.closeCompose()
            }
            return
        }
        if (saving) {
            saveQueued = true
            return
        }
        const savedRevision = editRevision
        saving = true
        statusText = "Saving draft…"
        store.saveDraft(payload, function(result, error) {
            root.saving = false
            if (error) {
                const closingWindow = root.closeAfterSave || root.closeAfterSend
                const failedMailto = root.replacementQueued
                    && root.replacementMode === "mailto"
                    ? String(root.replacementMessage || "") : ""
                root.saveQueued = false
                root.closeAfterSave = false
                root.closeAfterSend = false
                root.sendAfterSave = false
                root.sending = false
                root.clearReplacement()
                if (failedMailto !== "") root.deferredMailtoUri = failedMailto
                if (root.discarding) {
                    root.saving = false
                    root.finishDiscard()
                    return
                }
                root.statusText = error.message || "Draft could not be saved"
                if (failedMailto !== "")
                    root.statusText += "; the email link remains queued"
                if (closingWindow) root.closeOperationFailed()
                if (root.deferredMailtoUri !== "" && !closingWindow)
                    autosave.restart()
                return
            }
            root.statusText = "Draft saved"
            root.persistedRevision = savedRevision
            if (root.discarding) {
                root.finishDiscard()
            } else if (root.replacementQueued
                    && (root.saveQueued || root.editRevision !== savedRevision)) {
                root.saveQueued = false
                root.save(false)
            } else if (root.replacementQueued) {
                root.finishReplacement()
            } else if (root.sendAfterSave) {
                root.sendAfterSave = false
                root.sending = false
                root.performSend()
            } else if (root.saveQueued || root.editRevision !== savedRevision) {
                root.saveQueued = false
                root.save(root.closeAfterSave)
            } else if (root.deferredMailtoUri !== "") {
                root.applyDeferredMailto()
            } else if (root.closeAfterSave) {
                root.closeAfterSave = false
                root.store.closeCompose()
            }
        })
    }

    function requestClose() {
        autosave.stop()
        // Closing has priority over a queued reply/forward/mailto transition.
        // The current draft is the state that must be persisted before exit.
        clearAllReplacements()
        if (discarding) {
            closeAfterDiscard = true
            statusText = "Discarding draft…"
            return
        }
        if (sending) {
            closeAfterSend = true
            return
        }
        save(true)
    }

    function cancelCloseRequest() {
        closeAfterSave = false
        closeAfterSend = false
        closeAfterDiscard = false
    }

    function finishDiscard() {
        const id = String(store.composeDraft.draftId || "")
        if (id === "") {
            discarding = false
            store.closeCompose()
            return
        }
        statusText = "Discarding draft…"
        store.deleteDraft({ draftId: id }, function(result, error) {
            root.discarding = false
            if (error) {
                const closingWindow = root.closeAfterDiscard
                root.closeAfterDiscard = false
                root.statusText = error.message || "Draft could not be discarded"
                if (closingWindow) root.closeOperationFailed()
                if (root.deferredMailtoUri !== "") root.continueDeferredMailto()
                return
            }
            root.closeAfterDiscard = false
            if (root.deferredMailtoUri !== "") {
                root.applyDeferredMailto()
                return
            }
            root.store.closeCompose()
        })
    }

    function discard() {
        if (discarding || sending) return
        autosave.stop()
        saveQueued = false
        closeAfterSave = false
        closeAfterSend = false
        sendAfterSave = false
        clearAllReplacements()
        discarding = true
        if (saving) {
            statusText = "Discarding draft…"
            return
        }
        finishDiscard()
    }

    function send() {
        if (sending || discarding || transitionQueued || closeAfterSave
                || closeAfterSend || closeAfterDiscard
                || toField.text.trim() === "") return
        autosave.stop()
        captureDraft()
        if (saving) {
            sendAfterSave = true
            sending = true
            statusText = "Finishing draft…"
            return
        }
        performSend()
    }

    function performSend() {
        const payload = captureDraft()
        sending = true
        statusText = "Sending…"
        store.sendMessage(payload, function(result, error) {
            root.sending = false
            if (error) {
                const closingWindow = root.closeAfterSend
                root.closeAfterSend = false
                root.statusText = error.message || "Message could not be sent"
                if (closingWindow) root.closeOperationFailed()
                if (root.deferredMailtoUri !== "") root.continueDeferredMailto()
                return
            }
            root.closeAfterSend = false
            if (root.deferredMailtoUri !== "") root.continueDeferredMailto()
        })
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.headerHeight
            color: Theme.surfaceHover

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.space2
                anchors.rightMargin: Theme.space2
                spacing: 2

                Button {
                    id: headerTitle
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    flat: true
                    hoverEnabled: true
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: root.minimized ? "Restore draft" : "Minimize draft"
                    onClicked: root.toggleMinimized()

                    contentItem: Text {
                        text: root.tabTitle
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 8
                    }
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: headerTitle.down ? Theme.surfaceSelected
                            : headerTitle.hovered || headerTitle.visualFocus
                                ? Theme.surfaceRaised : "transparent"
                        border.width: headerTitle.visualFocus ? 1 : 0
                        border.color: Theme.accent
                    }
                }

                ToolButton {
                    id: minimizeButton
                    implicitWidth: 40
                    implicitHeight: 40
                    hoverEnabled: true
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: root.minimized ? "Restore draft" : "Minimize draft"
                    onClicked: root.toggleMinimized()

                    contentItem: Text {
                        text: root.minimized ? "⌃" : "−"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: root.minimized ? 19 : 22
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: minimizeButton.down ? Theme.surfaceSelected
                            : minimizeButton.hovered || minimizeButton.visualFocus
                                ? Theme.surfaceRaised : "transparent"
                        border.width: minimizeButton.visualFocus ? 1 : 0
                        border.color: Theme.accent
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: root.minimized ? "Restore draft" : "Minimize draft"
                    ToolTip.delay: 500
                }

                IconButton {
                    iconName: "close"
                    tip: "Save and close draft (Esc)"
                    onClicked: root.requestClose()
                }
            }
        }

        Rectangle {
            visible: !root.minimized
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        ScrollView {
            visible: !root.minimized
            Layout.fillWidth: true
            Layout.fillHeight: true
            enabled: !root.sending
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                width: parent.width
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 8
                    spacing: 12
                    Text {
                        text: "From"
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                    }
                    StyledComboBox {
                        id: fromAccount
                        Layout.fillWidth: true
                        model: store.accounts
                        textRole: "address"
                        currentIndex: {
                            for (let i = 0; i < store.accounts.length; ++i) {
                                if (String(store.accounts[i].id || store.accounts[i].account_id || "")
                                        === String(store.composeDraft.accountId
                                            || store.activeAccountId)) return i
                            }
                            return 0
                        }
                        onActivated: index => {
                            if (index < 0 || index >= store.accounts.length) return
                            store.composeDraft = Object.assign({}, store.composeDraft,
                                { accountId: String(store.accounts[index].id
                                    || store.accounts[index].account_id || "") })
                            root.noteEdited()
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.preferredHeight: 1
                    color: Theme.borderSoft
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 6
                    spacing: 10
                    Text {
                        text: "To"
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                    }
                    TextField {
                        id: toField
                        Layout.fillWidth: true
                        placeholderText: "name@example.com"
                        color: Theme.text
                        placeholderTextColor: Theme.textMuted
                        selectByMouse: true
                        background: null
                        onTextEdited: root.noteEdited()
                    }
                    Button {
                        text: root.recipientDetailsOpen ? "Hide" : "Cc / Bcc"
                        flat: true
                        focusPolicy: Qt.StrongFocus
                        onClicked: root.recipientDetailsOpen = !root.recipientDetailsOpen
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.preferredHeight: 1
                    color: Theme.borderSoft
                }

                RowLayout {
                    visible: root.recipientDetailsOpen
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    spacing: 10
                    Text {
                        text: "Cc"
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                    }
                    TextField {
                        id: ccField
                        Layout.fillWidth: true
                        color: Theme.text
                        background: null
                        onTextEdited: root.noteEdited()
                    }
                    Text {
                        text: "Bcc"
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                    }
                    TextField {
                        id: bccField
                        Layout.fillWidth: true
                        color: Theme.text
                        background: null
                        onTextEdited: root.noteEdited()
                    }
                }
                Rectangle {
                    visible: root.recipientDetailsOpen
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.preferredHeight: 1
                    color: Theme.borderSoft
                }

                TextField {
                    id: subjectField
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 4
                    Layout.bottomMargin: 4
                    placeholderText: "Subject"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    selectByMouse: true
                    background: null
                    onTextEdited: root.noteEdited()
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.preferredHeight: 1
                    color: Theme.borderSoft
                }

                Rectangle {
                    visible: AppSettings.composeFormattingExpanded
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? 46 : 0
                    color: Theme.surface

                    Flickable {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space4
                        anchors.rightMargin: Theme.space4
                        contentWidth: formatRow.implicitWidth
                        contentHeight: height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        RowLayout {
                            id: formatRow
                            height: parent.height
                            spacing: 2

                            ComposeFormatButton {
                                label: "↶"
                                tip: "Undo (Ctrl+Z)"
                                enabled: bodyField.canUndo
                                onClicked: bodyField.undo()
                            }
                            ComposeFormatButton {
                                label: "↷"
                                tip: "Redo (Ctrl+Shift+Z)"
                                enabled: bodyField.canRedo
                                onClicked: bodyField.redo()
                            }

                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 24
                                Layout.leftMargin: 3
                                Layout.rightMargin: 3
                                color: Theme.borderSoft
                            }

                            ComposeFormatButton {
                                label: "B"
                                labelBold: true
                                tip: "Bold (Ctrl+B)"
                                onClicked: bodyField.applyBold()
                            }
                            ComposeFormatButton {
                                label: "I"
                                labelItalic: true
                                tip: "Italic (Ctrl+I)"
                                onClicked: bodyField.applyItalic()
                            }
                            ComposeFormatButton {
                                label: "U"
                                labelUnderline: true
                                tip: "Underline (Ctrl+U)"
                                onClicked: bodyField.applyUnderline()
                            }
                            ComposeFormatButton {
                                label: "S"
                                labelStrikeout: true
                                tip: "Strikethrough (Alt+Shift+5 or Ctrl+Shift+X)"
                                onClicked: bodyField.applyStrikeout()
                            }

                            StyledComboBox {
                                id: textSize
                                Layout.preferredWidth: 104
                                Layout.preferredHeight: 36
                                model: [
                                    { label: "Small", size: 12 },
                                    { label: "Body", size: 14 },
                                    { label: "Large", size: 18 },
                                    { label: "Title", size: 24 }
                                ]
                                textRole: "label"
                                currentIndex: 1
                                Accessible.name: "Text size"
                                onActivated: index => bodyField.applyFontSize(model[index].size)

                                ToolTip.visible: hovered
                                ToolTip.text: "Text size (Ctrl+Shift+, / Ctrl+Shift+.)"
                                ToolTip.delay: 450
                            }

                            ComposeFormatButton {
                                label: "A"
                                swatchColor: "#3b82f6"
                                tip: "Text colour (Alt+Shift+C)"
                                onClicked: root.openBodyTextColorMenu()

                                Menu {
                                    id: textColorMenu
                                    y: parent.height
                                    MenuItem { text: "Red"; onTriggered: bodyField.applyTextColor("#ef5350") }
                                    MenuItem { text: "Orange"; onTriggered: bodyField.applyTextColor("#f59e0b") }
                                    MenuItem { text: "Green"; onTriggered: bodyField.applyTextColor("#22c55e") }
                                    MenuItem { text: "Blue"; onTriggered: bodyField.applyTextColor("#3b82f6") }
                                    MenuItem { text: "Purple"; onTriggered: bodyField.applyTextColor("#a855f7") }
                                }
                            }
                            ComposeFormatButton {
                                label: "H"
                                swatchColor: "#fff2a8"
                                tip: "Highlight colour (Alt+Shift+H)"
                                onClicked: root.openBodyHighlightMenu()

                                Menu {
                                    id: highlightMenu
                                    y: parent.height
                                    MenuItem { text: "Yellow"; onTriggered: bodyField.applyHighlight("#fff2a8") }
                                    MenuItem { text: "Green"; onTriggered: bodyField.applyHighlight("#c8f7d5") }
                                    MenuItem { text: "Blue"; onTriggered: bodyField.applyHighlight("#cfe8ff") }
                                    MenuItem { text: "Pink"; onTriggered: bodyField.applyHighlight("#ffd6e7") }
                                }
                            }
                            ComposeFormatButton {
                                label: "Tx"
                                tip: "Clear formatting from selected text (Ctrl+\\)"
                                enabled: bodyField.selectionStart !== bodyField.selectionEnd
                                onClicked: bodyField.clearSelectionFormatting()
                            }
                        }
                    }
                }
                Rectangle {
                    visible: AppSettings.composeFormattingExpanded
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.preferredHeight: visible ? 1 : 0
                    color: Theme.borderSoft
                }

                RichTextArea {
                    id: bodyField
                    objectName: "composeBodyEditor"
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(180, root.height
                        - (AppSettings.composeFormattingExpanded ? 346 : 300))
                    Layout.leftMargin: Theme.space4
                    Layout.rightMargin: Theme.space4
                    Layout.topMargin: 6
                    placeholderText: "Write a message…"
                    placeholderTextColor: Theme.textMuted
                    onUserEdited: if (!root.loadingDraft) root.noteEdited()
                }
            }
        }

        Rectangle {
            visible: !root.minimized
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        RowLayout {
            visible: !root.minimized
            Layout.fillWidth: true
            Layout.preferredHeight: 58
            Layout.leftMargin: Theme.space4
            Layout.rightMargin: Theme.space4
            spacing: 10

            PrimaryButton {
                text: root.sending ? "Sending…" : "Send"
                iconName: "send"
                enabled: !root.sending && !root.discarding
                    && !root.transitionQueued && !root.closeAfterSave
                    && !root.closeAfterSend && !root.closeAfterDiscard
                    && store.accounts.length > 0
                    && toField.text.trim() !== ""
                onClicked: root.send()
            }
            ComposeFormatButton {
                label: "Aa"
                labelBold: AppSettings.composeFormattingExpanded
                swatchColor: AppSettings.composeFormattingExpanded
                    ? Theme.accent : "transparent"
                tip: AppSettings.composeFormattingExpanded
                    ? "Hide formatting options (Alt+Shift+F)"
                    : "Show formatting options (Alt+Shift+F)"
                onClicked: root.toggleFormattingOptions()
            }
            Text {
                visible: root.statusText !== ""
                Layout.fillWidth: true
                text: root.statusText
                textFormat: Text.PlainText
                color: root.statusText.indexOf("could not") >= 0
                    ? Theme.danger : Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
            }
            Item { visible: root.statusText === ""; Layout.fillWidth: true }
            IconButton {
                iconName: "trash"
                tip: "Discard draft"
                destructive: true
                enabled: !root.discarding && !root.sending
                onClicked: root.discard()
            }
        }
    }

    Timer {
        id: autosave
        interval: 1500
        repeat: false
        onTriggered: root.save()
    }

    Shortcut { sequence: "Ctrl+Return"; enabled: root.open; onActivated: root.send() }
    Shortcut { sequence: "Ctrl+Enter"; enabled: root.open; onActivated: root.send() }
    // Body formatting must not intercept the same key combinations while a
    // recipient or subject field is active.
    Shortcut {
        sequence: "Ctrl+B"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: bodyField.applyBold()
    }
    Shortcut {
        sequence: "Ctrl+I"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: bodyField.applyItalic()
    }
    Shortcut {
        sequence: "Ctrl+U"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: bodyField.applyUnderline()
    }
    Shortcut {
        sequence: "Ctrl+Shift+X"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: bodyField.applyStrikeout()
    }
    Shortcut {
        sequence: "Alt+Shift+5"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: bodyField.applyStrikeout()
    }
    Shortcut {
        sequence: "Ctrl+Shift+,"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: root.adjustBodyTextSize(-1)
    }
    Shortcut {
        sequence: "Ctrl+Shift+."
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: root.adjustBodyTextSize(1)
    }
    Shortcut {
        sequence: "Ctrl+\\"
        enabled: root.open && !root.minimized && bodyField.activeFocus
            && bodyField.selectionStart !== bodyField.selectionEnd
        onActivated: bodyField.clearSelectionFormatting()
    }
    Shortcut {
        sequence: "Alt+Shift+C"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: root.openBodyTextColorMenu()
    }
    Shortcut {
        sequence: "Alt+Shift+H"
        enabled: root.open && !root.minimized && bodyField.activeFocus
        onActivated: root.openBodyHighlightMenu()
    }
    Shortcut {
        sequence: "Alt+Shift+F"
        enabled: root.open && !root.minimized
        onActivated: root.toggleFormattingOptions()
    }
    Shortcut { sequence: "Escape"; enabled: root.open; onActivated: root.requestClose() }

    onOpenChanged: {
        if (open) {
            prepareOpen()
        } else {
            autosave.stop()
            saveQueued = false
            closeAfterSave = false
            closeAfterSend = false
            closeAfterDiscard = false
            sendAfterSave = false
            sending = false
            discarding = false
            clearReplacement()
        }
    }

    Component.onCompleted: {
        if (open) prepareOpen()
    }
}
