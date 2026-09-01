import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"

Item {
    id: root
    required property var store

    readonly property bool mobile: width < 720
    readonly property bool medium: width >= 720 && width < 1080
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
    readonly property string renderedMessageHtml: messageReaderPane.renderedBodyHtml

    function openAccountSetup(account) {
        accountToEdit = account || null
        accountSetupOpen = true
        navigationOpen = false
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
        composePane.startAnother(mode, message)
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
                    visible: !root.mobile
                    Layout.preferredWidth: root.medium ? 64 : 224
                    Layout.fillHeight: true
                    store: root.store
                    collapsed: root.medium
                    onComposeRequested: root.startNewCompose()
                    onDraftsRequested: store.openDrafts()
                    onAccountSetupRequested: account => root.openAccountSetup(account)
                }

                Rectangle {
                    visible: !root.mobile
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    color: Theme.borderSoft
                }

                MessageListPane {
                    id: messageListPane
                    visible: !store.draftsOpen && (!root.mobile || root.mobilePage === "list")
                    Layout.preferredWidth: root.mobile ? -1 : root.medium ? 330 : 390
                    Layout.fillWidth: root.mobile
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onMenuRequested: root.navigationOpen = true
                    onMessageActivated: root.openMessagePage()
                }

                Rectangle {
                    visible: !root.mobile && !store.draftsOpen
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    color: Theme.borderSoft
                }

                MessageReaderPane {
                    id: messageReaderPane
                    visible: !store.draftsOpen && (!root.mobile || root.mobilePage === "reader")
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onBackRequested: root.returnToList()
                    onComposeRequested: (mode, message) =>
                        root.startContextCompose(mode, message)
                }

                DraftsPane {
                    visible: store.draftsOpen
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onBackRequested: store.closeDrafts()
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
                onComposeRequested: {
                    root.navigationOpen = false
                    root.startNewCompose()
                }
                onDraftsRequested: {
                    root.navigationOpen = false
                    store.openDrafts()
                }
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
