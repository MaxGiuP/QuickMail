import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 340
    height: 720
    property int mailRequests: 0
    property int calendarRequests: 0

    function expect(condition, message) {
        if (condition) return
        console.error("QML SMOKE TEST FAILED: navigation hierarchy: " + message)
        Qt.exit(1)
    }

    QtObject {
        id: fakeStore

        property string view: "mail"
        property bool draftsOpen: false
        property string activeFolderId: "inbox"
        property string activeAccountId: "account-a"
        property var drafts: [{ draftId: "draft-a" }]
        property var folders: [{ id: "inbox", name: "Inbox", unread: 2 }]
        property var accounts: [{
            id: "account-a", displayName: "Alex", address: "alex@example.com"
        }]
        property var events: [{ id: "event-a" }]
        property var tasks: [{ id: "task-a", done: false }]

        function selectFolder(folderId) { activeFolderId = String(folderId) }
        function selectAccount(accountId) { activeAccountId = String(accountId) }
    }

    NavigationPane {
        id: navigation

        anchors.fill: parent
        store: fakeStore
        onMailRequested: {
            ++window.mailRequests
            fakeStore.view = "mail"
        }
        onCalendarRequested: {
            ++window.calendarRequests
            fakeStore.view = "calendar"
        }
    }

    Timer {
        interval: 80
        running: true
        repeat: false
        onTriggered: {
            window.expect(navigation.mailParentSelected
                    && !navigation.calendarParentSelected,
                "Mail was not the selected top-level destination")
            window.expect(navigation.mailNavigationVisible,
                "Mail controls were not nested beneath Mail")

            navigation.selectCalendarParent()
            window.expect(window.calendarRequests === 1
                    && navigation.calendarParentSelected,
                "Calendar parent selection did not switch destinations")
            window.expect(!navigation.mailNavigationVisible,
                "compose, drafts, or mailboxes remained visible in Calendar")

            navigation.selectMailParent()
            window.expect(window.mailRequests === 1
                    && navigation.mailParentSelected
                    && navigation.mailNavigationVisible,
                "Mail parent selection did not restore its child controls")

            fakeStore.view = "compose"
            window.expect(navigation.mailParentSelected,
                "the composer was detached from its Mail parent")
            Qt.exit(0)
        }
    }
}
