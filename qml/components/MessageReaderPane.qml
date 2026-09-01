pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import QtCore
import ".."

Rectangle {
    id: root
    required property var store
    property bool mobile: false
    property string attachmentStatus: ""
    property string pendingSaveSource: ""
    property bool htmlRenderFailed: false
    readonly property bool threadAvatarLayoutReady: _threadAvatarLayoutReady
    property bool _threadAvatarLayoutReady: false
    property int _threadAvatarLayoutGeneration: 0
    signal backRequested()
    signal composeRequested(string mode, var message)

    color: Theme.surface

    readonly property var message: store.selectedMessage || ({})
    readonly property string sender: singleLine(message.from_name || message.sender_name
        || (message.author && (message.author.name || message.author.address))
        || message.from || message.from_address || "Unknown sender") || "Unknown sender"
    readonly property string senderAddress: singleLine((message.author && message.author.address)
        || message.from_address || message.from || "")
    readonly property string recipient: addressList(message.to_display || message.to || "")
    readonly property string bodyText: store.messageBodyText(message)
    readonly property string bodyHtml: String(message.bodyHtml || message.body_html || "")
    readonly property bool hasHtmlBody: bodyHtml.trim() !== ""
    readonly property string renderedBodyHtml: hasHtmlBody ? htmlLoader.loadedHtml : ""
    readonly property int threadCount: Array.isArray(store.threadMessages)
        ? store.threadMessages.length : 0
    readonly property string timestampText: formatTimestamp(message.date_display
        || message.received_display || message.timestamp || message.received_at || "")

    function deferThreadAvatarLayout() {
        const generation = ++_threadAvatarLayoutGeneration
        _threadAvatarLayoutReady = false
        // A Repeater creates every delegate at y=0 before ColumnLayout's
        // polish pass. Waiting for two event turns keeps those provisional
        // coordinates from activating every network-backed avatar Loader.
        Qt.callLater(function() {
            Qt.callLater(function() {
                if (generation === root._threadAvatarLayoutGeneration)
                    root._threadAvatarLayoutReady = true
            })
        })
    }

    onThreadCountChanged: deferThreadAvatarLayout()
    Component.onCompleted: deferThreadAvatarLayout()

    function singleLine(value) {
        return String(value === undefined || value === null ? "" : value)
            .replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
            .replace(/\s+/g, " ").trim()
    }

    function addressList(value) {
        if (!Array.isArray(value)) return String(value || "")
        return value.map(entry => entry.name || entry.address || "").filter(Boolean).join(", ")
    }

    function threadSender(item) {
        return singleLine(item && (item.from_name || item.sender_name
            || (item.author && (item.author.name || item.author.address))
            || item.from || item.from_address) || "Unknown sender") || "Unknown sender"
    }

    function senderAddressFor(item) {
        return singleLine(item && ((item.author && item.author.address)
            || item.from_address || item.from) || "")
    }

    function threadSelected(item) {
        return store.messageId(item) === store.messageId(store.selectedMessage)
    }

    function humanSize(value) {
        const bytes = Number(value || 0)
        if (bytes < 1024) return bytes + " B"
        if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB"
        return (bytes / (1024 * 1024)).toFixed(1) + " MB"
    }

    function formatTimestamp(value) {
        if (!value) return ""
        const date = new Date(value)
        if (isNaN(date.getTime())) return String(value)
        return Qt.formatDateTime(date, "d MMM yyyy, HH:mm")
    }

    function safeFilename(value) {
        let filename = String(value || "Attachment")
            .replace(/[\u0000-\u001f\\/]/g, "_").trim()
        if (filename === "" || filename === "." || filename === "..") filename = "Attachment"
        if (filename[0] === ".") filename = "_" + filename.substring(1)
        return filename
    }

    function localFileUrl(path) {
        const value = String(path || "")
        if (value === "" || value[0] !== "/" || value.indexOf("\u0000") >= 0) return ""
        return "file://" + value.split("/").map(function(part) {
            return encodeURIComponent(part)
        }).join("/")
    }

    function localPath(url) {
        const value = String(url || "")
        if (value.substring(0, 7) !== "file://") return ""
        try {
            return decodeURIComponent(value.substring(7))
        } catch (error) {
            return ""
        }
    }

    function attachmentDownloaded(result, error, openWhenReady) {
        if (error) {
            attachmentStatus = ""
            store.errorText = error.message || "The attachment could not be downloaded"
            return
        }
        const path = String(result && result.path || "")
        const url = localFileUrl(path)
        if (url === "") {
            attachmentStatus = ""
            store.errorText = "The mail service returned an invalid attachment path"
            return
        }
        if (openWhenReady) {
            attachmentStatus = "Opening " + safeFilename(result.filename)
            if (!Qt.openUrlExternally(url)) {
                attachmentStatus = ""
                store.errorText = "No application is available to open this attachment"
            } else {
                attachmentStatus = "Opened " + safeFilename(result.filename)
            }
            return
        }
        pendingSaveSource = path
        const directory = StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        if (directory === "") {
            pendingSaveSource = ""
            store.errorText = "The Downloads folder is unavailable"
            return
        }
        const filename = safeFilename(result.filename)
        saveDialog.currentFolder = localFileUrl(directory)
        saveDialog.selectedFile = localFileUrl(directory + "/" + filename)
        saveDialog.open()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 58
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            spacing: 4
            IconButton {
                visible: root.mobile
                iconName: "back"
                tip: "Back to messages"
                onClicked: root.backRequested()
            }
            Item { Layout.fillWidth: true }
            IconButton {
                iconName: "archive"
                tip: "Archive (E)"
                enabled: store.selectedMessage !== null
                onClicked: store.archive(root.message)
            }
            IconButton {
                iconName: (root.message.starred === true || root.message.is_starred === true)
                    ? "star" : "starOutline"
                emphasized: root.message.starred === true || root.message.is_starred === true
                tip: "Star (S)"
                enabled: store.selectedMessage !== null
                onClicked: store.toggleStar(root.message)
            }
            IconButton {
                iconName: "trash"
                tip: "Move to trash (Delete)"
                destructive: true
                enabled: store.selectedMessage !== null
                onClicked: store.trash(root.message)
            }
            IconButton {
                iconName: "settings"
                tip: "Reader settings"
                onClicked: readerSettings.open()

                Menu {
                    id: readerSettings
                    x: parent.width - width
                    y: parent.height
                    MenuItem {
                        text: "Load remote content"
                        checkable: true
                        checked: AppSettings.allowRemoteContent
                        onTriggered: AppSettings.allowRemoteContent = checked
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        EmptyState {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: store.selectedMessage === null
            iconName: "mail"
            title: "Select a message"
            detail: "Choose a conversation from the list to read it here."
        }

        Flickable {
            id: bodyFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: store.selectedMessage !== null
            contentWidth: width
            contentHeight: article.implicitHeight + 48
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            onWidthChanged: root.deferThreadAvatarLayout()

            ColumnLayout {
                id: article
                width: Math.min(bodyFlick.width - 48, 780)
                x: Math.max(24, (bodyFlick.width - width) / 2)
                y: 24
                spacing: 16

                Text {
                    Layout.fillWidth: true
                    text: (root.message.subject || "(No subject)")
                        + (root.threadCount > 1 ? "  (" + root.threadCount + ")" : "")
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 26
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                }

                ColumnLayout {
                    id: threadSection
                    Layout.fillWidth: true
                    visible: store.threadLoading || root.threadCount > 1
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        visible: store.threadLoading || root.threadCount > 1
                        Text {
                            Layout.fillWidth: true
                            text: root.threadCount > 1
                                ? root.threadCount + " messages in this conversation"
                                : "Loading conversation…"
                            textFormat: Text.PlainText
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                        }
                        BusyIndicator {
                            visible: store.threadLoading
                            running: visible
                            Layout.preferredWidth: 20
                            Layout.preferredHeight: 20
                        }
                    }

                    Repeater {
                        model: store.threadMessages
                        delegate: Rectangle {
                            id: threadCard
                            objectName: "threadCard"
                            required property var modelData
                            required property int index
                            readonly property bool hasFinalLayoutGeometry:
                                root.threadAvatarLayoutReady
                                && threadSection.visible
                                && bodyFlick.visible
                                && bodyFlick.width > 0
                                && bodyFlick.height > 0
                                && threadCard.width > 0
                                && threadCard.height > 0
                                // All delegates are provisionally y=0. The
                                // summary row precedes the first real card, so
                                // a positive y proves ColumnLayout positioned it.
                                && threadCard.y > 0
                            readonly property bool intersectsViewport: {
                                // Re-evaluate both when the layout settles and
                                // while the outer article scrolls. Offscreen
                                // conversation members should not create image
                                // loaders or disclose their sender addresses.
                                const layoutPosition = threadCard.y
                                const top = threadCard.mapToItem(
                                    bodyFlick.contentItem, 0, 0).y
                                return layoutPosition >= 0
                                    && top + threadCard.height
                                        >= bodyFlick.contentY - threadCard.height
                                    && top <= bodyFlick.contentY
                                        + bodyFlick.height + threadCard.height
                            }
                            Layout.fillWidth: true
                            Layout.preferredHeight: 56
                            clip: true
                            radius: Theme.radiusSmall
                            color: root.threadSelected(modelData)
                                ? Theme.surfaceSelected : Theme.surfaceRaised
                            border.width: root.threadSelected(modelData) ? 1 : 0
                            border.color: Theme.accent

                            Behavior on color {
                                ColorAnimation { duration: 140 }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10
                                Loader {
                                    objectName: "threadCardAvatarLoader"
                                    Layout.preferredWidth: 30
                                    Layout.preferredHeight: 30
                                    active: threadCard.hasFinalLayoutGeometry
                                        && threadCard.intersectsViewport
                                    sourceComponent: Component {
                                        SenderAvatar {
                                            objectName: "threadCardAvatar"
                                            displayName: root.threadSender(threadCard.modelData)
                                            address: root.senderAddressFor(threadCard.modelData)
                                            avatarResolver: root.store
                                            allowRemoteContent: AppSettings.effectiveAllowRemoteContent
                                        }
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    spacing: 1
                                    Text {
                                        objectName: "threadCardSender"
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        text: root.threadSender(threadCard.modelData)
                                        textFormat: Text.PlainText
                                        color: Theme.text
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                        wrapMode: Text.NoWrap
                                        maximumLineCount: 1
                                        elide: Text.ElideRight
                                        clip: true
                                    }
                                    Text {
                                        objectName: "threadCardSnippet"
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        text: root.singleLine(threadCard.modelData.snippet || "")
                                        textFormat: Text.PlainText
                                        color: Theme.textMuted
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 10
                                        wrapMode: Text.NoWrap
                                        maximumLineCount: 1
                                        elide: Text.ElideRight
                                        clip: true
                                    }
                                }
                                Text {
                                    Layout.minimumWidth: 0
                                    Layout.maximumWidth: 110
                                    text: root.singleLine(root.formatTimestamp(
                                        threadCard.modelData.timestamp
                                            || threadCard.modelData.received_at || ""))
                                    textFormat: Text.PlainText
                                    color: Theme.textMuted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 10
                                    wrapMode: Text.NoWrap
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    clip: true
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.store.openThreadMessage(threadCard.modelData)
                            }
                        }
                    }

                    Text {
                        visible: store.threadTruncated
                        text: "Showing a 100-message window that keeps your selected message"
                        textFormat: Text.PlainText
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    SenderAvatar {
                        objectName: "messageHeaderAvatar"
                        Layout.preferredWidth: 42
                        Layout.preferredHeight: 42
                        displayName: root.sender
                        address: root.senderAddress
                        avatarResolver: root.store
                        allowRemoteContent: AppSettings.effectiveAllowRemoteContent
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.fillWidth: true
                            text: root.sender
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: (root.senderAddress !== root.sender ? root.senderAddress + " · " : "")
                                + (root.recipient !== "" ? "to " + root.recipient : "")
                            textFormat: Text.PlainText
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        text: root.timestampText
                        textFormat: Text.PlainText
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.borderSoft
                }

                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    visible: store.readerLoading
                    running: visible
                }

                Loader {
                    id: htmlLoader
                    property real renderedHeight: 160
                    property string loadedHtml: ""
                    Layout.fillWidth: true
                    Layout.preferredHeight: renderedHeight
                    visible: !store.readerLoading && root.hasHtmlBody && !root.htmlRenderFailed
                    active: root.hasHtmlBody && !root.htmlRenderFailed
                    sourceComponent: Component {
                        HtmlMessageView {
                            html: root.bodyHtml
                            foregroundColor: Theme.text
                            mutedColor: Theme.textMuted
                            linkColor: Theme.accent
                            pageColor: Theme.surface
                            allowRemoteContent: AppSettings.effectiveAllowRemoteContent
                            onHtmlChanged: htmlLoader.loadedHtml = html
                            Component.onCompleted: htmlLoader.loadedHtml = html
                        }
                    }
                    onStatusChanged: {
                        if (status === Loader.Error) root.htmlRenderFailed = true
                    }
                }

                Connections {
                    target: htmlLoader.item
                    enabled: htmlLoader.item !== null
                    function onRenderingFailed() { root.htmlRenderFailed = true }
                    function onPreferredHeightChanged(height) {
                        htmlLoader.renderedHeight = height
                    }
                    function onExternalLinkRequested(url) {
                        Qt.openUrlExternally(url)
                    }
                }

                TextArea {
                    Layout.fillWidth: true
                    visible: !store.readerLoading && (!root.hasHtmlBody || root.htmlRenderFailed)
                    text: root.bodyText
                    textFormat: Text.PlainText
                    wrapMode: TextEdit.Wrap
                    readOnly: true
                    selectByMouse: true
                    color: Theme.text
                    selectionColor: Theme.accentSoft
                    selectedTextColor: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 15
                    background: null
                    padding: 0
                    implicitHeight: contentHeight
                }

                ColumnLayout {
                    visible: Array.isArray(root.message.attachments)
                        && root.message.attachments.length > 0
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    spacing: 6
                    Text {
                        text: root.message.attachments && root.message.attachments.length === 1
                            ? "1 attachment" : (root.message.attachments
                                ? root.message.attachments.length : 0) + " attachments"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }
                    Text {
                        visible: root.attachmentStatus !== ""
                        text: root.attachmentStatus
                        textFormat: Text.PlainText
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }
                    Repeater {
                        model: root.message.attachments || []
                        delegate: Rectangle {
                            id: attachmentRow
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 52
                            radius: Theme.radiusSmall
                            color: Theme.surfaceRaised
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 6
                                spacing: 10
                                Text {
                                    text: Theme.icon("attach")
                                    color: Theme.textSecondary
                                    font.family: Theme.iconFont
                                    font.pixelSize: 20
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        Layout.fillWidth: true
                                        text: attachmentRow.modelData.filename || "Attachment"
                                        textFormat: Text.PlainText
                                        color: Theme.text
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 12
                                        elide: Text.ElideMiddle
                                    }
                                    Text {
                                        text: root.humanSize(attachmentRow.modelData.size)
                                        color: Theme.textMuted
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 10
                                    }
                                }
                                Button {
                                    text: "Open"
                                    flat: true
                                    onClicked: root.store.downloadAttachment(
                                        attachmentRow.modelData, true, function(result, error) {
                                            root.attachmentDownloaded(result, error, true)
                                        })
                                }
                                IconButton {
                                    iconName: "archive"
                                    tip: "Save attachment"
                                    onClicked: root.store.downloadAttachment(
                                        attachmentRow.modelData, false, function(result, error) {
                                            root.attachmentDownloaded(result, error, false)
                                        })
                                }
                            }
                        }
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    spacing: 10
                    PrimaryButton {
                        text: "Reply"
                        iconName: "reply"
                        onClicked: root.composeRequested("reply", root.message)
                    }
                    PrimaryButton {
                        text: "Reply all"
                        iconName: "replyAll"
                        onClicked: root.composeRequested("reply_all", root.message)
                    }
                    PrimaryButton {
                        text: "Forward"
                        iconName: "forward"
                        onClicked: root.composeRequested("forward", root.message)
                    }
                }
            }
        }
    }

    FileDialog {
        id: saveDialog
        title: "Save attachment"
        fileMode: FileDialog.SaveFile
        acceptLabel: "Save"
        onAccepted: {
            const destination = root.localPath(selectedFile)
            if (root.pendingSaveSource === "" || destination === "" || destination[0] !== "/") {
                root.store.errorText = "Choose a valid local destination"
                root.pendingSaveSource = ""
                return
            }
            root.attachmentStatus = "Saving attachment…"
            const source = root.pendingSaveSource
            root.pendingSaveSource = ""
            root.store.saveAttachmentTo(source, destination, function(error) {
                if (!error) root.attachmentStatus = "Attachment saved"
                else {
                    root.attachmentStatus = ""
                    root.store.errorText = error.message || "The attachment could not be saved"
                }
            })
        }
        onRejected: root.pendingSaveSource = ""
    }

    Shortcut { sequence: "R"; enabled: store.selectedMessage !== null; onActivated: root.composeRequested("reply", root.message) }
    Shortcut { sequence: "A"; enabled: store.selectedMessage !== null; onActivated: root.composeRequested("reply_all", root.message) }
    Shortcut { sequence: "F"; enabled: store.selectedMessage !== null; onActivated: root.composeRequested("forward", root.message) }
    Shortcut { sequence: "E"; enabled: store.selectedMessage !== null; onActivated: store.archive(root.message) }
    Shortcut { sequence: "S"; enabled: store.selectedMessage !== null; onActivated: store.toggleStar(root.message) }
    Shortcut { sequence: "Delete"; enabled: store.selectedMessage !== null; onActivated: store.trash(root.message) }

    onMessageChanged: {
        attachmentStatus = ""
        pendingSaveSource = ""
        htmlRenderFailed = false
        deferThreadAvatarLayout()
    }
}
