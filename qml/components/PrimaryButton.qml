import QtQuick
import QtQuick.Controls
import ".."

Button {
    id: root
    property string iconName: ""
    property bool destructive: false

    implicitHeight: 40
    leftPadding: 16
    rightPadding: 16
    spacing: 8
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus

    contentItem: Row {
        spacing: 8
        anchors.centerIn: parent
        Text {
            visible: root.iconName !== ""
            text: Theme.icon(root.iconName)
            color: root.enabled
                ? (root.destructive ? Theme.dangerText : Theme.accentText)
                : Theme.textMuted
            font.family: Theme.iconFont
            font.pixelSize: 19
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.text
            textFormat: Text.PlainText
            color: root.enabled
                ? (root.destructive ? Theme.dangerText : Theme.accentText)
                : Theme.textMuted
            font.family: Theme.fontFamily
            font.pixelSize: 14
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    background: Rectangle {
        radius: Theme.radiusSmall
        color: !root.enabled ? Theme.surfaceHover
            : root.destructive ? (root.down ? Qt.darker(Theme.danger, 1.2) : Theme.danger)
            : root.down ? Qt.darker(Theme.accent, 1.2) : Theme.accent
        opacity: root.hovered && root.enabled ? 0.92 : 1
        border.width: root.visualFocus ? 2 : 0
        border.color: Theme.text
    }
}
