import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    objectName: "statusBanner"
    property string kind: "offline" // offline | error | syncing
    property string message: ""
    readonly property bool shown: message !== ""
    signal dismissed()

    visible: shown || opacity > 0.01
    enabled: shown
    clip: true
    opacity: shown ? 1 : 0
    implicitHeight: shown ? 40 : 0
    color: kind === "error" ? Qt.rgba(1, 0.25, 0.3, 0.14)
        : kind === "syncing" ? Theme.surfaceRaised
        : Qt.rgba(0.94, 0.74, 0.42, 0.13)
    border.width: 1
    border.color: kind === "error" ? Qt.rgba(1, 0.44, 0.47, 0.4)
        : kind === "syncing" ? Theme.borderSoft
        : Qt.rgba(0.94, 0.74, 0.42, 0.35)

    Behavior on opacity {
        enabled: Theme.animationsEnabled
        NumberAnimation { duration: Theme.motionFast }
    }
    Behavior on implicitHeight {
        enabled: Theme.animationsEnabled
        NumberAnimation {
            duration: Theme.motionMedium
            easing.type: Easing.OutCubic
        }
    }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 8
        spacing: 10
        Text {
            objectName: "statusBannerIcon"
            text: Theme.icon(root.kind === "error" ? "error"
                : root.kind === "offline" ? "offline" : "refresh")
            color: root.kind === "error" ? Theme.danger
                : root.kind === "syncing" ? Theme.accent : Theme.warning
            font.family: Theme.iconFont
            font.pixelSize: 18
        }
        Text {
            objectName: "statusBannerMessage"
            Layout.fillWidth: true
            text: root.message
            textFormat: Text.PlainText
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        IconButton {
            objectName: "statusBannerDismissButton"
            visible: root.kind === "error"
            iconName: "close"
            tip: AgendaTranslations.tr("Close")
            implicitWidth: 32
            implicitHeight: 32
            onClicked: root.dismissed()
        }
    }
}
