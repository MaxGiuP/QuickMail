import QtQuick
import QtQuick.Controls

Control {
    id: root
    property int count: 0
    property bool offline: false
    signal activated()

    implicitWidth: 38
    implicitHeight: 34
    hoverEnabled: true

    contentItem: Item {
        Text {
            anchors.centerIn: parent
            text: Theme.icon(root.offline ? "offline" : "mail")
            color: root.hovered ? Theme.text : Theme.textSecondary
            font.family: Theme.iconFont
            font.pixelSize: 21
        }
        Rectangle {
            visible: root.count > 0
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: -2
            anchors.topMargin: -2
            implicitWidth: Math.max(17, badgeText.implicitWidth + 8)
            implicitHeight: 17
            radius: 9
            color: root.offline ? Theme.warning : Theme.accent
            Text {
                id: badgeText
                anchors.centerIn: parent
                text: root.count > 99 ? "99+" : String(root.count)
                color: Theme.canvas
                font.family: Theme.fontFamily
                font.pixelSize: 9
                font.weight: Font.Bold
            }
        }
        MouseArea { anchors.fill: parent; onClicked: root.activated() }
    }
    background: Rectangle {
        radius: Theme.radiusSmall
        color: root.hovered ? Theme.surfaceHover : "transparent"
    }
}
