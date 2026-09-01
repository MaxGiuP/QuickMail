import QtQuick
import QtQuick.Controls
import ".."

ToolButton {
    id: root
    property string iconName: "more"
    property string tip: ""
    property bool emphasized: false
    property bool destructive: false
    property bool spinning: false
    readonly property real iconRotation: iconContent.rotation

    implicitWidth: 40
    implicitHeight: 40
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus

    contentItem: Text {
        id: iconContent
        text: Theme.icon(root.iconName)
        color: root.destructive ? Theme.danger
            : root.emphasized ? Theme.accent : Theme.textSecondary
        font.family: Theme.iconFont
        font.pixelSize: 21
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        transformOrigin: Item.Center
    }

    NumberAnimation {
        id: spinAnimation
        target: iconContent
        property: "rotation"
        running: root.spinning
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        onStopped: if (!root.spinning) iconContent.rotation = 0
    }

    onSpinningChanged: if (!spinning) iconContent.rotation = 0

    background: Rectangle {
        radius: Theme.radiusSmall
        color: root.down ? Theme.surfaceSelected
            : root.hovered || root.visualFocus ? Theme.surfaceHover : "transparent"
        border.width: root.visualFocus ? 1 : 0
        border.color: Theme.accent
    }

    ToolTip.visible: hovered && tip !== ""
    ToolTip.text: tip
    ToolTip.delay: 500
}
