pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Dialog {
    id: root

    required property var destinations
    property string entryKind: "event" // event | task
    property date selectedDate: new Date()
    property bool submitting: false
    property string errorText: ""
    readonly property bool selectedTaskDateOnly: entryKind === "task"
        && root.destinationUsesDateOnlyTasks(root.selectedDestination())

    signal payloadReady(string kind, var payload)

    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 0
    width: parent ? Math.min(560, Math.max(300, parent.width - 32)) : 520
    height: parent ? Math.min(650, Math.max(470, parent.height - 32)) : 620
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0

    function twoDigits(value) {
        return value < 10 ? "0" + value : String(value)
    }

    function dateText(value) {
        const date = value instanceof Date ? value : new Date(value)
        if (isNaN(date.getTime())) return ""
        return date.getFullYear() + "-" + twoDigits(date.getMonth() + 1)
            + "-" + twoDigits(date.getDate())
    }

    function timeText(value) {
        const date = value instanceof Date ? value : new Date(value)
        if (isNaN(date.getTime())) return "09:00"
        return twoDigits(date.getHours()) + ":" + twoDigits(date.getMinutes())
    }

    function parseDate(value) {
        const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || "").trim())
        if (!match) return null
        const year = Number(match[1])
        const month = Number(match[2])
        const day = Number(match[3])
        const date = new Date(year, month - 1, day)
        if (date.getFullYear() !== year || date.getMonth() !== month - 1
                || date.getDate() !== day) return null
        return date
    }

    function parseDateTime(dateValue, timeValue) {
        const date = parseDate(dateValue)
        const match = /^(\d{1,2}):(\d{2})$/.exec(String(timeValue || "").trim())
        if (!date || !match) return null
        const hour = Number(match[1])
        const minute = Number(match[2])
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null
        date.setHours(hour, minute, 0, 0)
        return date
    }

    function utcMidnight(value) {
        if (!value) return null
        return new Date(Date.UTC(value.getFullYear(), value.getMonth(), value.getDate()))
    }

    function destinationUsesDateOnlyTasks(destination) {
        const provider = String(destination && destination.provider || "")
            .trim().toLowerCase()
        return provider === "gmail" || provider === "google"
            || provider === "google_tasks" || provider.indexOf("gmail") >= 0
            || provider.indexOf("google") >= 0
    }

    function taskDueValue(dateValue, timeValue, destination) {
        if (destinationUsesDateOnlyTasks(destination))
            return utcMidnight(parseDate(dateValue))
        return parseDateTime(dateValue, timeValue)
    }

    function selectedDestination() {
        const list = Array.isArray(destinations) ? destinations : []
        if (destinationBox.currentIndex < 0 || destinationBox.currentIndex >= list.length)
            return { accountId: "", provider: "local", label: AgendaTranslations.tr("QuickMail · Local"),
                calendarName: AgendaTranslations.tr("QuickMail") }
        return list[destinationBox.currentIndex]
    }

    function resetFields(kind, dateValue) {
        entryKind = kind === "task" ? "task" : "event"
        const candidate = dateValue instanceof Date ? dateValue : new Date(dateValue)
        selectedDate = isNaN(candidate.getTime()) ? new Date() : candidate
        const start = new Date(selectedDate.getFullYear(), selectedDate.getMonth(),
            selectedDate.getDate(), 9, 0, 0, 0)
        const end = new Date(start.getTime() + 60 * 60 * 1000)
        titleField.text = ""
        descriptionField.text = ""
        startDateField.text = dateText(start)
        startTimeField.text = timeText(start)
        endDateField.text = dateText(end)
        endTimeField.text = timeText(end)
        allDayCheck.checked = false
        dueDateCheck.checked = true
        destinationBox.currentIndex = 0
        errorText = ""
        submitting = false
    }

    function openFor(kind, dateValue) {
        resetFields(kind, dateValue)
        open()
    }

    function failSubmission(message) {
        submitting = false
        errorText = String(message || AgendaTranslations.tr("This item could not be saved."))
    }

    function finishSubmission() {
        submitting = false
        close()
    }

    function submit() {
        if (submitting) return
        const title = titleField.text.trim()
        if (title === "") {
            errorText = AgendaTranslations.tr("Add a title before saving.")
            titleField.forceActiveFocus()
            return
        }

        const destination = selectedDestination()
        if (entryKind === "task") {
            let dueAt = null
            if (dueDateCheck.checked) {
                const due = taskDueValue(startDateField.text, startTimeField.text,
                    destination)
                if (!due) {
                    errorText = destinationUsesDateOnlyTasks(destination)
                        ? AgendaTranslations.tr("Use YYYY-MM-DD for the due date.")
                        : AgendaTranslations.tr("Use YYYY-MM-DD for the date and HH:MM for the time.")
                    startDateField.forceActiveFocus()
                    return
                }
                dueAt = due.getTime()
            }
            errorText = ""
            submitting = true
            payloadReady("task", {
                id: "",
                title: title,
                description: descriptionField.text.trim(),
                done: false,
                dueAt: dueAt,
                createdAt: Date.now(),
                source: String(destination.provider || "local"),
                externalId: "",
                account: String(destination.accountId || "")
            })
            return
        }

        const startDate = parseDate(startDateField.text)
        const endDate = parseDate(endDateField.text)
        let start
        let end
        if (allDayCheck.checked) {
            start = utcMidnight(startDate)
            end = utcMidnight(endDate)
            if (start && end && end.getTime() <= start.getTime())
                end = new Date(start.getTime() + 24 * 60 * 60 * 1000)
        } else {
            start = parseDateTime(startDateField.text, startTimeField.text)
            end = parseDateTime(endDateField.text, endTimeField.text)
        }
        if (!start || !end) {
            errorText = AgendaTranslations.tr("Use YYYY-MM-DD for dates and HH:MM for times.")
            startDateField.forceActiveFocus()
            return
        }
        if (end.getTime() <= start.getTime()) {
            errorText = AgendaTranslations.tr("The event must end after it starts.")
            endTimeField.forceActiveFocus()
            return
        }

        errorText = ""
        submitting = true
        payloadReady("event", {
            id: "",
            externalId: "",
            calendarId: String(destination.accountId || ""),
            calendarName: String(destination.calendarName || destination.label
                || AgendaTranslations.tr("QuickMail")),
            title: title,
            description: descriptionField.text.trim(),
            startAt: start.getTime(),
            endAt: end.getTime(),
            allDay: allDayCheck.checked,
            readOnly: false
        })
    }

    onOpened: Qt.callLater(function() { titleField.forceActiveFocus() })

    background: Rectangle {
        radius: Theme.radiusLarge
        color: Theme.surfaceRaised
        border.width: 1
        border.color: Theme.border
    }

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            Layout.leftMargin: 18
            Layout.rightMargin: 10
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 18
                color: Theme.accentSoft
                Text {
                    anchors.centerIn: parent
                    text: root.entryKind === "task" ? "\ue2e6" : "\ue878"
                    color: Theme.accent
                    font.family: Theme.iconFont
                    font.pixelSize: 20
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    text: root.entryKind === "task" ? AgendaTranslations.tr("New task") : AgendaTranslations.tr("New event")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 19
                    font.weight: Font.DemiBold
                }
                Text {
                    text: AgendaTranslations.formatDate(root.selectedDate, "dddd, d MMMM")
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }
            }

            IconButton {
                iconName: "close"
                tip: AgendaTranslations.tr("Close")
                enabled: !root.submitting
                Accessible.name: tip
                onClicked: root.close()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width: Math.max(0, parent.width - 28)
                x: 14
                spacing: 12

                Item { Layout.preferredHeight: 2 }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Button {
                        id: eventKindButton
                        Layout.fillWidth: true
                        implicitHeight: 38
                        text: AgendaTranslations.tr("Event")
                        checkable: true
                        checked: root.entryKind === "event"
                        focusPolicy: Qt.StrongFocus
                        Accessible.name: AgendaTranslations.tr("Create an event")
                        onClicked: root.entryKind = "event"
                        background: Rectangle {
                            radius: Theme.radiusSmall
                            color: eventKindButton.checked ? Theme.surfaceSelected
                                : eventKindButton.hovered ? Theme.surfaceHover : Theme.surface
                            border.width: eventKindButton.visualFocus ? 1 : 0
                            border.color: Theme.accent
                        }
                        contentItem: Text {
                            text: eventKindButton.text
                            color: eventKindButton.checked ? Theme.accent : Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        id: taskKindButton
                        Layout.fillWidth: true
                        implicitHeight: 38
                        text: AgendaTranslations.tr("Task")
                        checkable: true
                        checked: root.entryKind === "task"
                        focusPolicy: Qt.StrongFocus
                        Accessible.name: AgendaTranslations.tr("Create a task")
                        onClicked: root.entryKind = "task"
                        background: Rectangle {
                            radius: Theme.radiusSmall
                            color: taskKindButton.checked ? Theme.surfaceSelected
                                : taskKindButton.hovered ? Theme.surfaceHover : Theme.surface
                            border.width: taskKindButton.visualFocus ? 1 : 0
                            border.color: Theme.accent
                        }
                        contentItem: Text {
                            text: taskKindButton.text
                            color: taskKindButton.checked ? Theme.accent : Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Text {
                    text: AgendaTranslations.tr("TITLE")
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.1
                }

                TextField {
                    id: titleField
                    Layout.fillWidth: true
                    implicitHeight: 42
                    placeholderText: root.entryKind === "task"
                        ? AgendaTranslations.tr("What needs doing?") : AgendaTranslations.tr("Event title")
                    color: Theme.text
                    placeholderTextColor: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 14
                    leftPadding: 12
                    rightPadding: 12
                    selectByMouse: true
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: root.entryKind === "task" ? AgendaTranslations.tr("Task title") : AgendaTranslations.tr("Event title")
                    onAccepted: root.submit()
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: Theme.surface
                        border.width: parent.activeFocus ? 1 : 0
                        border.color: Theme.accent
                    }
                }

                Text {
                    text: AgendaTranslations.tr("DESTINATION")
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.1
                }

                StyledComboBox {
                    id: destinationBox
                    Layout.fillWidth: true
                    model: root.destinations
                    textRole: "label"
                    iconName: "account"
                    Accessible.name: AgendaTranslations.tr("Account or local calendar")
                }

                CheckBox {
                    id: dueDateCheck
                    visible: root.entryKind === "task"
                    implicitHeight: 34
                    text: AgendaTranslations.tr("Set a due date")
                    checked: true
                    enabled: !root.submitting
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: text
                    indicator: Rectangle {
                        x: 0
                        y: Math.round((dueDateCheck.height - height) / 2)
                        implicitWidth: 20
                        implicitHeight: 20
                        radius: 6
                        color: dueDateCheck.checked ? Theme.accent : "transparent"
                        border.width: dueDateCheck.visualFocus ? 2 : 1
                        border.color: dueDateCheck.checked || dueDateCheck.visualFocus
                            ? Theme.accent : Theme.textMuted

                        Text {
                            anchors.centerIn: parent
                            visible: dueDateCheck.checked
                            text: Theme.icon("check")
                            color: Theme.accentText
                            font.family: Theme.iconFont
                            font.pixelSize: 15
                        }
                    }
                    contentItem: Text {
                        text: dueDateCheck.text
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        leftPadding: dueDateCheck.indicator.width + dueDateCheck.spacing
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.entryKind === "task" && dueDateCheck.checked
                        && root.selectedTaskDateOnly
                    text: AgendaTranslations.tr("Google Tasks stores a due date without a time.")
                    textFormat: Text.PlainText
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.StaticText
                }

                CheckBox {
                    id: allDayCheck
                    visible: root.entryKind === "event"
                    implicitHeight: 34
                    text: AgendaTranslations.tr("All-day event")
                    enabled: !root.submitting
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: text
                    indicator: Rectangle {
                        x: 0
                        y: Math.round((allDayCheck.height - height) / 2)
                        implicitWidth: 20
                        implicitHeight: 20
                        radius: 6
                        color: allDayCheck.checked ? Theme.accent : "transparent"
                        border.width: allDayCheck.visualFocus ? 2 : 1
                        border.color: allDayCheck.checked || allDayCheck.visualFocus
                            ? Theme.accent : Theme.textMuted

                        Text {
                            anchors.centerIn: parent
                            visible: allDayCheck.checked
                            text: Theme.icon("check")
                            color: Theme.accentText
                            font.family: Theme.iconFont
                            font.pixelSize: 15
                        }
                    }
                    contentItem: Text {
                        text: allDayCheck.text
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        leftPadding: allDayCheck.indicator.width + allDayCheck.spacing
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.width < 430 ? 1 : 2
                    columnSpacing: 10
                    rowSpacing: 8
                    visible: root.entryKind === "event" || dueDateCheck.checked

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 5
                        Text {
                            text: root.entryKind === "task" ? AgendaTranslations.tr("DUE DATE") : AgendaTranslations.tr("START DATE")
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                        }
                        TextField {
                            id: startDateField
                            Layout.fillWidth: true
                            implicitHeight: 40
                            inputMethodHints: Qt.ImhDate
                            placeholderText: "YYYY-MM-DD"
                            color: Theme.text
                            placeholderTextColor: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            leftPadding: 11
                            rightPadding: 11
                            Accessible.name: root.entryKind === "task" ? AgendaTranslations.tr("Due date") : AgendaTranslations.tr("Start date")
                            background: Rectangle {
                                radius: Theme.radiusSmall
                                color: Theme.surface
                                border.width: parent.activeFocus ? 1 : 0
                                border.color: Theme.accent
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: !allDayCheck.checked && !(root.entryKind === "task"
                            && root.selectedTaskDateOnly)
                        spacing: 5
                        Text {
                            text: root.entryKind === "task" ? AgendaTranslations.tr("DUE TIME") : AgendaTranslations.tr("START TIME")
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                        }
                        TextField {
                            id: startTimeField
                            Layout.fillWidth: true
                            implicitHeight: 40
                            inputMethodHints: Qt.ImhTime
                            placeholderText: "HH:MM"
                            color: Theme.text
                            placeholderTextColor: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            leftPadding: 11
                            rightPadding: 11
                            Accessible.name: root.entryKind === "task" ? AgendaTranslations.tr("Due time") : AgendaTranslations.tr("Start time")
                            background: Rectangle {
                                radius: Theme.radiusSmall
                                color: Theme.surface
                                border.width: parent.activeFocus ? 1 : 0
                                border.color: Theme.accent
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: root.entryKind === "event"
                        spacing: 5
                        Text {
                            text: AgendaTranslations.tr("END DATE")
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                        }
                        TextField {
                            id: endDateField
                            Layout.fillWidth: true
                            implicitHeight: 40
                            inputMethodHints: Qt.ImhDate
                            placeholderText: "YYYY-MM-DD"
                            color: Theme.text
                            placeholderTextColor: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            leftPadding: 11
                            rightPadding: 11
                            Accessible.name: AgendaTranslations.tr("End date")
                            background: Rectangle {
                                radius: Theme.radiusSmall
                                color: Theme.surface
                                border.width: parent.activeFocus ? 1 : 0
                                border.color: Theme.accent
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: root.entryKind === "event" && !allDayCheck.checked
                        spacing: 5
                        Text {
                            text: AgendaTranslations.tr("END TIME")
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                        }
                        TextField {
                            id: endTimeField
                            Layout.fillWidth: true
                            implicitHeight: 40
                            inputMethodHints: Qt.ImhTime
                            placeholderText: "HH:MM"
                            color: Theme.text
                            placeholderTextColor: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            leftPadding: 11
                            rightPadding: 11
                            Accessible.name: AgendaTranslations.tr("End time")
                            background: Rectangle {
                                radius: Theme.radiusSmall
                                color: Theme.surface
                                border.width: parent.activeFocus ? 1 : 0
                                border.color: Theme.accent
                            }
                        }
                    }
                }

                Text {
                    text: AgendaTranslations.tr("NOTES")
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.1
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96
                    TextArea {
                        id: descriptionField
                        placeholderText: AgendaTranslations.tr("Optional details")
                        color: Theme.text
                        placeholderTextColor: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        leftPadding: 11
                        rightPadding: 11
                        topPadding: 9
                        bottomPadding: 9
                        Accessible.name: AgendaTranslations.tr("Notes")
                        background: Rectangle {
                            radius: Theme.radiusSmall
                            color: Theme.surface
                            border.width: parent.activeFocus ? 1 : 0
                            border.color: Theme.accent
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.errorText !== ""
                    text: root.errorText
                    textFormat: Text.PlainText
                    color: Theme.danger
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.AlertMessage
                }

                Item { Layout.preferredHeight: 4 }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 68
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            spacing: 10

            Text {
                Layout.fillWidth: true
                text: root.entryKind === "task" ? AgendaTranslations.tr("Tasks appear in your unified agenda.")
                    : AgendaTranslations.tr("Events appear in Calendar and the sidebar agenda.")
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 10
                wrapMode: Text.WordWrap
            }

            Button {
                text: AgendaTranslations.tr("Cancel")
                flat: true
                enabled: !root.submitting
                focusPolicy: Qt.StrongFocus
                onClicked: root.close()
            }

            PrimaryButton {
                text: root.submitting ? AgendaTranslations.tr("Saving…") : AgendaTranslations.tr("Save")
                iconName: root.submitting ? "" : "check"
                enabled: !root.submitting
                Accessible.name: root.entryKind === "task" ? AgendaTranslations.tr("Save task") : AgendaTranslations.tr("Save event")
                onClicked: root.submit()
            }
        }
    }
}
