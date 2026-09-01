pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf
import ".."

Rectangle {
    id: root

    property url source
    readonly property int pageCount: document.pageCount
    readonly property int currentPage: pdfView.currentPage
    readonly property real renderScale: pdfView.renderScale
    readonly property bool ready: document.status === PdfDocument.Ready
    readonly property bool failed: document.status === PdfDocument.Error
    readonly property string errorText: root.pdfErrorText(document.error)
    readonly property bool compactToolbar: width < 600
    property bool passwordRequested: false
    property string scaleMode: "width" // width | page | manual

    color: Theme.canvas

    function pdfErrorText(error) {
        switch (error) {
        case PdfDocument.FileNotFound:
            return "The PDF file is no longer available."
        case PdfDocument.InvalidFileFormat:
            return "This file is not a valid PDF."
        case PdfDocument.IncorrectPassword:
            return "The PDF password is incorrect."
        case PdfDocument.UnsupportedSecurityScheme:
            return "This PDF uses unsupported security settings."
        case PdfDocument.DataNotYetAvailable:
            return "The PDF data is not available yet."
        default:
            return "QuickMail could not render this PDF."
        }
    }

    function zoomIn() {
        scaleMode = "manual"
        pdfView.renderScale = Math.min(10, pdfView.renderScale * Math.sqrt(2))
    }

    function zoomOut() {
        scaleMode = "manual"
        pdfView.renderScale = Math.max(0.1, pdfView.renderScale / Math.sqrt(2))
    }

    function fitWidth() {
        scaleMode = "width"
        if (ready && pdfView.width > 0 && pdfView.height > 0)
            pdfView.scaleToWidth(Math.max(1, pdfView.width - 20), pdfView.height)
    }

    function fitPage() {
        scaleMode = "page"
        if (ready && pdfView.width > 0 && pdfView.height > 0)
            pdfView.scaleToPage(Math.max(1, pdfView.width - 20),
                Math.max(1, pdfView.height - 20))
    }

    function resetScale() {
        scaleMode = "manual"
        pdfView.resetScale()
    }

    function rotateClockwise() {
        pdfView.pageRotation += 90
        if (scaleMode !== "manual") refitTimer.restart()
    }

    function previousPage() {
        if (pdfView.currentPage > 0) pdfView.goToPage(pdfView.currentPage - 1)
    }

    function nextPage() {
        if (pdfView.currentPage + 1 < document.pageCount)
            pdfView.goToPage(pdfView.currentPage + 1)
    }

    function submitPassword() {
        if (passwordField.text === "") return
        document.password = passwordField.text
        passwordField.clear()
        passwordRequested = false
    }

    onSourceChanged: {
        passwordRequested = false
        scaleMode = "width"
        passwordField.clear()
    }
    onWidthChanged: if (ready && scaleMode !== "manual") refitTimer.restart()
    onHeightChanged: if (ready && scaleMode === "page") refitTimer.restart()

    Timer {
        id: refitTimer
        interval: 50
        repeat: false
        onTriggered: {
            if (root.scaleMode === "page") root.fitPage()
            else if (root.scaleMode === "width") root.fitWidth()
        }
    }

    PdfDocument {
        id: document
        source: root.source
        onPasswordRequired: {
            root.passwordRequested = true
            Qt.callLater(function() { passwordField.forceActiveFocus() })
        }
        onStatusChanged: status => {
            if (status === PdfDocument.Ready) {
                root.passwordRequested = false
                Qt.callLater(root.fitWidth)
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.compactToolbar ? 88 : 48
            color: Theme.surfaceRaised
            border.width: 1
            border.color: Theme.borderSoft

            GridLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 4
                anchors.bottomMargin: 4
                columns: root.compactToolbar ? 1 : 2
                rows: root.compactToolbar ? 2 : 1
                columnSpacing: 8
                rowSpacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    IconButton {
                        objectName: "pdfPreviousPageButton"
                        iconName: "previous"
                        tip: "Previous page (Page Up)"
                        enabled: root.ready && pdfView.currentPage > 0
                        onClicked: root.previousPage()
                    }
                    Text {
                        Layout.preferredWidth: 78
                        text: root.ready && document.pageCount > 0
                            ? (pdfView.currentPage + 1) + " / " + document.pageCount : "— / —"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                    }
                    IconButton {
                        objectName: "pdfNextPageButton"
                        iconName: "next"
                        tip: "Next page (Page Down)"
                        enabled: root.ready && pdfView.currentPage + 1 < document.pageCount
                        onClicked: root.nextPage()
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Item { Layout.fillWidth: true }
                    IconButton {
                        objectName: "pdfZoomOutButton"
                        iconName: "zoomOut"
                        tip: "Zoom out (Ctrl+-)"
                        enabled: root.ready && pdfView.renderScale > 0.1
                        onClicked: root.zoomOut()
                    }
                    IconButton {
                        objectName: "pdfZoomInButton"
                        iconName: "zoomIn"
                        tip: "Zoom in (Ctrl++)"
                        enabled: root.ready && pdfView.renderScale < 10
                        onClicked: root.zoomIn()
                    }
                    IconButton {
                        iconName: "fitWidth"
                        tip: "Fit width (Ctrl+1)"
                        enabled: root.ready
                        onClicked: root.fitWidth()
                    }
                    IconButton {
                        iconName: "fitPage"
                        tip: "Fit page (Ctrl+2)"
                        enabled: root.ready
                        onClicked: root.fitPage()
                    }
                    IconButton {
                        iconName: "rotate"
                        tip: "Rotate clockwise (Ctrl+R)"
                        enabled: root.ready
                        onClicked: root.rotateClockwise()
                    }
                    Text {
                        Layout.preferredWidth: 44
                        visible: root.ready
                        text: Math.round(pdfView.renderScale * 100) + "%"
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.surface
            border.width: 1
            border.color: Theme.borderSoft

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 4

                TextField {
                    id: searchField
                    objectName: "pdfSearchField"
                    Layout.fillWidth: true
                    placeholderText: "Find in PDF (Ctrl+F)"
                    enabled: root.ready
                    selectByMouse: true
                    font.family: Theme.fontFamily
                    onTextChanged: pdfView.searchString = text
                }
                IconButton {
                    iconName: "previous"
                    tip: "Previous result (Shift+Enter)"
                    enabled: pdfView.searchModel.count > 0
                    onClicked: pdfView.searchBack()
                }
                IconButton {
                    iconName: "next"
                    tip: "Next result (Enter)"
                    enabled: pdfView.searchModel.count > 0
                    onClicked: pdfView.searchForward()
                }
                Text {
                    Layout.preferredWidth: 54
                    text: pdfView.searchModel.count > 0
                        ? (pdfView.searchModel.currentResult + 1) + " / "
                            + pdfView.searchModel.count : "0 / 0"
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignRight
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            PdfScrollablePageView {
                id: pdfView
                objectName: "pdfPageView"
                anchors.fill: parent
                document: document
            }

            BusyIndicator {
                anchors.centerIn: parent
                running: document.status === PdfDocument.Loading
                visible: running
            }

            EmptyState {
                anchors.fill: parent
                visible: root.failed && !root.passwordRequested
                iconName: "document"
                title: "PDF preview unavailable"
                detail: root.errorText
            }

            Rectangle {
                anchors.centerIn: parent
                width: Math.min(parent.width - 32, 420)
                height: passwordColumn.implicitHeight + 32
                visible: root.passwordRequested
                radius: Theme.radius
                color: Theme.surfaceRaised
                border.width: 1
                border.color: Theme.border

                ColumnLayout {
                    id: passwordColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 16
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        text: "This PDF is password protected"
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                    }
                    TextField {
                        id: passwordField
                        Layout.fillWidth: true
                        placeholderText: "PDF password"
                        echoMode: TextInput.Password
                        onAccepted: root.submitPassword()
                    }
                    PrimaryButton {
                        Layout.alignment: Qt.AlignRight
                        text: "Unlock"
                        enabled: passwordField.text !== ""
                        onClicked: root.submitPassword()
                    }
                }
            }
        }
    }

    Shortcut {
        sequences: [StandardKey.ZoomIn]
        enabled: root.visible && root.ready
        onActivated: root.zoomIn()
    }
    Shortcut {
        sequences: [StandardKey.ZoomOut]
        enabled: root.visible && root.ready
        onActivated: root.zoomOut()
    }
    Shortcut {
        sequence: "Ctrl+0"
        enabled: root.visible && root.ready
        onActivated: root.resetScale()
    }
    Shortcut {
        sequence: "Ctrl+1"
        enabled: root.visible && root.ready
        onActivated: root.fitWidth()
    }
    Shortcut {
        sequence: "Ctrl+2"
        enabled: root.visible && root.ready
        onActivated: root.fitPage()
    }
    Shortcut {
        sequence: "Ctrl+R"
        enabled: root.visible && root.ready
        onActivated: root.rotateClockwise()
    }
    Shortcut {
        sequences: [StandardKey.Find]
        enabled: root.visible && root.ready
        onActivated: {
            searchField.forceActiveFocus()
            searchField.selectAll()
        }
    }
    Shortcut {
        sequence: "PageUp"
        enabled: root.visible && root.ready
        onActivated: root.previousPage()
    }
    Shortcut {
        sequence: "PageDown"
        enabled: root.visible && root.ready
        onActivated: root.nextPage()
    }
}
