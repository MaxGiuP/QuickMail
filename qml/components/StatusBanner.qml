import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    property string kind: "offline" // offline | error | syncing
    property string message: ""
    signal dismissed()

    visible: message !== ""
    implicitHeight: visible ? 40 : 0
    color: kind === "error" ? Qt.rgba(1, 0.25, 0.3, 0.14)
        : kind === "syncing" ? Qt.rgba(0.4, 0.67, 0.94, 0.12)
        : Qt.rgba(0.94, 0.74, 0.42, 0.13)
    border.width: 1
    border.color: kind === "error" ? Qt.rgba(1, 0.44, 0.47, 0.4)
        : kind === "syncing" ? Qt.rgba(0.4, 0.67, 0.94, 0.35)
        : Qt.rgba(0.94, 0.74, 0.42, 0.35)

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 8
        spacing: 10
        Text {
            text: Theme.icon(root.kind === "error" ? "error"
                : root.kind === "offline" ? "offline" : "refresh")
            color: root.kind === "error" ? Theme.danger
                : root.kind === "syncing" ? Theme.accent : Theme.warning
            font.family: Theme.iconFont
            font.pixelSize: 18
        }
        Text {
            Layout.fillWidth: true
            text: root.message
            textFormat: Text.PlainText
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        IconButton {
            visible: root.kind === "error"
            iconName: "close"
            tip: "Dismiss"
            implicitWidth: 32
            implicitHeight: 32
            onClicked: root.dismissed()
        }
    }
}
