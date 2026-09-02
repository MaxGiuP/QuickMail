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
    property bool htmlRenderReady: false
    property int htmlRenderGeneration: 0
    property real _zoomWheelAngleRemainder: 0
    property real _zoomWheelPixelRemainder: 0
    property real _pendingZoomScrollRatio: 0
    property bool _zoomScrollRestorePending: false
    property int _zoomScrollRestoreGeneration: 0
    property string _displayedMessageId: ""
    readonly property bool settingsMenuVisible: readerSettings.visible
    readonly property int settingsMenuItemCount: readerSettings.count
    readonly property bool compactSettingChecked: compactMessageListSetting.checked
    readonly property bool composeFormattingSettingChecked: composeFormattingSetting.checked
    readonly property bool darkModeSettingChecked: darkModeSetting.checked
    readonly property bool systemThemeSettingChecked: systemThemeSetting.checked
    readonly property int minimumZoomPercent: 50
    readonly property int maximumZoomPercent: 200
    readonly property int zoomStepPercent: 10
    readonly property int messageZoomPercent: normalizedZoomPercent(
        AppSettings.readerZoomPercent)
    readonly property real messageZoomFactor: messageZoomPercent / 100
    readonly property bool canZoomIn: messageZoomPercent < maximumZoomPercent
    readonly property bool canZoomOut: messageZoomPercent > minimumZoomPercent
    readonly property var readerActiveFocusItem: root.Window.window
        ? root.Window.window.activeFocusItem : null
    readonly property bool readerShortcutsEnabled: root.visible && root.enabled
        && store.selectedMessage !== null && !readerSettings.visible
        && !attachmentViewer.visible
        && itemBelongsToReader(readerActiveFocusItem)
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
    readonly property bool messageIsUnread: message.unread === true
        || message.is_read === false || message.read === false
    readonly property string renderedBodyHtml: hasHtmlBody ? htmlLoader.loadedHtml : ""
    readonly property int threadCount: Array.isArray(store.threadMessages)
        ? store.threadMessages.length : 0
    readonly property int knownThreadCount: Math.max(threadCount,
        Number(message.conversationCount || 1))
    readonly property bool hasConversation: knownThreadCount > 1
    readonly property int threadSenderCount: countThreadSenders()
    readonly property string timestampText: formatTimestamp(message.date_display
        || message.received_display || message.timestamp || message.received_at || "")

    function scheduleHtmlRender() {
        const generation = ++htmlRenderGeneration
        htmlRenderReady = false
        htmlRenderFailed = false
        // Let the selected-message header paint before QTextDocument performs
        // the first rich-layout pass, which can take more than one frame.
        Qt.callLater(function() {
            if (generation === root.htmlRenderGeneration)
                root.htmlRenderReady = true
        })
    }

    onBodyHtmlChanged: scheduleHtmlRender()

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
    Component.onCompleted: {
        _displayedMessageId = currentMessageId()
        deferThreadAvatarLayout()
        scheduleHtmlRender()
    }

    function singleLine(value) {
        return String(value === undefined || value === null ? "" : value)
            .replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
            .replace(/\s+/g, " ").trim()
    }

    function addressList(value) {
        if (!Array.isArray(value)) return String(value || "")
        return value.map(entry => entry.name || entry.address || "").filter(Boolean).join(", ")
    }

    function normalizedZoomPercent(value) {
        const requested = Number(value)
        if (!isFinite(requested)) return 100
        return Math.max(minimumZoomPercent, Math.min(maximumZoomPercent,
            Math.round(requested)))
    }

    function itemBelongsToReader(item) {
        let current = item
        while (current !== null && current !== undefined) {
            if (current === root) return true
            current = current.parent
        }
        return false
    }

    function currentMessageId() {
        if (store.selectedMessage === null) return ""
        if (typeof store.messageId === "function")
            return String(store.messageId(root.message) || "")
        return String(root.message.id || root.message.message_id || "")
    }

    function deferZoomScrollRestore() {
        if (!_zoomScrollRestorePending) return
        const generation = ++_zoomScrollRestoreGeneration
        Qt.callLater(function() {
            Qt.callLater(function() {
                if (generation !== root._zoomScrollRestoreGeneration
                        || !root._zoomScrollRestorePending) return
                root.setReaderScroll(root._pendingZoomScrollRatio
                    * root.maximumReaderScroll())
                root._zoomScrollRestorePending = false
            })
        })
    }

    function beginZoomScrollRestore() {
        if (!_zoomScrollRestorePending) {
            const maximum = maximumReaderScroll()
            _pendingZoomScrollRatio = maximum > 0
                ? Math.max(0, Math.min(1, bodyFlick.contentY / maximum)) : 0
            _zoomScrollRestorePending = true
        }
        deferZoomScrollRestore()
    }

    function toggleReaderSettings() {
        if (readerSettings.visible) readerSettings.close()
        else readerSettings.open()
    }

    function setMessageZoomPercent(value) {
        const next = normalizedZoomPercent(value)
        if (AppSettings.readerZoomPercent !== next) {
            beginZoomScrollRestore()
            AppSettings.readerZoomPercent = next
        }
    }

    function adjustMessageZoom(percentagePoints) {
        const delta = Number(percentagePoints)
        if (!isFinite(delta) || delta === 0) return
        setMessageZoomPercent(messageZoomPercent + delta)
    }

    function zoomIn() {
        adjustMessageZoom(zoomStepPercent)
    }

    function zoomOut() {
        adjustMessageZoom(-zoomStepPercent)
    }

    function resetZoom() {
        resetZoomWheelAccumulator()
        setMessageZoomPercent(100)
    }

    function resetZoomWheelAccumulator() {
        zoomWheelAccumulatorReset.stop()
        _zoomWheelAngleRemainder = 0
        _zoomWheelPixelRemainder = 0
    }

    function wholeWheelSteps(value, threshold) {
        const scaled = value / threshold
        return scaled < 0 ? Math.ceil(scaled) : Math.floor(scaled)
    }

    function handleReaderZoomWheel(angleDelta, pixelDelta, modifiers) {
        if (Number(modifiers) !== Number(Qt.ControlModifier)) return false
        const angle = Number(angleDelta || 0)
        const pixel = Number(pixelDelta || 0)
        if (!isFinite(angle) || !isFinite(pixel)
                || (angle === 0 && pixel === 0)) return false
        zoomWheelAccumulatorReset.restart()

        let steps = 0
        if (angle !== 0) {
            if (_zoomWheelAngleRemainder !== 0
                    && Math.sign(_zoomWheelAngleRemainder) !== Math.sign(angle))
                _zoomWheelAngleRemainder = 0
            _zoomWheelAngleRemainder += angle
            steps = wholeWheelSteps(_zoomWheelAngleRemainder, 120)
            _zoomWheelAngleRemainder -= steps * 120
            _zoomWheelPixelRemainder = 0
        } else {
            if (_zoomWheelPixelRemainder !== 0
                    && Math.sign(_zoomWheelPixelRemainder) !== Math.sign(pixel))
                _zoomWheelPixelRemainder = 0
            _zoomWheelPixelRemainder += pixel
            steps = wholeWheelSteps(_zoomWheelPixelRemainder, 40)
            _zoomWheelPixelRemainder -= steps * 40
            _zoomWheelAngleRemainder = 0
        }
        if (steps !== 0) adjustMessageZoom(steps * zoomStepPercent)
        return true
    }

    Timer {
        id: zoomWheelAccumulatorReset
        interval: 400
        repeat: false
        onTriggered: root.resetZoomWheelAccumulator()
    }

    function maximumReaderScroll() {
        return Math.max(0, bodyFlick.contentHeight - bodyFlick.height)
    }

    function setReaderScroll(value) {
        bodyFlick.contentY = Math.max(0, Math.min(maximumReaderScroll(),
            Number(value) || 0))
        bodyFlick.returnToBounds()
    }

    function scrollReaderPage(direction) {
        setReaderScroll(bodyFlick.contentY + Number(direction || 0)
            * Math.max(80, bodyFlick.height * 0.85))
    }

    function scrollReaderToStart() {
        setReaderScroll(0)
    }

    function scrollReaderToEnd() {
        setReaderScroll(maximumReaderScroll())
    }

    function markUnread() {
        if (store.selectedMessage !== null && !messageIsUnread
                && typeof store.markRead === "function")
            store.markRead(root.message, false)
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

    function threadUnread(item) {
        return item && (item.unread === true || item.is_read === false || item.read === false)
    }

    function countThreadSenders() {
        const senders = []
        const list = Array.isArray(store.threadMessages) ? store.threadMessages : []
        for (let index = 0; index < list.length; ++index) {
            const item = list[index]
            const identity = senderAddressFor(item).toLowerCase() || threadSender(item).toLowerCase()
            if (identity !== "" && senders.indexOf(identity) < 0)
                senders.push(identity)
        }
        return senders.length
    }

    function threadMessageCountLabel() {
        const count = root.knownThreadCount
        let label = AgendaTranslations.tr("%n message(s)", count)
        if (store.threadTruncated)
            label = label.replace(String(count), String(count) + "+")
        return label
    }

    function threadBannerDetail() {
        if (store.threadLoading && root.threadCount < root.knownThreadCount)
            return AgendaTranslations.tr("Loading conversation · %1…")
                .arg(root.threadMessageCountLabel())
        const senders = root.threadSenderCount
        return AgendaTranslations.tr("Conversation · %1")
            .arg(root.threadMessageCountLabel())
            + (senders > 1
                ? AgendaTranslations.tr(" · %n sender(s)", senders) : "")
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

    function beginAttachmentSave(path, filenameValue) {
        pendingSaveSource = String(path || "")
        if (pendingSaveSource === "" || pendingSaveSource[0] !== "/"
                || pendingSaveSource.indexOf("\u0000") >= 0) {
            pendingSaveSource = ""
            store.errorText = "The attachment path is invalid"
            return
        }
        const directory = StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        if (directory === "") {
            pendingSaveSource = ""
            store.errorText = "The Downloads folder is unavailable"
            return
        }
        const filename = safeFilename(filenameValue)
        saveDialog.currentFolder = localFileUrl(directory)
        saveDialog.selectedFile = localFileUrl(directory + "/" + filename)
        saveDialog.open()
    }

    function attachmentDownloaded(result, error, previewWhenReady) {
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
        if (previewWhenReady) {
            attachmentStatus = ""
            if (!attachmentViewer.showFile(result))
                store.errorText = "QuickMail could not open this attachment preview"
            return
        }
        beginAttachmentSave(path, result.filename)
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
            Button {
                id: zoomIndicator
                objectName: "readerZoomIndicator"
                visible: store.selectedMessage !== null
                Layout.preferredWidth: 52
                flat: true
                text: root.messageZoomPercent + "%"
                enabled: root.messageZoomPercent !== 100
                font.family: Theme.fontFamily
                font.pixelSize: 11
                onClicked: root.resetZoom()
                ToolTip.visible: hovered
                ToolTip.text: AgendaTranslations.tr("Reset zoom (Ctrl+0)")
            }
            IconButton {
                iconName: "unread"
                tip: AgendaTranslations.tr("Mark as unread (Shift+U)")
                enabled: store.selectedMessage !== null && !root.messageIsUnread
                onClicked: root.markUnread()
            }
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
                objectName: "readerSettingsButton"
                iconName: "settings"
                tip: AgendaTranslations.tr("QuickMail settings")
                onClicked: root.toggleReaderSettings()

                Menu {
                    id: readerSettings
                    objectName: "readerSettingsMenu"
                    x: parent.width - width
                    y: parent.height
                    closePolicy: Popup.CloseOnEscape
                        | Popup.CloseOnPressOutsideParent
                    MenuItem {
                        objectName: "remoteContentSetting"
                        text: AgendaTranslations.tr("Load remote content")
                        checkable: true
                        checked: AppSettings.allowRemoteContent
                        onTriggered: AppSettings.allowRemoteContent = checked
                    }
                    MenuItem {
                        text: AgendaTranslations.tr("Always match app colours")
                        checkable: true
                        checked: AppSettings.useThemeEmailColors
                        onTriggered: AppSettings.useThemeEmailColors = checked
                    }
                    MenuItem {
                        id: compactMessageListSetting
                        objectName: "compactMessageListSetting"
                        text: AgendaTranslations.tr("Compact message list")
                        checkable: true
                        checked: AppSettings.compactMessageList
                        onTriggered: AppSettings.compactMessageList = checked
                    }
                    MenuItem {
                        id: composeFormattingSetting
                        objectName: "composeFormattingSetting"
                        text: AgendaTranslations.tr("Show compose formatting tools")
                        checkable: true
                        checked: AppSettings.composeFormattingExpanded
                        onTriggered: AppSettings.composeFormattingExpanded = checked
                    }
                    MenuSeparator {}
                    MenuItem {
                        id: systemThemeSetting
                        objectName: "systemThemeSetting"
                        text: AgendaTranslations.tr("Follow system theme")
                        checkable: true
                        checked: Theme.followsSystemTheme
                        onTriggered: AppSettings.themeMode = checked ? "system"
                            : Theme.darkMode ? "dark" : "light"
                    }
                    MenuItem {
                        id: darkModeSetting
                        objectName: "darkModeSetting"
                        text: AgendaTranslations.tr("Dark mode")
                        checkable: true
                        checked: Theme.darkMode
                        onTriggered: AppSettings.themeMode = checked ? "dark" : "light"
                    }
                    MenuSeparator {}
                    MenuItem {
                        objectName: "readerZoomInMenuItem"
                        text: AgendaTranslations.tr("Zoom in") + "\tCtrl++"
                        enabled: root.canZoomIn
                        onTriggered: root.zoomIn()
                    }
                    MenuItem {
                        objectName: "readerZoomOutMenuItem"
                        text: AgendaTranslations.tr("Zoom out") + "\tCtrl+-"
                        enabled: root.canZoomOut
                        onTriggered: root.zoomOut()
                    }
                    MenuItem {
                        objectName: "readerZoomResetMenuItem"
                        text: AgendaTranslations.tr("Reset zoom (%1%)")
                            .arg(root.messageZoomPercent) + "\tCtrl+0"
                        enabled: root.messageZoomPercent !== 100
                        onTriggered: root.resetZoom()
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
            objectName: "readerBodyFlick"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: store.selectedMessage !== null
            contentWidth: width
            contentHeight: article.implicitHeight + 48
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            onWidthChanged: root.deferThreadAvatarLayout()

            WheelHandler {
                id: readerZoomWheelHandler
                objectName: "readerZoomWheelHandler"
                target: null
                orientation: Qt.Vertical
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                acceptedModifiers: Qt.ControlModifier
                blocking: true
                onWheel: event => {
                    event.accepted = root.handleReaderZoomWheel(
                        event.angleDelta.y, event.pixelDelta.y,
                        event.modifiers)
                }
            }

            ColumnLayout {
                id: article
                objectName: "readerArticle"
                width: Math.min(bodyFlick.width - 48, 780)
                x: Math.max(24, (bodyFlick.width - width) / 2)
                y: 24
                spacing: 16

                Text {
                    objectName: "readerSubject"
                    Layout.fillWidth: true
                    text: root.message.subject || "(No subject)"
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 26
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                }

                ColumnLayout {
                    id: threadSection
                    objectName: "threadSection"
                    Layout.fillWidth: true
                    visible: root.hasConversation
                    spacing: 8

                    Rectangle {
                        id: threadBanner
                        objectName: "threadConversationBanner"
                        Layout.fillWidth: true
                        Layout.preferredHeight: 54
                        radius: Theme.radius
                        color: Theme.accentSoft
                        border.width: 1
                        border.color: Theme.accent

                        Accessible.role: Accessible.StaticText
                        Accessible.name: AgendaTranslations.tr("Conversation thread, %1")
                            .arg(root.threadBannerDetail())

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 10

                            Text {
                                text: Theme.icon("thread")
                                color: Theme.accent
                                font.family: Theme.iconFont
                                font.pixelSize: 24
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                Text {
                                    text: AgendaTranslations.tr("Conversation thread")
                                    textFormat: Text.PlainText
                                    color: Theme.accentSoftText
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                }

                                Text {
                                    id: threadBannerText
                                    objectName: "threadConversationBannerText"
                                    Layout.fillWidth: true
                                    text: root.threadBannerDetail()
                                    textFormat: Text.PlainText
                                    color: Theme.accentSoftText
                                    opacity: 0.8
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }

                            BusyIndicator {
                                visible: store.threadLoading
                                running: visible
                                Layout.preferredWidth: 22
                                Layout.preferredHeight: 22
                            }
                        }
                    }

                    Repeater {
                        model: store.threadMessages
                        delegate: Rectangle {
                            id: threadCard
                            objectName: "threadCard"
                            required property var modelData
                            required property int index
                            readonly property bool selectedMessage: root.threadSelected(modelData)
                            readonly property bool unreadMessage: root.threadUnread(modelData)
                            readonly property string displayTotal: store.threadTruncated
                                ? root.knownThreadCount + "+" : String(root.knownThreadCount)
                            readonly property string accessibleTotal: store.threadTruncated
                                ? AgendaTranslations.tr("at least %1").arg(root.knownThreadCount)
                                : String(root.knownThreadCount)
                            readonly property string positionLabel:
                                AgendaTranslations.tr("%1 of %2").arg(index + 1)
                                    .arg(displayTotal)
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
                            Layout.preferredHeight: 64
                            clip: true
                            radius: Theme.radiusSmall
                            color: selectedMessage
                                ? Theme.surfaceSelected : Theme.surfaceRaised
                            border.width: activeFocus ? 2 : 1
                            border.color: activeFocus || selectedMessage
                                ? Theme.accent : Theme.borderSoft
                            activeFocusOnTab: true

                            Accessible.role: Accessible.ListItem
                            Accessible.selected: selectedMessage
                            Accessible.name: AgendaTranslations.tr("Message %1 of %2 from %3")
                                .arg(index + 1).arg(accessibleTotal)
                                .arg(root.threadSender(modelData))
                            Accessible.description: selectedMessage
                                ? AgendaTranslations.tr("Current open message")
                                : unreadMessage ? AgendaTranslations.tr("Unread message")
                                    : AgendaTranslations.tr("Read message")

                            Behavior on color {
                                enabled: Theme.animationsEnabled
                                ColorAnimation { duration: Theme.motionMedium }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10

                                Item {
                                    Layout.preferredWidth: 18
                                    Layout.fillHeight: true

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: threadCard.index === 0 ? parent.height / 2 : 0
                                        width: 2
                                        height: threadCard.index === 0 || threadCard.index === root.threadCount - 1
                                            ? parent.height / 2 : parent.height
                                        visible: root.threadCount > 1
                                        color: Theme.border
                                    }

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: threadCard.selectedMessage ? 12 : 9
                                        height: width
                                        radius: width / 2
                                        color: threadCard.selectedMessage ? Theme.accent : Theme.surfaceRaised
                                        border.width: 2
                                        border.color: threadCard.selectedMessage
                                            ? Theme.accent : Theme.textMuted
                                    }

                                    Rectangle {
                                        objectName: "threadCardUnreadMarker"
                                        visible: threadCard.unreadMessage
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.topMargin: 9
                                        width: 7
                                        height: 7
                                        radius: 4
                                        color: Theme.accent
                                    }
                                }

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
                                        font.weight: threadCard.unreadMessage ? Font.Bold : Font.DemiBold
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
                                ColumnLayout {
                                    Layout.minimumWidth: 0
                                    Layout.maximumWidth: 112
                                    spacing: 2

                                    Text {
                                        Layout.alignment: Qt.AlignRight
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

                                    Rectangle {
                                        objectName: "threadCardCurrentMarker"
                                        visible: threadCard.selectedMessage
                                        Layout.alignment: Qt.AlignRight
                                        Layout.preferredWidth: 44
                                        Layout.preferredHeight: 17
                                        radius: 8
                                        color: Theme.accent

                                        Text {
                                            anchors.centerIn: parent
                                            text: AgendaTranslations.tr("OPEN")
                                            textFormat: Text.PlainText
                                            color: Theme.accentText
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 10
                                            font.weight: Font.Bold
                                        }
                                    }

                                    Text {
                                        objectName: "threadCardPosition"
                                        visible: !threadCard.selectedMessage
                                        Layout.alignment: Qt.AlignRight
                                        text: threadCard.positionLabel
                                        textFormat: Text.PlainText
                                        color: Theme.textMuted
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 9
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    threadCard.forceActiveFocus()
                                    root.store.openThreadMessage(threadCard.modelData)
                                }
                            }

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    root.store.openThreadMessage(threadCard.modelData)
                                    event.accepted = true
                                }
                            }

                            Accessible.onPressAction: {
                                threadCard.forceActiveFocus()
                                root.store.openThreadMessage(modelData)
                            }
                        }
                    }

                    Text {
                        visible: store.threadTruncated
                        text: AgendaTranslations.tr("Showing a 100-message window that keeps your selected message")
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
                    objectName: "messageHtmlLoader"
                    property real renderedHeight: 160
                    property string loadedHtml: ""
                    Layout.fillWidth: true
                    Layout.preferredHeight: renderedHeight
                    visible: !store.readerLoading && root.hasHtmlBody
                        && !root.htmlRenderFailed
                    active: root.hasHtmlBody && root.htmlRenderReady
                        && !root.htmlRenderFailed
                    sourceComponent: Component {
                        HtmlMessageView {
                            objectName: "messageHtmlView"
                            html: root.bodyHtml
                            trustedSanitizedHtml: true
                            useThemeColors: AppSettings.useThemeEmailColors
                            zoomFactor: root.messageZoomFactor
                            foregroundColor: Theme.text
                            mutedColor: Theme.textMuted
                            linkColor: Theme.accent
                            pageColor: Theme.surface
                            allowRemoteContent: AppSettings.effectiveAllowRemoteContent
                            onPreferredHeightChanged: preferredHeight => {
                                htmlLoader.renderedHeight = preferredHeight
                                root.deferZoomScrollRestore()
                            }
                            onHtmlChanged: htmlLoader.loadedHtml = html
                            Component.onCompleted: {
                                htmlLoader.loadedHtml = html
                                htmlLoader.renderedHeight = rendererHeight
                            }
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
                    function onExternalLinkRequested(url) {
                        Qt.openUrlExternally(url)
                    }
                }

                TextArea {
                    id: plainBody
                    objectName: "plainMessageBody"
                    Layout.fillWidth: true
                    visible: !store.readerLoading && (!root.hasHtmlBody || root.htmlRenderFailed)
                    text: root.bodyText
                    textFormat: Text.PlainText
                    wrapMode: TextEdit.Wrap
                    readOnly: true
                    selectByMouse: true
                    persistentSelection: true
                    color: Theme.text
                    selectionColor: Theme.accentSoft
                    selectedTextColor: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 15 * root.messageZoomFactor
                    background: null
                    padding: 0
                    implicitHeight: contentHeight
                    onContentHeightChanged: root.deferZoomScrollRestore()

                    TextContextMenuArea {
                        objectName: "plainTextContextArea"
                        anchors.fill: parent
                        editor: plainBody
                        editable: false
                    }
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
                                    text: "Preview"
                                    flat: true
                                    Accessible.name: "Preview "
                                        + (attachmentRow.modelData.filename || "attachment")
                                    onClicked: {
                                        root.attachmentStatus = "Loading preview…"
                                        root.store.downloadAttachment(
                                            attachmentRow.modelData, true, function(result, error) {
                                                root.attachmentDownloaded(result, error, true)
                                            })
                                    }
                                }
                                IconButton {
                                    iconName: "save"
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

    AttachmentViewer {
        id: attachmentViewer
        parent: Overlay.overlay
        onSaveRequested: (sourcePath, filename) => {
            root.beginAttachmentSave(sourcePath, filename)
        }
    }

    Shortcut {
        objectName: "readerZoomInShortcut"
        sequences: [StandardKey.ZoomIn]
        enabled: root.readerShortcutsEnabled
        onActivated: root.zoomIn()
    }
    Shortcut {
        objectName: "readerZoomOutShortcut"
        sequences: [StandardKey.ZoomOut]
        enabled: root.readerShortcutsEnabled
        onActivated: root.zoomOut()
    }
    Shortcut {
        objectName: "readerZoomResetShortcut"
        sequence: "Ctrl+0"
        enabled: root.readerShortcutsEnabled
        onActivated: root.resetZoom()
    }
    Shortcut {
        sequence: "PageDown"
        enabled: root.readerShortcutsEnabled
        onActivated: root.scrollReaderPage(1)
    }
    Shortcut {
        sequence: "PageUp"
        enabled: root.readerShortcutsEnabled
        onActivated: root.scrollReaderPage(-1)
    }
    Shortcut {
        sequence: "Home"
        enabled: root.readerShortcutsEnabled
        onActivated: root.scrollReaderToStart()
    }
    Shortcut {
        sequence: "End"
        enabled: root.readerShortcutsEnabled
        onActivated: root.scrollReaderToEnd()
    }
    Shortcut { sequence: "R"; enabled: root.readerShortcutsEnabled; onActivated: root.composeRequested("reply", root.message) }
    Shortcut { sequence: "A"; enabled: root.readerShortcutsEnabled; onActivated: root.composeRequested("reply_all", root.message) }
    Shortcut { sequence: "F"; enabled: root.readerShortcutsEnabled; onActivated: root.composeRequested("forward", root.message) }
    Shortcut { sequence: "E"; enabled: root.readerShortcutsEnabled; onActivated: store.archive(root.message) }
    Shortcut { sequence: "S"; enabled: root.readerShortcutsEnabled; onActivated: store.toggleStar(root.message) }
    Shortcut { sequence: "Shift+U"; enabled: root.readerShortcutsEnabled && !root.messageIsUnread; onActivated: root.markUnread() }
    Shortcut { sequence: "Delete"; enabled: root.readerShortcutsEnabled; onActivated: store.trash(root.message) }

    onMessageChanged: {
        const nextMessageId = currentMessageId()
        attachmentViewer.close()
        attachmentStatus = ""
        pendingSaveSource = ""
        htmlRenderFailed = false
        if (nextMessageId !== _displayedMessageId) {
            ++_zoomScrollRestoreGeneration
            _zoomScrollRestorePending = false
            resetZoomWheelAccumulator()
            bodyFlick.cancelFlick()
            bodyFlick.contentY = 0
        }
        _displayedMessageId = nextMessageId
        deferThreadAvatarLayout()
    }
}
