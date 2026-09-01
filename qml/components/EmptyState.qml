import QtQuick
import QtQuick.Layouts
import ".."

Item {
    id: root
    property string iconName: "mail"
    property string title: "Nothing here"
    property string detail: ""
    property string actionText: ""
    signal action()

    ColumnLayout {
        width: Math.min(parent.width - 48, 360)
        anchors.centerIn: parent
        spacing: 10
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: Theme.icon(root.iconName)
            color: Theme.textMuted
            font.family: Theme.iconFont
            font.pixelSize: 44
        }
        Text {
            Layout.fillWidth: true
            text: root.title
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: 20
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: root.detail
            textFormat: Text.PlainText
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: 14
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }
        PrimaryButton {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 6
            visible: root.actionText !== ""
            text: root.actionText
            onClicked: root.action()
        }
    }
}
