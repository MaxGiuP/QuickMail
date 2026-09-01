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
    property bool sendAfterSave: false
    property bool discarding: false
    property bool loadingDraft: false
    property bool recipientDetailsOpen: false
    property bool replacementQueued: false
    property string replacementMode: ""
    property var replacementMessage: null
    property int editRevision: 0
    property string statusText: ""
    readonly property int headerHeight: 48
    readonly property string modeTitle: store.composeDraft.mode === "reply" ? "Reply"
        : store.composeDraft.mode === "reply_all" ? "Reply all"
        : store.composeDraft.mode === "forward" ? "Forward"
        : store.composeDraft.mode === "draft" ? "Edit draft" : "New message"
    readonly property string tabTitle: minimized && subjectField.text.trim() !== ""
        ? subjectField.text.trim() : modeTitle

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
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
    }
    Behavior on opacity { NumberAnimation { duration: 140 } }

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
            bodyText: bodyField.text,
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
        bodyField.text = String(store.composeDraft.bodyText || "")
        recipientDetailsOpen = ccField.text !== "" || bccField.text !== ""
        loadingDraft = false
    }

    function focusComposer() {
        if (!open || minimized) return
        if (toField.text.trim() === "") toField.forceActiveFocus()
        else bodyField.forceActiveFocus()
    }

    function prepareOpen() {
        minimized = false
        saving = false
        saveQueued = false
        closeAfterSave = false
        sendAfterSave = false
        discarding = false
        editRevision = 0
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
        replacementQueued = false
        replacementMode = ""
        replacementMessage = null
        store.startCompose(mode, message)
        // `open` remains true while switching between the saved draft and the
        // new reply, so explicitly reload the editor fields.
        prepareOpen()
    }

    function startAnother(mode, message) {
        if (!open) {
            store.startCompose(mode, message)
            return
        }
        restore()
        if (sending || discarding) {
            statusText = "Finish the current draft first"
            return
        }
        replacementQueued = true
        replacementMode = String(mode || "compose")
        replacementMessage = message || null
        autosave.stop()
        const payload = captureDraft()
        const hasSavedDraft = String(store.composeDraft.draftId || "") !== ""
        if (!hasDraftContent(payload) && !hasSavedDraft) {
            finishReplacement()
            return
        }
        if (saving) {
            // The in-flight request may represent an older edit revision.
            // Force one final save of the captured fields before replacing
            // this tab, even when no text-change signal raced with us.
            saveQueued = true
            statusText = "Saving current draft…"
            return
        }
        save(false)
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
                root.saveQueued = false
                root.closeAfterSave = false
                root.sendAfterSave = false
                root.sending = false
                root.replacementQueued = false
                root.replacementMode = ""
                root.replacementMessage = null
                if (root.discarding) {
                    root.saving = false
                    root.finishDiscard()
                    return
                }
                root.statusText = error.message || "Draft could not be saved"
                return
            }
            root.statusText = "Draft saved"
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
            } else if (root.closeAfterSave) {
                root.closeAfterSave = false
                root.store.closeCompose()
            }
        })
    }

    function requestClose() {
        autosave.stop()
        save(true)
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
                root.statusText = error.message || "Draft could not be discarded"
                return
            }
            root.store.closeCompose()
        })
    }

    function discard() {
        autosave.stop()
        saveQueued = false
        closeAfterSave = false
        sendAfterSave = false
        discarding = true
        if (saving) {
            statusText = "Discarding draft…"
            return
        }
        finishDiscard()
    }

    function send() {
        if (sending || toField.text.trim() === "") return
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
            if (error) root.statusText = error.message || "Message could not be sent"
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
                anchors.leftMargin: 6
                anchors.rightMargin: 4
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
                    ComboBox {
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

                TextArea {
                    id: bodyField
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(180, root.height - 300)
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    Layout.topMargin: 6
                    placeholderText: "Write a message…"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.text
                    selectionColor: Theme.accentSoft
                    selectedTextColor: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 14
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    background: null
                    onTextChanged: if (activeFocus && !root.loadingDraft) root.noteEdited()
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
            Layout.leftMargin: 12
            Layout.rightMargin: 10
            spacing: 10

            PrimaryButton {
                text: root.sending ? "Sending…" : "Send"
                iconName: "send"
                enabled: !root.sending && store.accounts.length > 0
                    && toField.text.trim() !== ""
                onClicked: root.send()
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
    Shortcut { sequence: "Escape"; enabled: root.open; onActivated: root.requestClose() }

    onOpenChanged: {
        if (open) {
            prepareOpen()
        } else {
            autosave.stop()
            saveQueued = false
            closeAfterSave = false
            sendAfterSave = false
            discarding = false
            replacementQueued = false
            replacementMode = ""
            replacementMessage = null
        }
    }

    Component.onCompleted: {
        if (open) prepareOpen()
    }
}
