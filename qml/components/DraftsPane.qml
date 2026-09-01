pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root
    required property var store
    property bool mobile: false
    property bool persistentNavigation: false
    property var pendingDelete: null
    readonly property bool backButtonVisible: backButton.visible
    signal backRequested()

    color: Theme.canvas

    function messageFor(record) {
        return record && record.message || ({})
    }

    function recipients(record) {
        const values = messageFor(record).to || []
        if (!Array.isArray(values)) return String(values || "")
        return values.map(function(value) {
            return String(value && (value.address || value.name) || "")
        }).filter(function(value) { return value !== "" }).join(", ")
    }

    function updatedText(record) {
        const value = record && (record.updatedAt || record.updated_at) || ""
        if (value === "") return ""
        const date = new Date(value)
        if (isNaN(date.getTime())) return String(value)
        return Qt.formatDateTime(date, "d MMM yyyy, HH:mm")
    }

    function requestDelete(record) {
        pendingDelete = record
        deleteDialog.open()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            Layout.leftMargin: Theme.space4
            Layout.rightMargin: Theme.space4
            spacing: 8
            IconButton {
                id: backButton

                visible: root.mobile && !root.persistentNavigation
                iconName: "back"
                tip: "Back to mail"
                onClicked: root.backRequested()
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    text: "Saved drafts"
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 21
                    font.weight: Font.DemiBold
                }
                Text {
                    visible: root.store.drafts.length > 0
                    text: root.store.drafts.length === 1 ? "1 draft"
                        : root.store.drafts.length + " drafts"
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }
            }
            IconButton {
                iconName: "refresh"
                tip: "Refresh saved drafts"
                enabled: !root.store.draftsLoading
                onClicked: root.store.loadDrafts()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            EmptyState {
                anchors.fill: parent
                visible: !root.store.draftsLoading && root.store.drafts.length === 0
                iconName: "drafts"
                title: "No saved drafts"
                detail: "Drafts you save while composing will appear here."
            }

            BusyIndicator {
                anchors.centerIn: parent
                visible: root.store.draftsLoading && root.store.drafts.length === 0
                running: visible
            }

            ListView {
                id: draftList
                anchors.fill: parent
                anchors.margins: Theme.space3
                visible: root.store.drafts.length > 0
                model: root.store.drafts
                spacing: 6
                clip: true
                focus: true
                currentIndex: -1
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                onCountChanged: {
                    if (count === 0) currentIndex = -1
                    else if (currentIndex < 0 || currentIndex >= count) currentIndex = 0
                }

                delegate: Rectangle {
                    id: draftRow
                    required property var modelData
                    required property int index
                    width: draftList.width - (draftList.ScrollBar.vertical.visible ? 10 : 0)
                    height: 88
                    radius: Theme.radiusSmall
                    color: draftList.currentIndex === index ? Theme.surfaceSelected
                        : rowMouse.containsMouse ? Theme.surfaceHover : Theme.surface
                    readonly property var message: root.messageFor(modelData)

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space3
                        anchors.rightMargin: Theme.space3
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 10

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                Layout.fillWidth: true
                                text: draftRow.message.subject || "(No subject)"
                                textFormat: Text.PlainText
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.recipients(draftRow.modelData) || "No recipients yet"
                                textFormat: Text.PlainText
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            Text {
                                text: root.updatedText(draftRow.modelData)
                                textFormat: Text.PlainText
                                color: Theme.textMuted
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                            }
                        }

                        Button {
                            text: "Open"
                            flat: true
                            onClicked: root.store.openDraft(draftRow.modelData)
                        }
                        IconButton {
                            iconName: "trash"
                            tip: "Delete draft"
                            destructive: true
                            onClicked: root.requestDelete(draftRow.modelData)
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        anchors.rightMargin: 116
                        hoverEnabled: true
                        onClicked: {
                            draftList.currentIndex = draftRow.index
                            root.store.openDraft(draftRow.modelData)
                        }
                    }
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
                        currentIndex = Math.min(count - 1, currentIndex + 1)
                        positionViewAtIndex(currentIndex, ListView.Contain)
                        event.accepted = true
                    } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
                        currentIndex = Math.max(0, currentIndex - 1)
                        positionViewAtIndex(currentIndex, ListView.Contain)
                        event.accepted = true
                    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && currentIndex >= 0) {
                        root.store.openDraft(root.store.drafts[currentIndex])
                        event.accepted = true
                    } else if (event.key === Qt.Key_Delete && currentIndex >= 0) {
                        root.requestDelete(root.store.drafts[currentIndex])
                        event.accepted = true
                    }
                }
            }
        }
    }

    Dialog {
        id: deleteDialog
        parent: root
        modal: true
        title: "Delete this draft?"
        standardButtons: Dialog.Yes | Dialog.Cancel
        width: Math.min(420, Math.max(280, root.width - 40))
        height: Math.min(190, Math.max(150, root.height - 40))
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        onAccepted: {
            const draft = root.pendingDelete
            root.pendingDelete = null
            root.store.deleteDraft(draft, function(result, error) {
                if (error)
                    root.store.errorText = error.message || "Draft could not be deleted"
            })
        }
        onRejected: root.pendingDelete = null
        contentItem: Text {
            text: "This removes the saved draft from QuickMail."
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
    }
}
