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
                anchors.fill: parent
                spacing: 0
                visible: store.view !== "compose"

                NavigationPane {
                    visible: !root.mobile
                    Layout.preferredWidth: root.medium ? 64 : 224
                    Layout.fillHeight: true
                    store: root.store
                    collapsed: root.medium
                    onComposeRequested: store.startCompose("compose", null)
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
                    visible: !store.draftsOpen && (!root.mobile || root.mobilePage === "reader")
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    store: root.store
                    mobile: root.mobile
                    onBackRequested: root.returnToList()
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
                anchors.fill: parent
                visible: store.view === "compose"
                store: root.store
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
                    store.startCompose("compose", null)
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

    Shortcut { sequence: "Ctrl+N"; onActivated: store.startCompose("compose", null) }
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
