import QtQuick

Item {
    id: root

    required property var editor
    property bool editable: editor && !editor.readOnly
    readonly property alias contextHandler: contextHandler
    readonly property alias menu: selectionMenu
    readonly property bool menuVisible: selectionMenu.visible
    readonly property int actionCount: selectionMenu.visibleActionCount

    function showAt(x, y) {
        selectionMenu.showAt(x, y)
    }

    TapHandler {
        id: contextHandler
        objectName: "textContextHandler"
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: eventPoint => root.showAt(
            eventPoint.position.x, eventPoint.position.y)
    }

    TextSelectionMenu {
        id: selectionMenu
        editor: root.editor
        editable: root.editable
    }
}
