pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property bool collapsed: false
    readonly property bool calendarParentSelected: store.view === "calendar"
    readonly property bool mailParentSelected: !calendarParentSelected
    readonly property bool mailNavigationVisible: mailNavigation.visible
    readonly property int parentLabelHoverDelay: 550
    signal mailRequested()
    signal composeRequested()
    signal draftsRequested()
    signal calendarRequested()
    signal accountSetupRequested(var account)

    color: Theme.surface
    border.width: 0

    readonly property var standardFolders: [
        { id: "inbox", name: "Inbox", icon: "inbox" },
        { id: "unread", name: "Unread", icon: "unread" },
        { id: "starred", name: "Starred", icon: "star" },
        { id: "drafts", name: "Drafts", icon: "drafts" },
        { id: "sent", name: "Sent", icon: "sent" },
        { id: "archive", name: "Archive", icon: "archive" },
        { id: "trash", name: "Trash", icon: "trash" }
    ]
    readonly property var visibleFolders: {
        const remote = Array.isArray(store.folders) ? store.folders : []
        return remote.length > 0 ? remote : standardFolders
    }

    function displayFolderName(folder) {
        return FolderPresentation.displayName(folder)
    }

    function displayFolderIcon(folder) {
        return FolderPresentation.iconName(folder)
    }

    function selectMailParent() {
        mailRequested()
    }

    function selectCalendarParent() {
        calendarRequested()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 4

        Rectangle {
            id: parentSwitcher

            Layout.fillWidth: true
            Layout.topMargin: 8
            Layout.preferredHeight: root.collapsed ? 94 : 50
            radius: Theme.radius
            color: Theme.surfaceRaised
            border.width: 1
            border.color: Theme.borderSoft

            GridLayout {
                anchors.fill: parent
                anchors.margins: 3
                columns: root.collapsed ? 1 : 2
                rows: root.collapsed ? 2 : 1
                columnSpacing: 3
                rowSpacing: 3

                Button {
                    id: mailParentButton
                    objectName: "mailParentButton"

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    flat: true
                    hoverEnabled: true
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: "Mail"
                    Accessible.description: root.mailParentSelected
                        ? "Current top-level section" : "Open the Mail section"
                    onClicked: root.selectMailParent()

                    contentItem: RowLayout {
                        spacing: 6
                        Item { Layout.fillWidth: true }
                        Text {
                            text: Theme.icon("mail")
                            color: root.mailParentSelected
                                ? Theme.accentSoftText : Theme.textSecondary
                            font.family: Theme.iconFont
                            font.pixelSize: 19

                            Behavior on color {
                                enabled: Theme.animationsEnabled
                                ColorAnimation {
                                    duration: Theme.motionFast
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: root.mailParentSelected ? Theme.accentSoft
                            : mailParentButton.down ? Theme.surfaceSelected
                            : mailParentButton.hovered || mailParentButton.visualFocus
                                ? Theme.surfaceHover : "transparent"
                        border.width: mailParentButton.visualFocus ? 1 : 0
                        border.color: Theme.accent

                        Behavior on color {
                            enabled: Theme.animationsEnabled
                            ColorAnimation {
                                duration: Theme.motionFast
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    ToolTip.visible: hovered
                    ToolTip.text: "Mail"
                    ToolTip.delay: root.parentLabelHoverDelay
                }

                Button {
                    id: calendarParentButton
                    objectName: "calendarParentButton"

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    flat: true
                    hoverEnabled: true
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: "Calendar"
                    Accessible.description: root.calendarParentSelected
                        ? "Current top-level section" : "Open the Calendar section"
                    onClicked: root.selectCalendarParent()

                    contentItem: RowLayout {
                        spacing: 6
                        Item { Layout.fillWidth: true }
                        Text {
                            text: Theme.icon("calendar")
                            color: root.calendarParentSelected
                                ? Theme.accentSoftText : Theme.textSecondary
                            font.family: Theme.iconFont
                            font.pixelSize: 19

                            Behavior on color {
                                enabled: Theme.animationsEnabled
                                ColorAnimation {
                                    duration: Theme.motionFast
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: root.calendarParentSelected ? Theme.accentSoft
                            : calendarParentButton.down ? Theme.surfaceSelected
                            : calendarParentButton.hovered || calendarParentButton.visualFocus
                                ? Theme.surfaceHover : "transparent"
                        border.width: calendarParentButton.visualFocus ? 1 : 0
                        border.color: Theme.accent

                        Behavior on color {
                            enabled: Theme.animationsEnabled
                            ColorAnimation {
                                duration: Theme.motionFast
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    ToolTip.visible: hovered
                    ToolTip.text: "Calendar"
                    ToolTip.delay: root.parentLabelHoverDelay
                }
            }
        }

        ColumnLayout {
            id: mailNavigation

            visible: root.mailParentSelected
            opacity: root.mailParentSelected ? 1 : 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 4

            Behavior on opacity {
                enabled: Theme.animationsEnabled
                NumberAnimation {
                    duration: Theme.motionMedium
                    easing.type: Easing.OutCubic
                }
            }

            Text {
                visible: !root.collapsed
                Layout.leftMargin: 10
                Layout.topMargin: 10
                Layout.bottomMargin: 2
                text: "MAIL"
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
            }

            PrimaryButton {
                Layout.fillWidth: true
                text: root.collapsed ? "" : "New message"
                iconName: "compose"
                onClicked: root.composeRequested()
            }

            Button {
                id: savedDraftsButton

                Layout.fillWidth: true
                Layout.preferredHeight: 40
                leftPadding: 10
                rightPadding: 10
                flat: true
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                onClicked: root.draftsRequested()
                contentItem: RowLayout {
                    spacing: 12
                    Text {
                        objectName: "savedDraftsIcon"
                        text: Theme.icon("drafts")
                        color: root.store.draftsOpen ? Theme.accent : Theme.textSecondary
                        font.family: Theme.iconFont
                        font.pixelSize: 20

                        Behavior on color {
                            enabled: Theme.animationsEnabled
                            ColorAnimation {
                                duration: Theme.motionFast
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                    Text {
                        visible: !root.collapsed
                        Layout.fillWidth: true
                        text: "Saved drafts"
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: !root.collapsed && Array.isArray(root.store.drafts)
                            && root.store.drafts.length > 0
                        text: root.store.drafts.length > 99
                            ? "99+" : String(root.store.drafts.length)
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                    }
                }
                background: Rectangle {
                    radius: Theme.radiusSmall
                    color: root.store.draftsOpen ? Theme.surfaceSelected
                        : savedDraftsButton.hovered || savedDraftsButton.visualFocus
                            ? Theme.surfaceHover : "transparent"
                    border.width: savedDraftsButton.visualFocus ? 1 : 0
                    border.color: Theme.accent

                    Behavior on color {
                        enabled: Theme.animationsEnabled
                        ColorAnimation {
                            duration: Theme.motionFast
                            easing.type: Easing.OutCubic
                        }
                    }
                }
                ToolTip.visible: root.collapsed && hovered
                ToolTip.text: "Saved drafts"
                ToolTip.delay: 500
            }

            Text {
                visible: !root.collapsed
                Layout.leftMargin: 10
                Layout.topMargin: 8
                Layout.bottomMargin: 4
                text: "MAILBOXES"
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
            }

            ListView {
                id: folderList

                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 2
                model: root.visibleFolders
                currentIndex: {
                    for (let i = 0; i < root.visibleFolders.length; ++i) {
                        const folder = root.visibleFolders[i]
                        if (String(folder.id || folder.folder_id)
                                === root.store.activeFolderId) return i
                    }
                    return -1
                }
                delegate: Rectangle {
                    id: folderRow

                    required property var modelData
                    required property int index
                    width: folderList.width
                    height: 42
                    radius: Theme.radiusSmall
                    color: folderList.currentIndex === index ? Theme.surfaceSelected
                        : folderMouse.containsMouse ? Theme.surfaceHover : "transparent"
                    readonly property string folderId: String(modelData.id
                        || modelData.folder_id || "")
                    readonly property string folderName: root.displayFolderName(modelData)
                    readonly property string folderIcon: root.displayFolderIcon(modelData)

                    Behavior on color {
                        enabled: Theme.animationsEnabled
                        ColorAnimation {
                            duration: Theme.motionFast
                            easing.type: Easing.OutCubic
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 12
                        Text {
                            objectName: "folderIcon"
                            text: Theme.icon(folderRow.folderIcon)
                            color: folderList.currentIndex === folderRow.index
                                ? Theme.accent : Theme.textSecondary
                            font.family: Theme.iconFont
                            font.pixelSize: 20

                            Behavior on color {
                                enabled: Theme.animationsEnabled
                                ColorAnimation {
                                    duration: Theme.motionFast
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                        Text {
                            visible: !root.collapsed
                            Layout.fillWidth: true
                            text: folderRow.folderName
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            visible: !root.collapsed
                                && Number(modelData.unread_count || modelData.unread || 0) > 0
                            implicitWidth: countText.implicitWidth + 12
                            implicitHeight: 22
                            radius: 11
                            color: Theme.accentSoft
                            Text {
                                id: countText
                                anchors.centerIn: parent
                                text: Number(modelData.unread_count
                                    || modelData.unread || 0) > 999 ? "999+"
                                    : String(modelData.unread_count || modelData.unread || "")
                                color: Theme.accent
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                    MouseArea {
                        id: folderMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.store.selectFolder(folderRow.folderId)
                    }
                }
            }
        }

        ColumnLayout {
            id: calendarNavigation

            visible: root.calendarParentSelected
            opacity: root.calendarParentSelected ? 1 : 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8

            Behavior on opacity {
                enabled: Theme.animationsEnabled
                NumberAnimation {
                    duration: Theme.motionMedium
                    easing.type: Easing.OutCubic
                }
            }

            Text {
                visible: !root.collapsed
                Layout.leftMargin: 10
                Layout.topMargin: 10
                text: "CALENDAR"
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
            }

            Rectangle {
                visible: !root.collapsed
                Layout.fillWidth: true
                Layout.preferredHeight: 76
                radius: Theme.radius
                color: Theme.surfaceRaised
                border.width: 1
                border.color: Theme.borderSoft

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: 17
                        color: Theme.accentSoft
                        Text {
                            anchors.centerIn: parent
                            text: Theme.icon("calendar")
                            color: Theme.accentSoftText
                            font.family: Theme.iconFont
                            font.pixelSize: 19
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            Layout.fillWidth: true
                            text: "Events & tasks"
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: (Array.isArray(root.store.events)
                                ? root.store.events.length : 0) + " events · "
                                + (Array.isArray(root.store.tasks)
                                    ? root.store.tasks.filter(task => !task.done).length : 0)
                                + " open tasks"
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        Text {
            visible: !root.collapsed
            Layout.leftMargin: 10
            Layout.topMargin: 4
            text: "ACCOUNTS"
            color: Theme.textMuted
            font.family: Theme.fontFamily
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.letterSpacing: 1.2
        }

        ListView {
            id: accountList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(100, contentHeight)
            clip: true
            spacing: 2
            model: store.accounts
            delegate: Rectangle {
                id: accountRow
                required property var modelData
                width: accountList.width
                height: 46
                radius: Theme.radiusSmall
                color: String(modelData.id || modelData.account_id || "") === store.activeAccountId
                    ? Theme.surfaceHover : accountMouse.containsMouse ? Theme.surfaceHover : "transparent"

                Behavior on color {
                    enabled: Theme.animationsEnabled
                    ColorAnimation {
                        duration: Theme.motionFast
                        easing.type: Easing.OutCubic
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 8
                    spacing: 10
                    Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        radius: 16
                        color: Theme.accentSoft
                        Text {
                            anchors.centerIn: parent
                            text: Theme.initials(modelData.displayName || modelData.display_name
                                || modelData.address || modelData.email)
                            textFormat: Text.PlainText
                            color: Theme.accent
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                            font.weight: Font.Bold
                        }
                    }
                    Column {
                        visible: !root.collapsed
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            width: parent.width
                            text: modelData.displayName || modelData.display_name
                                || modelData.address || modelData.email || "Account"
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: modelData.address || modelData.email || modelData.provider || ""
                            textFormat: Text.PlainText
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                    IconButton {
                        visible: !root.collapsed
                        Layout.preferredWidth: 30
                        Layout.preferredHeight: 30
                        iconName: "settings"
                        tip: "Reconnect account"
                        onClicked: root.accountSetupRequested(accountRow.modelData)
                    }
                }
                MouseArea {
                    id: accountMouse
                    anchors.fill: parent
                    anchors.rightMargin: root.collapsed ? 0 : 38
                    hoverEnabled: true
                    onClicked: root.store.selectAccount(String(accountRow.modelData.id
                        || accountRow.modelData.account_id || ""))
                }
            }
        }

        Button {
            Layout.fillWidth: true
            text: root.collapsed ? "+" : "+  Add account"
            flat: true
            onClicked: root.accountSetupRequested(null)
        }
    }
}
