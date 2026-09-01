pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    required property string kind // event | task
    required property var entry
    property bool compact: false
    property bool pending: false
    property string destinationLabel: ""

    signal completionRequested(bool done)
    signal deleteRequested()

    readonly property bool isTask: kind === "task"
    readonly property bool completed: isTask && entry && entry.done === true
    readonly property bool readOnly: !isTask && entry && (entry.readOnly === true
        || entry.read_only === true)
    readonly property double startTime: root.dateTime(entry && (entry.startAt
        !== undefined ? entry.startAt : entry.start_at))
    readonly property double endTime: root.dateTime(entry && (entry.endAt
        !== undefined ? entry.endAt : entry.end_at))
    readonly property double dueTime: root.dateTime(entry && (entry.dueAt
        !== undefined ? entry.dueAt : entry.due_at))
    readonly property bool taskDueDateOnly: isTask
        && root.dateOnlyTaskSource(entry && entry.source)
    readonly property bool allDay: !isTask && entry && (entry.allDay === true
        || entry.all_day === true)

    implicitHeight: compact ? 64 : 68
    radius: Theme.radius
    color: rowMouse.containsMouse ? Theme.surfaceHover : Theme.surface
    border.width: 1
    border.color: rowMouse.containsMouse ? Theme.border : Theme.borderSoft
    opacity: completed ? 0.62 : pending ? 0.72 : 1

    Behavior on color {
        ColorAnimation { duration: 100 }
    }

    function dateTime(value) {
        if (value === undefined || value === null || value === "") return NaN
        const parsed = value instanceof Date ? value : new Date(value)
        return parsed.getTime()
    }

    function dateOnlyTaskSource(value) {
        const source = String(value || "").trim().toLowerCase()
        return source === "gmail" || source === "google" || source === "google_tasks"
            || source.indexOf("gmail") >= 0 || source.indexOf("google") >= 0
    }

    function localDateFromUtcDay(timestamp) {
        const instant = new Date(timestamp)
        if (isNaN(instant.getTime())) return null
        return new Date(instant.getUTCFullYear(), instant.getUTCMonth(), instant.getUTCDate())
    }

    function secondaryText() {
        if (root.isTask) {
            if (isNaN(root.dueTime)) return AgendaTranslations.tr("No due date")
            if (root.taskDueDateOnly) {
                const dueDate = root.localDateFromUtcDay(root.dueTime)
                return AgendaTranslations.tr("Due %1").arg(
                    AgendaTranslations.formatDate(dueDate, "ddd d MMM"))
            }
            return AgendaTranslations.tr("Due %1").arg(
                AgendaTranslations.formatDate(new Date(root.dueTime), "ddd d MMM, HH:mm"))
        }
        if (root.allDay) return AgendaTranslations.tr("All day")
        if (isNaN(root.startTime)) return AgendaTranslations.tr("Time unavailable")
        const start = new Date(root.startTime)
        if (isNaN(root.endTime)) return AgendaTranslations.formatDate(start, "HH:mm")
        return AgendaTranslations.formatDate(start, "HH:mm") + "–"
            + AgendaTranslations.formatDate(new Date(root.endTime), "HH:mm")
    }

    function destinationText() {
        if (root.destinationLabel !== "") return root.destinationLabel
        if (!root.entry) return AgendaTranslations.tr("Local")
        if (root.isTask) {
            const source = String(root.entry.source || "local")
            const account = String(root.entry.account || "")
            if (account !== "") return account
            if (source !== "" && source !== "local") return source
            return AgendaTranslations.tr("Local")
        }
        return String(root.entry.calendarName || root.entry.calendar_name
            || root.entry.calendarId || root.entry.calendar_id || AgendaTranslations.tr("Local"))
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 8
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        spacing: 8

        CheckBox {
            id: taskCheck
            visible: root.isTask
            Layout.preferredWidth: 34
            Layout.preferredHeight: 34
            checked: root.completed
            enabled: !root.pending
            focusPolicy: Qt.StrongFocus
            Accessible.name: checked ? AgendaTranslations.tr("Mark %1 incomplete").arg(root.entry.title || AgendaTranslations.tr("task"))
                : AgendaTranslations.tr("Mark %1 complete").arg(root.entry.title || AgendaTranslations.tr("task"))
            indicator: Rectangle {
                x: Math.round((taskCheck.width - width) / 2)
                y: Math.round((taskCheck.height - height) / 2)
                implicitWidth: 20
                implicitHeight: 20
                radius: 6
                color: taskCheck.checked ? Theme.accent : "transparent"
                border.width: taskCheck.visualFocus ? 2 : 1
                border.color: taskCheck.checked ? Theme.accent
                    : taskCheck.visualFocus ? Theme.accent : Theme.textMuted

                Text {
                    anchors.centerIn: parent
                    visible: taskCheck.checked
                    text: Theme.icon("check")
                    color: Theme.accentText
                    font.family: Theme.iconFont
                    font.pixelSize: 15
                }
            }
            onToggled: {
                if (checked !== root.completed)
                    root.completionRequested(checked)
            }
        }

        Rectangle {
            visible: !root.isTask
            Layout.preferredWidth: 3
            Layout.fillHeight: true
            Layout.topMargin: 6
            Layout.bottomMargin: 6
            radius: 2
            color: Theme.accent
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: String(root.entry && root.entry.title || (root.isTask
                    ? AgendaTranslations.tr("Untitled task") : AgendaTranslations.tr("Untitled event")))
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 14
                font.weight: Font.DemiBold
                font.strikeout: root.completed
                elide: Text.ElideRight
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 7

                Text {
                    text: root.secondaryText()
                    textFormat: Text.PlainText
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.preferredWidth: 3
                    Layout.preferredHeight: 3
                    radius: 2
                    color: Theme.textMuted
                }

                Text {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: root.destinationText()
                    textFormat: Text.PlainText
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
        }

        BusyIndicator {
            visible: root.pending
            running: visible
            Layout.preferredWidth: 26
            Layout.preferredHeight: 26
        }

        IconButton {
            visible: !root.pending && !root.readOnly
            iconName: "trash"
            tip: root.isTask ? AgendaTranslations.tr("Delete task") : AgendaTranslations.tr("Delete event")
            destructive: true
            implicitWidth: 32
            implicitHeight: 32
            Accessible.name: tip
            onClicked: root.deleteRequested()
        }

        Text {
            visible: root.readOnly
            text: "\ue897"
            color: Theme.textMuted
            font.family: Theme.iconFont
            font.pixelSize: 17
            Accessible.name: AgendaTranslations.tr("Read-only event")
        }
    }

    MouseArea {
        id: rowMouse
        anchors.fill: parent
        anchors.rightMargin: root.readOnly ? 34 : 48
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }
}
