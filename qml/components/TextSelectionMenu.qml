import QtQuick
import QtQuick.Controls
import ".."

Menu {
    id: root

    required property var editor
    property bool editable: editor && !editor.readOnly
    readonly property bool hasSelection: editor
        && editor.selectionStart !== editor.selectionEnd
    readonly property bool hasText: editor && Number(editor.length) > 0
    readonly property int visibleActionCount: editable ? 6 : 3
    readonly property alias cutActionItem: cutItem
    readonly property alias copyActionItem: copyItem
    readonly property alias pasteActionItem: pasteItem
    readonly property alias deleteActionItem: deleteItem
    readonly property alias selectAllActionItem: selectAllItem
    readonly property alias deselectActionItem: deselectItem

    objectName: "textSelectionMenu"
    title: AgendaTranslations.tr("Text actions")

    function showAt(x, y) {
        const targetX = isFinite(Number(x)) ? Number(x) : 12
        const targetY = isFinite(Number(y)) ? Number(y) : 12
        popup(targetX, targetY)
    }

    MenuItem {
        id: cutItem
        objectName: "textActionCut"
        visible: root.editable
        text: AgendaTranslations.tr("Cut")
        enabled: root.hasSelection
        icon.name: "edit-cut"
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.editor.cut()
    }
    MenuItem {
        id: copyItem
        objectName: "textActionCopy"
        text: AgendaTranslations.tr("Copy")
        enabled: root.hasSelection
        icon.name: "edit-copy"
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.editor.copy()
    }
    MenuItem {
        id: pasteItem
        objectName: "textActionPaste"
        visible: root.editable
        text: AgendaTranslations.tr("Paste")
        enabled: root.editor && root.editor.canPaste
        icon.name: "edit-paste"
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.editor.paste()
    }
    MenuItem {
        id: deleteItem
        objectName: "textActionDelete"
        visible: root.editable
        text: AgendaTranslations.tr("Delete selection")
        enabled: root.hasSelection
        icon.name: "edit-delete"
        icon.color: enabled ? Theme.danger : Theme.textMuted
        onTriggered: root.editor.remove(root.editor.selectionStart,
            root.editor.selectionEnd)
    }
    MenuSeparator { visible: root.editable }
    MenuItem {
        id: selectAllItem
        objectName: "textActionSelectAll"
        text: AgendaTranslations.tr("Select all")
        enabled: root.hasText && (!root.hasSelection
            || root.editor.selectionStart !== 0
            || root.editor.selectionEnd !== root.editor.length)
        icon.name: "edit-select-all"
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.editor.selectAll()
    }
    MenuItem {
        id: deselectItem
        objectName: "textActionDeselect"
        text: AgendaTranslations.tr("Deselect")
        enabled: root.hasSelection
        icon.name: "edit-clear"
        icon.color: enabled ? Theme.textSecondary : Theme.textMuted
        onTriggered: root.editor.deselect()
    }
}
