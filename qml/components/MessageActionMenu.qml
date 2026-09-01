import QtQuick
import QtQuick.Controls
import ".."

Menu {
    id: root

    required property var message
    property bool includeOpen: false
    readonly property bool unread: message
        && (message.unread === true || message.is_read === false
            || message.read === false)
    readonly property bool starred: message
        && (message.starred === true || message.is_starred === true)
    readonly property int visibleActionCount: 7 + (includeOpen ? 1 : 0)
    readonly property alias openActionItem: openItem
    readonly property alias replyActionItem: replyItem
    readonly property alias replyAllActionItem: replyAllItem
    readonly property alias forwardActionItem: forwardItem
    readonly property alias readActionItem: readItem
    readonly property alias starActionItem: starItem
    readonly property alias archiveActionItem: archiveItem
    readonly property alias trashActionItem: trashItem

    signal openRequested()
    signal composeRequested(string mode)
    signal readRequested(bool read)
    signal starRequested()
    signal archiveRequested()
    signal trashRequested()

    objectName: "messageActionMenu"
    title: AgendaTranslations.tr("Message actions")

    function showAt(x, y) {
        const targetX = isFinite(Number(x)) ? Number(x) : 12
        const targetY = isFinite(Number(y)) ? Number(y) : 12
        popup(targetX, targetY)
    }

    MenuItem {
        id: openItem
        objectName: "messageActionOpen"
        visible: root.includeOpen
        text: AgendaTranslations.tr("Open")
        onTriggered: root.openRequested()
    }
    MenuItem {
        id: replyItem
        objectName: "messageActionReply"
        text: AgendaTranslations.tr("Reply")
        onTriggered: root.composeRequested("reply")
    }
    MenuItem {
        id: replyAllItem
        objectName: "messageActionReplyAll"
        text: AgendaTranslations.tr("Reply all")
        onTriggered: root.composeRequested("reply_all")
    }
    MenuItem {
        id: forwardItem
        objectName: "messageActionForward"
        text: AgendaTranslations.tr("Forward")
        onTriggered: root.composeRequested("forward")
    }
    MenuSeparator {}
    MenuItem {
        id: readItem
        objectName: "messageActionRead"
        text: root.unread ? AgendaTranslations.tr("Mark as read")
            : AgendaTranslations.tr("Mark as unread")
        onTriggered: root.readRequested(root.unread)
    }
    MenuItem {
        id: starItem
        objectName: "messageActionStar"
        text: root.starred ? AgendaTranslations.tr("Unstar")
            : AgendaTranslations.tr("Star")
        onTriggered: root.starRequested()
    }
    MenuSeparator {}
    MenuItem {
        id: archiveItem
        objectName: "messageActionArchive"
        text: AgendaTranslations.tr("Archive")
        onTriggered: root.archiveRequested()
    }
    MenuItem {
        id: trashItem
        objectName: "messageActionTrash"
        text: AgendaTranslations.tr("Move to trash")
        onTriggered: root.trashRequested()
    }
}
