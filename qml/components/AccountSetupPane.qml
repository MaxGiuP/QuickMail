pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property var account: null
    property string provider: account ? String(account.provider || "imap").toLowerCase() : ""
    property bool busy: false
    property string errorText: ""
    readonly property bool editing: account !== null
    signal closed()

    color: Theme.canvas

    function normalizedPort(field, fallback) {
        const value = Number(field.text)
        return value >= 1 && value <= 65535 ? value : fallback
    }

    function clearSensitiveFields() {
        password.clear()
        smtpPassword.clear()
    }

    function closePane() {
        clearSensitiveFields()
        busy = false
        errorText = ""
        closed()
    }

    function gmailPayload(address, displayName) {
        return {
            provider: "gmail",
            address: String(address || "").trim(),
            displayName: String(displayName || "").trim()
        }
    }

    function requestFinished(result, error) {
        if (error) {
            busy = false
            errorText = error.message || (editing
                ? "The account could not be reconnected."
                : "The account could not be connected.")
            return
        }
        // Account creation only registers the provider. Wait for the daemon's
        // fast foreground sync so the first mailbox/message load cannot race
        // an empty cache.
        const connectedAccountId = String(result && (result.accountId || result.account_id) || "")
        store.syncAccount(connectedAccountId, function(syncResult, syncError) {
            root.store.loadAccounts()
            if (syncError)
                root.store.errorText = syncError.message || "Initial mail sync failed"
            root.closePane()
        })
    }

    function submit() {
        if (provider === "") return
        errorText = ""
        if (editing) {
            busy = true
            store.reauthAccount(account, root.requestFinished)
            return
        }
        let payload
        if (provider === "gmail") {
            if (gmailAddress.text.trim() === "") {
                errorText = "Enter the Gmail address."
                return
            }
            const address = gmailAddress.text.trim()
            payload = gmailPayload(address, gmailName.text)
        } else {
            if (imapAddress.text.trim() === "" || imapHost.text.trim() === ""
                    || imapUsername.text.trim() === "" || password.text === ""
                    || smtpHost.text.trim() === ""
                    || (!smtpSamePassword.checked && smtpPassword.text === "")) {
                errorText = "Enter the address, both mail servers, username, and password."
                return
            }
            const address = imapAddress.text.trim()
            const username = imapUsername.text.trim()
            payload = {
                provider: "imap",
                address: address,
                displayName: imapName.text.trim(),
                imap: {
                    host: imapHost.text.trim(),
                    port: normalizedPort(imapPort, 993),
                    security: imapSecurity.currentValue,
                    username: username,
                    password: password.text
                },
                smtp: {
                    host: smtpHost.text.trim(),
                    port: normalizedPort(smtpPort, 587),
                    security: smtpSecurity.currentValue,
                    username: smtpUsername.text.trim() || username,
                    password: smtpSamePassword.checked ? password.text : smtpPassword.text
                }
            }
        }
        busy = true
        store.addAccount(payload, root.requestFinished)
        clearSensitiveFields()
    }

    function removeCurrentAccount() {
        if (!editing || busy) return
        busy = true
        errorText = ""
        store.removeAccount(account, function(result, error) {
            root.busy = false
            if (error) {
                root.errorText = error.message || "The account could not be removed."
                return
            }
            root.store.loadAccounts()
            root.closePane()
        })
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 62
            Layout.leftMargin: 10
            Layout.rightMargin: 14
            IconButton {
                visible: store.accounts.length > 0
                iconName: "back"
                tip: "Back to mail"
                onClicked: root.closePane()
            }
            Text {
                Layout.fillWidth: true
                text: root.editing ? "Reconnect account" : "Add an account"
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 20
                font.weight: Font.DemiBold
            }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.borderSoft }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                width: Math.min(parent.width - 40, 620)
                x: Math.max(20, (parent.width - width) / 2)
                spacing: 14

                Item { Layout.preferredHeight: 20 }
                Text {
                    Layout.fillWidth: true
                    text: root.editing
                        ? "Reconnect using the credentials already protected by GNOME Online Accounts or your system keyring."
                        : "Choose how QuickMail should connect. Credentials go directly to the local daemon and are stored in your system keyring."
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    visible: !root.editing
                    Layout.fillWidth: true
                    spacing: 12
                    Repeater {
                        model: [
                            { id: "gmail", title: "Gmail", detail: "GNOME Online Accounts · IMAP / SMTP", icon: "mail" },
                            { id: "imap", title: "IMAP / SMTP", detail: "Fastmail, Outlook, iCloud, or your server", icon: "folder" }
                        ]
                        delegate: Rectangle {
                            id: providerCard
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 112
                            radius: Theme.radius
                            color: root.provider === modelData.id ? Theme.surfaceSelected
                                : cardMouse.containsMouse ? Theme.surfaceHover : Theme.surface
                            border.width: root.provider === modelData.id ? 1 : 0
                            border.color: Theme.accent
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 14
                                spacing: 4
                                Text {
                                    text: Theme.icon(providerCard.modelData.icon)
                                    color: Theme.accent
                                    font.family: Theme.iconFont
                                    font.pixelSize: 24
                                }
                                Text {
                                    text: providerCard.modelData.title
                                    color: Theme.text
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 15
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: providerCard.modelData.detail
                                    color: Theme.textMuted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 11
                                    wrapMode: Text.WordWrap
                                }
                            }
                            MouseArea {
                                id: cardMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.provider = providerCard.modelData.id
                            }
                        }
                    }
                }

                ColumnLayout {
                    visible: !root.editing && root.provider === "gmail"
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: "Gmail through GNOME Online Accounts"
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 17
                        font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "QuickMail opens Google sign-in through GNOME Online Accounts. Authorization and token refresh are managed by GOA; QuickMail never asks for or stores your Google password, OAuth client ID, OAuth client secret, or access tokens."
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                    TextField { id: gmailName; Layout.fillWidth: true; placeholderText: "Display name"; text: root.account ? root.account.displayName || "" : "" }
                    TextField { id: gmailAddress; Layout.fillWidth: true; placeholderText: "you@gmail.com"; text: root.account ? root.account.address || "" : "" }
                }

                ColumnLayout {
                    visible: !root.editing && root.provider === "imap"
                    Layout.fillWidth: true
                    spacing: 10
                    Text { text: "Mailbox"; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 17; font.weight: Font.DemiBold }
                    TextField { id: imapName; Layout.fillWidth: true; placeholderText: "Display name"; text: root.account ? root.account.displayName || "" : "" }
                    TextField { id: imapAddress; Layout.fillWidth: true; placeholderText: "Email address"; text: root.account ? root.account.address || "" : "" }
                    Text { text: "Incoming mail"; color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: Font.DemiBold }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField { id: imapHost; Layout.fillWidth: true; placeholderText: "imap.example.com" }
                        TextField { id: imapPort; Layout.preferredWidth: 88; text: "993"; validator: IntValidator { bottom: 1; top: 65535 } }
                        ComboBox { id: imapSecurity; model: [{ text: "TLS", value: "tls" }, { text: "STARTTLS", value: "starttls" }]; textRole: "text"; valueRole: "value" }
                    }
                    TextField { id: imapUsername; Layout.fillWidth: true; placeholderText: "IMAP username" }
                    TextField { id: password; Layout.fillWidth: true; placeholderText: "App password"; echoMode: TextInput.Password }
                    Text { text: "Outgoing mail"; color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: Font.DemiBold }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField { id: smtpHost; Layout.fillWidth: true; placeholderText: "smtp.example.com" }
                        TextField { id: smtpPort; Layout.preferredWidth: 88; text: "587"; validator: IntValidator { bottom: 1; top: 65535 } }
                        ComboBox { id: smtpSecurity; model: [{ text: "STARTTLS", value: "starttls" }, { text: "TLS", value: "tls" }]; textRole: "text"; valueRole: "value" }
                    }
                    TextField { id: smtpUsername; Layout.fillWidth: true; placeholderText: "SMTP username (defaults to IMAP)" }
                    CheckBox { id: smtpSamePassword; text: "Use the same password for sending"; checked: true }
                    TextField { id: smtpPassword; Layout.fillWidth: true; visible: !smtpSamePassword.checked; placeholderText: "SMTP app password"; echoMode: TextInput.Password }
                }

                Rectangle {
                    visible: root.errorText !== ""
                    Layout.fillWidth: true
                    implicitHeight: errorLabel.implicitHeight + 20
                    radius: Theme.radiusSmall
                    color: Qt.rgba(1, 0.25, 0.3, 0.13)
                    Text {
                        id: errorLabel
                        anchors.fill: parent
                        anchors.margins: 10
                        text: root.errorText
                        textFormat: Text.PlainText
                        color: Theme.danger
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 24
                    PrimaryButton {
                        visible: root.editing
                        text: "Remove account"
                        iconName: "trash"
                        destructive: true
                        enabled: !root.busy
                        onClicked: removeDialog.open()
                    }
                    Item { Layout.fillWidth: true }
                    PrimaryButton {
                        text: root.busy ? "Connecting…" : root.editing ? "Reconnect account"
                            : root.provider === "gmail" ? "Open Google sign-in" : "Connect account"
                        iconName: "chevron"
                        enabled: root.provider !== "" && !root.busy
                        onClicked: root.submit()
                    }
                }
            }
        }
    }

    Dialog {
        id: removeDialog
        parent: root
        modal: true
        title: "Remove this account?"
        standardButtons: Dialog.Yes | Dialog.Cancel
        width: Math.min(420, Math.max(280, root.width - 40))
        height: Math.min(200, Math.max(160, root.height - 40))
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        onAccepted: root.removeCurrentAccount()
        contentItem: Text {
            text: root.provider === "gmail"
                ? "This removes the account from QuickMail. Your GNOME Online Account stays connected."
                : "This removes the account and its cached mail from QuickMail."
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
    }

    onVisibleChanged: if (!visible) clearSensitiveFields()
}
