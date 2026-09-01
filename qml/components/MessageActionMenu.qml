import QtQuick
import QtQuick.Controls
import ".."

Menu {
    id: root

    required property var message
    property bool includeOpen: false
    readonly property int actionIconSize: 18
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
        icon.name: "document-open"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.openRequested()
    }
    MenuItem {
        id: replyItem
        objectName: "messageActionReply"
        text: AgendaTranslations.tr("Reply")
        icon.name: "mail-reply-sender"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.composeRequested("reply")
    }
    MenuItem {
        id: replyAllItem
        objectName: "messageActionReplyAll"
        text: AgendaTranslations.tr("Reply all")
        icon.name: "mail-reply-all"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.composeRequested("reply_all")
    }
    MenuItem {
        id: forwardItem
        objectName: "messageActionForward"
        text: AgendaTranslations.tr("Forward")
        icon.name: "mail-forward"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.composeRequested("forward")
    }
    MenuSeparator {}
    MenuItem {
        id: readItem
        objectName: "messageActionRead"
        text: root.unread ? AgendaTranslations.tr("Mark as read")
            : AgendaTranslations.tr("Mark as unread")
        icon.name: root.unread ? "mail-mark-read" : "mail-mark-unread"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.readRequested(root.unread)
    }
    MenuItem {
        id: starItem
        objectName: "messageActionStar"
        text: root.starred ? AgendaTranslations.tr("Unstar")
            : AgendaTranslations.tr("Star")
        icon.name: root.starred ? "non-starred" : "starred"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: !enabled ? Theme.textMuted
            : root.starred ? Theme.textSecondary : Theme.accent
        onTriggered: root.starRequested()
    }
    MenuSeparator {}
    MenuItem {
        id: archiveItem
        objectName: "messageActionArchive"
        text: AgendaTranslations.tr("Archive")
        icon.name: "archive"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.archiveRequested()
    }
    MenuItem {
        id: trashItem
        objectName: "messageActionTrash"
        text: AgendaTranslations.tr("Move to trash")
        icon.name: "user-trash"
        icon.width: root.actionIconSize
        icon.height: root.actionIconSize
        icon.color: enabled ? Theme.danger : Theme.textMuted
        onTriggered: root.trashRequested()
    }
}
