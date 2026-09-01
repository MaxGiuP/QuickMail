import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property bool sending: false
    property bool saving: false
    property bool saveQueued: false
    property bool closeAfterSave: false
    property bool sendAfterSave: false
    property bool discarding: false
    property int editRevision: 0
    property string statusText: ""

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

    color: Theme.canvas

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

    function hasDraftContent(payload) {
        return payload.to.length > 0 || payload.cc.length > 0 || payload.bcc.length > 0
            || payload.subject !== "" || String(payload.bodyText || "") !== ""
    }

    function noteEdited() {
        captureDraft()
        ++editRevision
        statusText = ""
        autosave.restart()
    }

    function save(closeWhenDone) {
        if (sending) return
        if (closeWhenDone === true) closeAfterSave = true
        const payload = captureDraft()
        if (!hasDraftContent(payload)) {
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

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            Layout.leftMargin: 10
            Layout.rightMargin: 14
            spacing: 8
            IconButton {
                iconName: "back"
                tip: "Close composer (Esc)"
                onClicked: root.requestClose()
            }
            Text {
                Layout.fillWidth: true
                text: store.composeDraft.mode === "reply" ? "Reply"
                    : store.composeDraft.mode === "reply_all" ? "Reply all"
                    : store.composeDraft.mode === "forward" ? "Forward"
                    : store.composeDraft.mode === "draft" ? "Edit draft" : "New message"
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 19
                font.weight: Font.DemiBold
            }
            Text {
                visible: root.statusText !== ""
                text: root.statusText
                textFormat: Text.PlainText
                color: root.statusText.indexOf("could not") >= 0 ? Theme.danger : Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 11
            }
            PrimaryButton {
                text: root.sending ? "Sending…" : "Send"
                iconName: "send"
                enabled: !root.sending && store.accounts.length > 0
                    && toField.text.trim() !== ""
                onClicked: root.send()
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.borderSoft }

        ScrollView {
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
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 8
                    spacing: 12
                    Text { text: "From"; color: Theme.textMuted; font.family: Theme.fontFamily; font.pixelSize: 13 }
                    ComboBox {
                        id: fromAccount
                        Layout.fillWidth: true
                        model: store.accounts
                        textRole: "address"
                        currentIndex: {
                            for (let i = 0; i < store.accounts.length; ++i) {
                                if (String(store.accounts[i].id || store.accounts[i].account_id || "")
                                        === String(store.composeDraft.accountId || store.activeAccountId)) return i
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
                Rectangle { Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.preferredHeight: 1; color: Theme.borderSoft }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 10
                    spacing: 12
                    Text { text: "To"; color: Theme.textMuted; font.family: Theme.fontFamily; font.pixelSize: 13 }
                    TextField {
                        id: toField
                        Layout.fillWidth: true
                        text: root.addressText(store.composeDraft.to)
                        placeholderText: "name@example.com"
                        color: Theme.text
                        placeholderTextColor: Theme.textMuted
                        selectByMouse: true
                        background: null
                        onTextEdited: root.noteEdited()
                    }
                    Button {
                        text: ccRow.visible ? "Hide Cc" : "Cc / Bcc"
                        flat: true
                        onClicked: ccRow.visible = !ccRow.visible
                    }
                }
                Rectangle { Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.preferredHeight: 1; color: Theme.borderSoft }

                RowLayout {
                    id: ccRow
                    visible: root.addressText(store.composeDraft.cc) !== ""
                        || root.addressText(store.composeDraft.bcc) !== ""
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    spacing: 12
                    Text { text: "Cc"; color: Theme.textMuted; font.family: Theme.fontFamily; font.pixelSize: 13 }
                    TextField { id: ccField; Layout.fillWidth: true; text: root.addressText(store.composeDraft.cc); color: Theme.text; background: null; onTextEdited: root.noteEdited() }
                    Text { text: "Bcc"; color: Theme.textMuted; font.family: Theme.fontFamily; font.pixelSize: 13 }
                    TextField { id: bccField; Layout.fillWidth: true; text: root.addressText(store.composeDraft.bcc); color: Theme.text; background: null; onTextEdited: root.noteEdited() }
                }
                Rectangle { visible: ccRow.visible; Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.preferredHeight: 1; color: Theme.borderSoft }

                TextField {
                    id: subjectField
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 6
                    Layout.bottomMargin: 6
                    text: store.composeDraft.subject || ""
                    placeholderText: "Subject"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 17
                    font.weight: Font.DemiBold
                    selectByMouse: true
                    background: null
                    onTextEdited: root.noteEdited()
                }
                Rectangle { Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.preferredHeight: 1; color: Theme.borderSoft }

                TextArea {
                    id: bodyField
                    Layout.fillWidth: true
                    Layout.minimumHeight: 420
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    Layout.topMargin: 8
                    text: store.composeDraft.bodyText || ""
                    placeholderText: "Write a message…"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.text
                    selectionColor: Theme.accentSoft
                    selectedTextColor: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 15
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    background: null
                    onTextChanged: if (activeFocus) root.noteEdited()
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.bottomMargin: 16
                    Item { Layout.fillWidth: true }
                    IconButton {
                        iconName: "trash"
                        tip: "Discard draft"
                        destructive: true
                        onClicked: root.discard()
                    }
                }
            }
        }
    }

    Timer {
        id: autosave
        interval: 1500
        repeat: false
        onTriggered: root.save()
    }

    Shortcut { sequence: "Ctrl+Return"; onActivated: root.send() }
    Shortcut { sequence: "Ctrl+Enter"; onActivated: root.send() }
    Shortcut {
        sequence: "Escape"
        onActivated: root.requestClose()
    }

    onVisibleChanged: {
        if (visible) {
            saving = false
            saveQueued = false
            closeAfterSave = false
            sendAfterSave = false
            discarding = false
            editRevision = 0
            statusText = ""
            Qt.callLater(function() { toField.forceActiveFocus() })
        } else {
            autosave.stop()
            saveQueued = false
            closeAfterSave = false
            sendAfterSave = false
            discarding = false
        }
    }
}
