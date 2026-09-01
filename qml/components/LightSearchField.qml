import QtQuick
import QtQuick.Controls
import ".."

TextField {
    id: root
    signal submitted(string query)

    placeholderText: "Search mail"
    placeholderTextColor: Theme.textMuted
    color: Theme.text
    selectionColor: Theme.accentSoft
    selectedTextColor: Theme.text
    font.family: Theme.fontFamily
    font.pixelSize: 14
    leftPadding: 40
    rightPadding: text.length > 0 ? 38 : 12
    implicitHeight: 42
    selectByMouse: true

    background: Rectangle {
        color: Theme.surfaceRaised
        radius: Theme.radius
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accent
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: Theme.icon("search")
            color: Theme.textMuted
            font.family: Theme.iconFont
            font.pixelSize: 20
        }
        IconButton {
            visible: root.text.length > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 36
            implicitHeight: 36
            iconName: "close"
            tip: "Clear search"
            onClicked: {
                root.clear()
                root.submitted("")
            }
        }
    }
    Keys.onReturnPressed: submitted(text)
    Keys.onEscapePressed: {
        clear()
        submitted("")
        focus = false
    }
}
