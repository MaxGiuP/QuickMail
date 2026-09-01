import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

ComboBox {
    id: root

    property string iconName: ""

    implicitHeight: 40
    leftPadding: 14
    rightPadding: 42
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus

    function optionText(data, roles) {
        if (root.textRole === "") return String(data === undefined ? "" : data)
        if (data && typeof data === "object" && data[root.textRole] !== undefined)
            return String(data[root.textRole])
        if (roles && roles[root.textRole] !== undefined)
            return String(roles[root.textRole])
        return ""
    }

    contentItem: RowLayout {
        spacing: 8

        Text {
            visible: root.iconName !== ""
            text: Theme.icon(root.iconName)
            textFormat: Text.PlainText
            color: root.enabled ? Theme.textSecondary : Theme.textMuted
            font.family: Theme.iconFont
            font.pixelSize: 18
        }
        Text {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.displayText
            textFormat: Text.PlainText
            color: root.enabled ? Theme.text : Theme.textMuted
            font.family: Theme.fontFamily
            font.pixelSize: 13
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    indicator: Text {
        x: root.width - width - 14
        y: Math.round((root.height - height) / 2)
        text: Theme.icon("chevron")
        textFormat: Text.PlainText
        color: root.enabled ? Theme.textSecondary : Theme.textMuted
        font.family: Theme.iconFont
        font.pixelSize: 20
        rotation: root.popup.visible ? 90 : 0

        Behavior on rotation {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
    }

    background: Rectangle {
        radius: Theme.radiusSmall
        color: !root.enabled ? Theme.surface
            : root.down ? Theme.surfaceSelected
            : root.hovered ? Theme.surfaceHover : Theme.surfaceRaised
        border.width: root.visualFocus || root.popup.visible ? 1 : 0
        border.color: Theme.accent

        Behavior on color {
            ColorAnimation { duration: 100 }
        }
    }

    delegate: ItemDelegate {
        id: option

        required property int index
        required property var model
        required property var modelData

        width: ListView.view ? ListView.view.width : root.width
        implicitHeight: 40
        leftPadding: 12
        rightPadding: 12
        highlighted: root.highlightedIndex === index
        hoverEnabled: true

        contentItem: RowLayout {
            spacing: 8

            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: root.optionText(option.modelData, option.model)
                textFormat: Text.PlainText
                color: root.currentIndex === option.index
                    ? Theme.accentSoftText : Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                visible: root.currentIndex === option.index
                text: Theme.icon("check")
                textFormat: Text.PlainText
                color: Theme.accentSoftText
                font.family: Theme.iconFont
                font.pixelSize: 18
            }
        }

        background: Rectangle {
            radius: Theme.radiusSmall
            color: root.currentIndex === option.index ? Theme.accentSoft
                : option.down ? Theme.surfaceSelected
                : option.hovered || option.highlighted ? Theme.surfaceHover : "transparent"

            Behavior on color {
                ColorAnimation { duration: 90 }
            }
        }
    }

    popup: Popup {
        id: popup

        y: root.height + 4
        width: root.width
        height: Math.min(contentList.contentHeight + topPadding + bottomPadding, 288)
        padding: 6
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        enter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 100 }
                NumberAnimation { property: "scale"; from: 0.98; to: 1; duration: 100; easing.type: Easing.OutCubic }
            }
        }
        exit: Transition {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 80 }
        }

        background: Rectangle {
            radius: Theme.radius
            color: Theme.surfaceRaised
            border.width: 1
            border.color: Theme.borderSoft
        }

        contentItem: ListView {
            id: contentList
            clip: true
            implicitHeight: contentHeight
            spacing: 2
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            highlightMoveDuration: 80
            ScrollIndicator.vertical: ScrollIndicator {}
        }
    }
}
