import QtQuick
import QtQuick.Controls
import ".."

ToolButton {
    id: root

    property string label: ""
    property string tip: ""
    property bool labelBold: false
    property bool labelItalic: false
    property bool labelUnderline: false
    property bool labelStrikeout: false
    property color swatchColor: "transparent"

    implicitWidth: 36
    implicitHeight: 36
    hoverEnabled: true
    focusPolicy: Qt.NoFocus
    Accessible.name: tip

    contentItem: Item {
        Text {
            anchors.centerIn: parent
            text: root.label
            textFormat: Text.PlainText
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: root.label.length > 1 ? 12 : 16
            font.weight: root.labelBold ? Font.Bold : Font.Normal
            font.italic: root.labelItalic
            font.underline: root.labelUnderline
            font.strikeout: root.labelStrikeout
        }

        Rectangle {
            visible: root.swatchColor.a > 0
            width: 16
            height: 3
            radius: 2
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 3
            color: root.swatchColor
        }
    }

    background: Rectangle {
        radius: Theme.radiusSmall
        color: root.down ? Theme.surfaceSelected
            : root.hovered ? Theme.surfaceHover : "transparent"
    }

    ToolTip.visible: hovered && tip !== ""
    ToolTip.text: tip
    ToolTip.delay: 450
}
