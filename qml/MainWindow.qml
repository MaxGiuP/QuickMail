import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"

Item {
    id: root
    required property var store

    readonly property bool mobile: width < 720
    readonly property bool medium: width >= 720 && width < 1080
    readonly property bool navigationCollapsed: width < 900
    property string mobilePage: "list"
    property bool navigationOpen: false
    property bool accountSetupOpen: false
    property var accountToEdit: null
    readonly property bool accountSetupVisible: accountSetupPane.visible
    readonly property bool mailSurfaceVisible: mailSurface.visible
    readonly property bool mailSurfaceInteractive: mailSurface.enabled
    readonly property bool composeVisible: composePane.open
    readonly property bool composeRendered: composePane.visible
    readonly property bool composeMinimized: composePane.minimized
    readonly property real composeOpacity: composePane.opacity
    readonly property real composePanelWidth: composePane.width
    readonly property real composePanelHeight: composePane.height
    readonly property bool composeReplacementQueued: composePane.transitionQueued
    readonly property bool composeSending: composePane.sending
    readonly property bool composeDiscarding: composePane.discarding
    readonly property string composeRecipientText: composePane.recipientText
    readonly property string composeSubjectText: composePane.subjectText
    readonly property string composeBodyText: composePane.editorBodyText
    readonly property bool navigationRailVisible: navigationRail.visible
    readonly property real navigationRailWidth: navigationRail.width
    readonly property real mailListLeftEdge: messageListPane.x
    readonly property bool draftsBackButtonVisible: draftsPane.backButtonVisible
    readonly property string renderedMessageHtml: messageReaderPane.renderedBodyHtml
    property bool windowClosePending: false
    readonly property bool safeToReplace: composePane.safeToReplace
    signal windowCloseReady()

    function openAccountSetup(account) {
        accountToEdit = account || null
        accountSetupOpen = true
        navigationOpen = false
    }

    function openCalendar() {
        accountSetupOpen = false
        navigationOpen = false
        mobilePage = "list"
        store.openCalendar()
    }

    function openMail() {
        navigationOpen = false
        store.openMailSurface()
    }

    function openMessagePage() {
        if (mobile) mobilePage = "reader"
    }

    function returnToList() {
        mobilePage = "list"
        navigationOpen = false
    }

    function startNewCompose() {
        if (store.view === "compose") {
            composePane.restore()
            return
        }
        store.startCompose("compose", null)
    }

    function startContextCompose(mode, message) {
        return composePane.startAnother(mode, message)
    }

    function startMailto(uri) {
        if (!composePane.acceptsMailto(uri)) return false
        cancelWindowClose()
        return composePane.startMailto(uri)
    }

    function saveCompose() {
        composePane.save(false)
    }

    function minimizeCompose() {
        composePane.minimize()
    }

    function restoreCompose() {
        composePane.restore()
    }

    function requestComposeClose() {
        composePane.requestClose()
    }

    function discardCompose() {
        composePane.discard()
    }

    function sendCompose() {
        composePane.send()
    }

    function prepareWindowClose() {
        if (windowClosePending) return
        if (!composePane.open) {
            windowCloseReady()
            return
        }
        windowClosePending = true
        composePane.requestClose()
    }

    function cancelWindowClose() {
        if (!windowClosePending) return
        windowClosePending = false
        composePane.cancelCloseRequest()
    }

    onComposeVisibleChanged: {
        if (!windowClosePending || composeVisible) return
        windowClosePending = false
        windowCloseReady()
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.canvas
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        StatusBanner {
            Layout.fillWidth: true
            kind: store.errorText !== "" ? "error" : store.offline ? "offline" : "syncing"
            message: store.errorText !== "" ? store.errorText
                : store.offline ? "Offline — reconnecting to the QuickMail service"
                : store.syncing ? "Checking for new mail…" : ""
            onDismissed: store.errorText = ""
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            RowLayout {
                id: mailSurface
                anchors.fill: parent
                spacing: 0
                enabled: !composePane.open || composePane.minimized

                NavigationPane {
                    id: navigationRail

                    visible: true
                    Layout.preferredWidth: root.navigationCollapsed ? 64
                        : root.medium ? 176 : 224
                    Layout.minimumWidth: Layout.preferredWidth
                    Layout.maximumWidth: Layout.preferredWidth
                    Layout.fillHeight: true
                    store: root.store
                    collapsed: root.navigationCollapsed
                    onMailRequested: root.openMail()
                    onComposeRequested: root.startNewCompose()
                    onDraftsRequested: store.openDrafts()
                    onCalendarRequested: root.openCalendar()
                    onAccountSetupRequested: account => root.openAccountSetup(account)
                }

                Rectangle {
                    visible: true
                    Layout.preferredWidth: 1
                    Layout.minimumWidth: 1
                    Layout.maximumWidth: 1
                    Layout.fillHeight: true
                    color: Theme.borderSoft
                }

                MessageListPane {
                    id: messageListPane
                    visible: store.view !== "calendar" && !store.draftsOpen
                        && (!root.mobile || root.mobilePage === "list")
                    Layout.preferredWidth: root.mobile ? -1 : root.medium ? 330 : 390
                    Layout.fillWidth: root.mobile
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onMenuRequested: root.navigationOpen = true
                    onMessageActivated: root.openMessagePage()
                }

                Rectangle {
                    visible: store.view !== "calendar" && !root.mobile && !store.draftsOpen
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    color: Theme.borderSoft
                }

                MessageReaderPane {
                    id: messageReaderPane
                    visible: store.view !== "calendar" && !store.draftsOpen
                        && (!root.mobile || root.mobilePage === "reader")
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onBackRequested: root.returnToList()
                    onComposeRequested: (mode, message) =>
                        root.startContextCompose(mode, message)
                }

                DraftsPane {
                    id: draftsPane

                    visible: store.view !== "calendar" && store.draftsOpen
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    persistentNavigation: navigationRail.visible
                    onBackRequested: store.closeDrafts()
                }

                CalendarPane {
                    id: calendarPane
                    visible: store.view === "calendar"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onNavigationRequested: root.navigationOpen = true
                    onBackRequested: root.openMail()
                }
            }

            ComposePane {
                id: composePane
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: root.mobile ? 8 : 16
                anchors.bottomMargin: root.mobile ? 8 : 12
                width: {
                    const available = Math.max(0, parent.width - 2 * anchors.rightMargin)
                    if (minimized) return Math.min(340, available)
                    if (root.mobile) return available
                    return Math.min(560, Math.max(420, parent.width * 0.48), available)
                }
                height: {
                    if (minimized) return headerHeight
                    const available = Math.max(headerHeight,
                        parent.height - 2 * anchors.bottomMargin)
                    return root.mobile ? available : Math.min(620, available)
                }
                open: store.view === "compose"
                store: root.store
                z: 10
                onCloseOperationFailed: root.windowClosePending = false

                Behavior on width {
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
                Behavior on height {
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: root.mobile && root.navigationOpen
                color: "#80000000"
                z: 20
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.navigationOpen = false
                }
            }

            NavigationPane {
                width: Math.min(284, parent.width * 0.84)
                height: parent.height
                x: root.navigationOpen ? 0 : -width - 8
                visible: root.mobile
                z: 21
                store: root.store
                onMailRequested: root.openMail()
                onComposeRequested: {
                    root.navigationOpen = false
                    root.startNewCompose()
                }
                onDraftsRequested: {
                    root.navigationOpen = false
                    store.openDrafts()
                }
                onCalendarRequested: root.openCalendar()
                onAccountSetupRequested: account => root.openAccountSetup(account)
                Behavior on x { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            }

            AccountSetupPane {
                id: accountSetupPane
                anchors.fill: parent
                visible: root.accountSetupOpen
                    || (root.store.accountsLoaded && root.store.accounts.length === 0)
                z: 30
                store: root.store
                account: root.accountToEdit
                onClosed: {
                    root.accountSetupOpen = false
                    root.accountToEdit = null
                }
            }
        }
    }

    Shortcut { sequence: "Ctrl+N"; onActivated: root.startNewCompose() }
    Shortcut {
        sequence: "Escape"
        enabled: store.view !== "compose"
        onActivated: {
            if (root.navigationOpen) root.navigationOpen = false
            else if (root.mobilePage === "reader") root.returnToList()
        }
    }
    Shortcut { sequence: "Alt+1"; onActivated: store.selectFolderRole("inbox") }
    Shortcut { sequence: "Alt+2"; onActivated: store.selectFolderRole("unread") }
    Shortcut { sequence: "Alt+3"; onActivated: store.selectFolderRole("starred") }
}
