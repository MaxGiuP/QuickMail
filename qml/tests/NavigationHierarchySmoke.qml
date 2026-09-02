import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 420
    height: 720
    property int mailRequests: 0
    property int calendarRequests: 0

    function expect(condition, message) {
        if (condition) return
        console.error("QML SMOKE TEST FAILED: navigation hierarchy: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
    }

    function named(object, name) {
        const result = []
        descendantsWithName(object, name, result)
        return result
    }

    function iconCenter(navigationPane, name) {
        const icons = named(navigationPane, name)
        expect(icons.length > 0, "could not inspect " + name)
        if (icons.length === 0) return -1
        const icon = icons[0]
        return icon.mapToItem(navigationPane, icon.width / 2, icon.height / 2).x
    }

    function descendantTexts(object, result) {
        if (!object) return
        if (typeof object.text === "string") result.push(object.text)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantTexts(children[index], result)
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

        width: 340
        height: parent.height
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

    NavigationPane {
        id: collapsedNavigation

        x: 350
        width: 64
        height: parent.height
        collapsed: true
        store: fakeStore
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
            window.expect(navigation.parentLabelHoverDelay >= 400,
                "top-level labels no longer use an intentional hover delay")

            const mailButtons = window.named(navigation, "mailParentButton")
            const calendarButtons = window.named(navigation, "calendarParentButton")
            window.expect(mailButtons.length === 1 && calendarButtons.length === 1,
                "top-level navigation buttons were not exposed for inspection")
            const mailButtonTexts = []
            const calendarButtonTexts = []
            if (mailButtons.length > 0)
                window.descendantTexts(mailButtons[0].contentItem, mailButtonTexts)
            if (calendarButtons.length > 0)
                window.descendantTexts(calendarButtons[0].contentItem, calendarButtonTexts)
            window.expect(mailButtonTexts.indexOf("Mail") < 0
                    && calendarButtonTexts.indexOf("Calendar") < 0,
                "top-level labels remained inline instead of icon-only")

            const expandedDraftsCenter = window.iconCenter(
                navigation, "savedDraftsIcon")
            const expandedFolderCenter = window.iconCenter(
                navigation, "folderIcon")
            window.expect(Math.abs(expandedDraftsCenter - expandedFolderCenter) < 0.5,
                "Saved drafts did not align with expanded mailbox rows")

            const collapsedDraftsCenter = window.iconCenter(
                collapsedNavigation, "savedDraftsIcon")
            const collapsedFolderCenter = window.iconCenter(
                collapsedNavigation, "folderIcon")
            window.expect(Math.abs(collapsedDraftsCenter - collapsedFolderCenter) < 0.5,
                "Saved drafts did not align with compressed mailbox rows")

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
