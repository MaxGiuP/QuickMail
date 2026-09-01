pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    required property var store
    property bool mobile: false
    property date selectedDate: root.startOfDay(new Date())
    property date visibleMonth: new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1)
    property int activeTab: 0 // 0 agenda | 1 tasks
    property string mutationError: ""
    property string pendingEntryId: ""
    property string pendingEntryKind: ""
    property var pendingDelete: null

    signal backRequested()

    readonly property bool compactLayout: mobile || width < 760
    readonly property date today: root.startOfDay(clock.now)
    readonly property var accountDestinations: root.buildDestinations(
        store && Array.isArray(store.accounts) ? store.accounts : [])
    readonly property var monthDays: root.buildMonthDays(visibleMonth)
    readonly property var selectedAgenda: root.buildSelectedAgenda()
    readonly property var taskItems: root.buildTaskItems()
    readonly property int selectedEventCount: root.eventsForDate(selectedDate).length
    readonly property int selectedTaskCount: root.tasksForDate(selectedDate).length
    readonly property int calendarColumnCount: 7
    readonly property int calendarWeekRowCount: 6
    readonly property real calendarDayCellHeight: compactLayout ? 32 : 36
    readonly property real calendarColumnWidth: calendarGrid.width > 0
        ? (calendarGrid.width - calendarGrid.columnSpacing * (calendarColumnCount - 1))
            / calendarColumnCount
        : 0

    color: Theme.canvas

    function startOfDay(value) {
        const date = value instanceof Date ? value : new Date(value)
        if (isNaN(date.getTime())) return new Date(0)
        return new Date(date.getFullYear(), date.getMonth(), date.getDate())
    }

    function endOfDay(value) {
        const start = startOfDay(value)
        return new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1)
    }

    function timestamp(value) {
        if (value === undefined || value === null || value === "") return NaN
        const date = value instanceof Date ? value : new Date(value)
        return date.getTime()
    }

    function value(item, camelName, snakeName) {
        if (!item) return undefined
        return item[camelName] !== undefined ? item[camelName] : item[snakeName]
    }

    function itemId(item) {
        return String(item && (item.id || item.taskId || item.task_id
            || item.eventId || item.event_id) || "")
    }

    function sameDay(left, right) {
        const first = startOfDay(left)
        const second = startOfDay(right)
        return first.getTime() === second.getTime()
    }

    function eventIntersectsDate(event, dateValue) {
        const dayStart = startOfDay(dateValue).getTime()
        const nextDay = endOfDay(dateValue).getTime()
        const start = timestamp(value(event, "startAt", "start_at"))
        let end = timestamp(value(event, "endAt", "end_at"))
        if (isNaN(start)) return false
        if (isNaN(end) || end <= start) end = start + 1
        return start < nextDay && end > dayStart
    }

    function taskDueOnDate(task, dateValue) {
        const due = taskDueDate(task)
        return due !== null && sameDay(due, dateValue)
    }

    function taskUsesDateOnlyDue(task) {
        const source = String(task && task.source || "").trim().toLowerCase()
        return source === "gmail" || source === "google" || source === "google_tasks"
            || source.indexOf("gmail") >= 0 || source.indexOf("google") >= 0
    }

    function taskDueDate(task) {
        const due = timestamp(value(task, "dueAt", "due_at"))
        if (isNaN(due)) return null
        const instant = new Date(due)
        if (!taskUsesDateOnlyDue(task)) return instant
        return new Date(instant.getUTCFullYear(), instant.getUTCMonth(), instant.getUTCDate())
    }

    function eventsForDate(dateValue) {
        const source = store && Array.isArray(store.events) ? store.events : []
        return source.filter(function(event) { return root.eventIntersectsDate(event, dateValue) })
    }

    function tasksForDate(dateValue) {
        const source = store && Array.isArray(store.tasks) ? store.tasks : []
        return source.filter(function(task) { return root.taskDueOnDate(task, dateValue) })
    }

    function buildSelectedAgenda() {
        const entries = []
        const events = eventsForDate(selectedDate)
        const tasks = tasksForDate(selectedDate)
        const dayTime = startOfDay(selectedDate).getTime()
        for (let i = 0; i < events.length; ++i) {
            const start = timestamp(value(events[i], "startAt", "start_at"))
            const allDay = events[i].allDay === true || events[i].all_day === true
            entries.push({ kind: "event", item: events[i],
                sortTime: allDay ? dayTime - 2 : start })
        }
        for (let i = 0; i < tasks.length; ++i) {
            const dueDate = taskDueDate(tasks[i])
            const due = dueDate ? dueDate.getTime() : Number.POSITIVE_INFINITY
            entries.push({ kind: "task", item: tasks[i], sortTime: due })
        }
        entries.sort(function(left, right) {
            if (left.sortTime !== right.sortTime) return left.sortTime - right.sortTime
            return String(left.item.title || "").localeCompare(String(right.item.title || ""))
        })
        return entries
    }

    function buildTaskItems() {
        const source = store && Array.isArray(store.tasks) ? store.tasks.slice() : []
        source.sort(function(left, right) {
            const leftDone = left && left.done === true ? 1 : 0
            const rightDone = right && right.done === true ? 1 : 0
            if (leftDone !== rightDone) return leftDone - rightDone
            const leftDate = taskDueDate(left)
            const rightDate = taskDueDate(right)
            const leftDue = leftDate ? leftDate.getTime() : NaN
            const rightDue = rightDate ? rightDate.getTime() : NaN
            if (isNaN(leftDue) && !isNaN(rightDue)) return 1
            if (!isNaN(leftDue) && isNaN(rightDue)) return -1
            if (!isNaN(leftDue) && !isNaN(rightDue) && leftDue !== rightDue)
                return leftDue - rightDue
            return String(left && left.title || "").localeCompare(String(right && right.title || ""))
        })
        return source
    }

    function buildMonthDays(monthValue) {
        const month = monthValue instanceof Date ? monthValue : new Date(monthValue)
        const first = new Date(month.getFullYear(), month.getMonth(), 1)
        const mondayOffset = (first.getDay() + 6) % 7
        const gridStart = new Date(first.getFullYear(), first.getMonth(), 1 - mondayOffset)
        const result = []
        for (let i = 0; i < 42; ++i)
            result.push(new Date(gridStart.getFullYear(), gridStart.getMonth(), gridStart.getDate() + i))
        return result
    }

    function providerKey(account) {
        return String(account && (account.provider || account.protocol) || "")
            .trim().toLowerCase()
    }

    function accountSupportsAgenda(account) {
        if (!account || account.enabled === false || account.calendarEnabled === false
                || account.calendar_enabled === false) return false
        if (account.calendarEnabled === true || account.calendar_enabled === true
                || account.tasksEnabled === true || account.tasks_enabled === true)
            return true
        const capabilities = account.capabilities || ({})
        if (capabilities.calendar === true || capabilities.tasks === true
                || capabilities.agenda === true) return true
        const provider = providerKey(account)
        return provider.indexOf("gmail") >= 0 || provider.indexOf("google") >= 0
            || provider.indexOf("outlook") >= 0 || provider.indexOf("hotmail") >= 0
            || provider.indexOf("microsoft") >= 0 || provider.indexOf("office365") >= 0
            || provider.indexOf("ms_graph") >= 0
    }

    function providerDisplay(account) {
        const provider = providerKey(account)
        if (provider.indexOf("gmail") >= 0 || provider.indexOf("google") >= 0)
            return AgendaTranslations.tr("Google")
        if (provider.indexOf("outlook") >= 0 || provider.indexOf("hotmail") >= 0
                || provider.indexOf("microsoft") >= 0 || provider.indexOf("office365") >= 0
                || provider.indexOf("ms_graph") >= 0)
            return AgendaTranslations.tr("Microsoft")
        return String(account && account.provider || AgendaTranslations.tr("Account"))
    }

    function buildDestinations(accounts) {
        const result = [{
            accountId: "",
            provider: "local",
            label: AgendaTranslations.tr("QuickMail · Local"),
            calendarName: AgendaTranslations.tr("QuickMail")
        }]
        for (let i = 0; i < accounts.length; ++i) {
            const account = accounts[i]
            if (!accountSupportsAgenda(account)) continue
            const accountId = String(account.id || account.accountId || account.account_id || "")
            if (accountId === "") continue
            const address = String(account.address || account.email || account.displayName
                || account.display_name || accountId)
            const provider = providerKey(account) || "account"
            const label = providerDisplay(account) + " · " + address
            result.push({ accountId: accountId, provider: provider, label: label,
                calendarName: label })
        }
        return result
    }

    function entryDestination(kind, entry) {
        if (!entry) return AgendaTranslations.tr("Local")
        if (kind !== "task") {
            return String(entry.calendarName || entry.calendar_name
                || entry.calendarId || entry.calendar_id || AgendaTranslations.tr("Local"))
        }
        const accountId = String(entry.account || "")
        if (accountId !== "") {
            for (let i = 0; i < accountDestinations.length; ++i) {
                if (String(accountDestinations[i].accountId || "") === accountId)
                    return String(accountDestinations[i].label || accountId)
            }
            return accountId
        }
        const source = String(entry.source || "local")
        return source === "" || source === "local" ? AgendaTranslations.tr("Local") : source
    }

    function selectDate(value) {
        const chosen = startOfDay(value)
        selectedDate = chosen
        if (chosen.getFullYear() !== visibleMonth.getFullYear()
                || chosen.getMonth() !== visibleMonth.getMonth())
            visibleMonth = new Date(chosen.getFullYear(), chosen.getMonth(), 1)
    }

    function showPreviousMonth() {
        moveToMonth(-1)
    }

    function showNextMonth() {
        moveToMonth(1)
    }

    function moveToMonth(offset) {
        const targetMonth = new Date(visibleMonth.getFullYear(),
            visibleMonth.getMonth() + offset, 1)
        const maximumDay = new Date(targetMonth.getFullYear(),
            targetMonth.getMonth() + 1, 0).getDate()
        const preferredDay = Math.max(1, Math.min(selectedDate.getDate(), maximumDay))
        selectDate(new Date(targetMonth.getFullYear(), targetMonth.getMonth(), preferredDay))
    }

    function showToday() {
        selectDate(today)
    }

    function returnToMail() {
        backRequested()
    }

    function openEventComposer() {
        composer.openFor("event", selectedDate)
    }

    function openTaskComposer() {
        composer.openFor("task", selectedDate)
    }

    function reloadAgenda() {
        if (!store) return
        if (typeof store.loadAgenda === "function") store.loadAgenda()
        else if (typeof store.loadSnapshot === "function") store.loadSnapshot()
    }

    function refreshAgenda() {
        if (!store) return
        if (typeof store.syncAgenda === "function") store.syncAgenda()
        else reloadAgenda()
    }

    function errorMessage(error, fallback) {
        return String(error && (error.message || error.detail) || fallback)
    }

    function submitCreatedEntry(kind, payload) {
        mutationError = ""
        try {
            if (kind === "task") {
                if (!store || typeof store.createTask !== "function") {
                    composer.failSubmission(AgendaTranslations.tr("Task creation is not connected to QuickMail yet."))
                    return
                }
                store.createTask(payload, function(result, error) {
                    if (error) {
                        composer.failSubmission(root.errorMessage(error, AgendaTranslations.tr("The task could not be saved.")))
                        return
                    }
                    composer.finishSubmission()
                    root.reloadAgenda()
                })
                return
            }
            if (!store || typeof store.createCalendarEvent !== "function") {
                composer.failSubmission(AgendaTranslations.tr("Calendar creation is not connected to QuickMail yet."))
                return
            }
            store.createCalendarEvent(payload, function(result, error) {
                if (error) {
                    composer.failSubmission(root.errorMessage(error, AgendaTranslations.tr("The event could not be saved.")))
                    return
                }
                composer.finishSubmission()
                root.reloadAgenda()
            })
        } catch (error) {
            composer.failSubmission(root.errorMessage(error, AgendaTranslations.tr("This item could not be saved.")))
        }
    }

    function setTaskDone(task, done) {
        if (!task || pendingEntryId !== "") return
        if (!store || typeof store.completeTask !== "function") {
            mutationError = AgendaTranslations.tr("Task completion is not connected to QuickMail yet.")
            return
        }
        pendingEntryId = itemId(task)
        pendingEntryKind = "task"
        mutationError = ""
        try {
            store.completeTask(task, done, function(result, error) {
                root.pendingEntryId = ""
                root.pendingEntryKind = ""
                if (error) {
                    root.mutationError = root.errorMessage(error,
                        AgendaTranslations.tr("The task could not be updated."))
                    return
                }
                root.reloadAgenda()
            })
        } catch (error) {
            pendingEntryId = ""
            pendingEntryKind = ""
            mutationError = errorMessage(error, AgendaTranslations.tr("The task could not be updated."))
        }
    }

    function requestDelete(kind, entry) {
        if (!entry || pendingEntryId !== "") return
        pendingDelete = { kind: kind, item: entry }
        deleteDialog.open()
    }

    function confirmDelete() {
        const removal = pendingDelete
        pendingDelete = null
        if (!removal || !store) return
        pendingEntryId = itemId(removal.item)
        pendingEntryKind = removal.kind
        mutationError = ""
        const callback = function(result, error) {
            root.pendingEntryId = ""
            root.pendingEntryKind = ""
            if (error) {
                root.mutationError = root.errorMessage(error,
                    removal.kind === "task" ? AgendaTranslations.tr("The task could not be deleted.")
                        : AgendaTranslations.tr("The event could not be deleted."))
                return
            }
            root.reloadAgenda()
        }
        try {
            if (removal.kind === "task") {
                if (typeof store.deleteTask !== "function") {
                    callback(null, { message: AgendaTranslations.tr("Task deletion is not connected to QuickMail yet.") })
                    return
                }
                store.deleteTask(removal.item, callback)
            } else {
                if (typeof store.deleteCalendarEvent !== "function") {
                    callback(null, { message: AgendaTranslations.tr("Calendar deletion is not connected to QuickMail yet.") })
                    return
                }
                store.deleteCalendarEvent(removal.item, callback)
            }
        } catch (error) {
            callback(null, error)
        }
    }

    function dayAccessibleName(dateValue) {
        const events = eventsForDate(dateValue).length
        const tasks = tasksForDate(dateValue).filter(function(task) { return task.done !== true }).length
        let detail = ""
        if (events > 0) detail += AgendaTranslations.tr(", %n event(s)", events)
        if (tasks > 0) detail += AgendaTranslations.tr(", %n open task(s)", tasks)
        return AgendaTranslations.formatDate(dateValue, "dddd d MMMM yyyy") + detail
    }

    Timer {
        id: clock
        property date now: new Date()
        interval: 60000
        running: true
        repeat: true
        onTriggered: now = new Date()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 68
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            spacing: 9

            Button {
                id: backButton

                implicitWidth: root.compactLayout ? 40 : backButtonContent.implicitWidth + 18
                implicitHeight: 40
                leftPadding: 9
                rightPadding: 9
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                text: AgendaTranslations.tr("Back to mail")
                Accessible.name: text
                onClicked: root.returnToMail()

                contentItem: Row {
                    id: backButtonContent
                    spacing: 6

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Theme.icon("back")
                        color: Theme.textSecondary
                        font.family: Theme.iconFont
                        font.pixelSize: 20
                    }

                    Text {
                        visible: !root.compactLayout
                        anchors.verticalCenter: parent.verticalCenter
                        text: backButton.text
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                }

                background: Rectangle {
                    radius: Theme.radiusSmall
                    color: backButton.down ? Theme.surfaceSelected
                        : backButton.hovered || backButton.visualFocus
                            ? Theme.surfaceHover : "transparent"
                    border.width: backButton.visualFocus ? 1 : 0
                    border.color: Theme.accent
                }

                ToolTip.visible: backButton.hovered && root.compactLayout
                ToolTip.text: backButton.text
                ToolTip.delay: 500
            }

            Rectangle {
                visible: root.width >= 420
                Layout.preferredWidth: 38
                Layout.preferredHeight: 38
                radius: 19
                color: Theme.accentSoft
                Text {
                    anchors.centerIn: parent
                    text: "\ue935"
                    color: Theme.accent
                    font.family: Theme.iconFont
                    font.pixelSize: 21
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: 0
                Text {
                    Layout.fillWidth: true
                    text: AgendaTranslations.tr("Calendar")
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 21
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: AgendaTranslations.formatDate(root.selectedDate, "dddd, d MMMM yyyy")
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            IconButton {
                iconName: "refresh"
                tip: AgendaTranslations.tr("Refresh calendar and tasks")
                enabled: !(root.store && root.store.agendaLoading === true)
                Accessible.name: tip
                onClicked: root.refreshAgenda()
                RotationAnimator on rotation {
                    running: root.store && root.store.agendaLoading === true
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                }
            }

            PrimaryButton {
                text: root.compactLayout ? "" : AgendaTranslations.tr("New")
                iconName: "compose"
                Accessible.name: AgendaTranslations.tr("Create an event or task")
                onClicked: createMenu.open()

                Menu {
                    id: createMenu
                    y: parent.height + 4
                    MenuItem {
                        text: AgendaTranslations.tr("New event")
                        onTriggered: root.openEventComposer()
                    }
                    MenuItem {
                        text: AgendaTranslations.tr("New task")
                        onTriggered: root.openTaskComposer()
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.borderSoft
        }

        GridLayout {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: root.compactLayout ? 1 : 2
            rows: root.compactLayout ? 2 : 1
            columnSpacing: 0
            rowSpacing: 0

            Rectangle {
                id: monthPanel
                Layout.fillWidth: root.compactLayout
                Layout.fillHeight: !root.compactLayout
                Layout.minimumWidth: root.compactLayout ? 0 : 330
                Layout.maximumWidth: root.compactLayout ? Number.POSITIVE_INFINITY : 430
                Layout.preferredWidth: root.compactLayout ? -1
                    : Math.min(430, Math.max(330, body.width * 0.42))
                Layout.minimumHeight: root.compactLayout ? 288 : 0
                Layout.maximumHeight: root.compactLayout ? 356 : Number.POSITIVE_INFINITY
                Layout.preferredHeight: root.compactLayout
                    ? Math.min(356, Math.max(288, body.height * 0.51)) : -1
                color: Theme.surface
                border.width: 1
                border.color: Theme.borderSoft

                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: root.compactLayout ? 10 : 16
                    anchors.rightMargin: root.compactLayout ? 10 : 16
                    anchors.topMargin: 10
                    anchors.bottomMargin: 10
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        spacing: 4

                        Text {
                            Layout.fillWidth: true
                            text: AgendaTranslations.formatDate(root.visibleMonth, "MMMM yyyy")
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: 17
                            font.weight: Font.DemiBold
                        }

                        Button {
                            text: AgendaTranslations.tr("Today")
                            flat: true
                            implicitHeight: 34
                            focusPolicy: Qt.StrongFocus
                            Accessible.name: AgendaTranslations.tr("Go to today")
                            onClicked: root.showToday()
                        }

                        IconButton {
                            iconName: "back"
                            tip: AgendaTranslations.tr("Previous month")
                            implicitWidth: 34
                            implicitHeight: 34
                            Accessible.name: tip
                            onClicked: root.showPreviousMonth()
                        }

                        IconButton {
                            iconName: "chevron"
                            tip: AgendaTranslations.tr("Next month")
                            implicitWidth: 34
                            implicitHeight: 34
                            Accessible.name: tip
                            onClicked: root.showNextMonth()
                        }
                    }

                    GridLayout {
                        id: calendarGrid

                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        columns: root.calendarColumnCount
                        rows: root.calendarWeekRowCount + 1
                        columnSpacing: 4
                        rowSpacing: 4
                        uniformCellWidths: true

                        Repeater {
                            model: [AgendaTranslations.tr("Mon"), AgendaTranslations.tr("Tue"), AgendaTranslations.tr("Wed"), AgendaTranslations.tr("Thu"),
                                AgendaTranslations.tr("Fri"), AgendaTranslations.tr("Sat"), AgendaTranslations.tr("Sun")]
                            Text {
                                required property string modelData
                                Layout.fillWidth: true
                                Layout.minimumHeight: 22
                                Layout.preferredHeight: 22
                                Layout.maximumHeight: 22
                                text: modelData
                                color: Theme.textMuted
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        Repeater {
                            model: root.monthDays

                            Button {
                                id: dayButton
                                required property var modelData
                                required property int index
                                readonly property date day: modelData
                                readonly property bool inMonth: day.getMonth() === root.visibleMonth.getMonth()
                                    && day.getFullYear() === root.visibleMonth.getFullYear()
                                readonly property bool selected: root.sameDay(day, root.selectedDate)
                                readonly property bool currentDay: root.sameDay(day, root.today)
                                readonly property int eventCount: root.eventsForDate(day).length
                                readonly property int openTaskCount: root.tasksForDate(day).filter(
                                    function(task) { return task.done !== true }).length

                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                Layout.minimumHeight: root.calendarDayCellHeight
                                Layout.preferredHeight: root.calendarDayCellHeight
                                Layout.maximumHeight: root.calendarDayCellHeight
                                hoverEnabled: true
                                focusPolicy: Qt.StrongFocus
                                Accessible.name: root.dayAccessibleName(day)
                                Accessible.description: selected ? AgendaTranslations.tr("Selected date") : ""
                                onClicked: root.selectDate(day)

                                contentItem: Item {
                                    Rectangle {
                                        id: dayMarker

                                        width: 29
                                        height: 29
                                        radius: width / 2
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: dayButton.eventCount > 0 || dayButton.openTaskCount > 0
                                            ? 0 : Math.round((parent.height - height) / 2)
                                        color: dayButton.selected ? Theme.accent
                                            : dayButton.down ? Theme.surfaceSelected
                                            : dayButton.hovered ? Theme.surfaceHover : "transparent"
                                        border.width: dayButton.visualFocus ? 2
                                            : dayButton.currentDay ? 1 : 0
                                        border.color: dayButton.visualFocus
                                            ? (dayButton.selected ? Theme.accentText : Theme.accent)
                                            : Theme.accent

                                        Text {
                                            anchors.centerIn: parent
                                            text: dayButton.day.getDate()
                                            color: dayButton.selected ? Theme.accentText
                                                : dayButton.currentDay ? Theme.accent
                                                : dayButton.inMonth ? Theme.text : Theme.textMuted
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 12
                                            font.weight: dayButton.currentDay || dayButton.selected
                                                ? Font.DemiBold : Font.Normal
                                        }
                                    }

                                    Row {
                                        anchors.top: dayMarker.bottom
                                        anchors.topMargin: 1
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        spacing: 3
                                        Rectangle {
                                            visible: dayButton.eventCount > 0
                                            width: 4
                                            height: 4
                                            radius: 2
                                            color: Theme.accent
                                        }
                                        Rectangle {
                                            visible: dayButton.openTaskCount > 0
                                            width: 4
                                            height: 4
                                            radius: 2
                                            color: Theme.success
                                        }
                                    }
                                }

                                background: Rectangle {
                                    color: "transparent"
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 22
                        spacing: 7
                        Rectangle {
                            Layout.preferredWidth: 5
                            Layout.preferredHeight: 5
                            radius: 3
                            color: Theme.accent
                        }
                        Text {
                            text: AgendaTranslations.tr("Events")
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                        }
                        Rectangle {
                            Layout.preferredWidth: 5
                            Layout.preferredHeight: 5
                            radius: 3
                            color: Theme.success
                        }
                        Text {
                            text: AgendaTranslations.tr("Open tasks")
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: root.accountDestinations.length > 1
                            text: AgendaTranslations.tr("%1 accounts").arg(root.accountDestinations.length - 1)
                            color: Theme.textMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                        }
                    }
                }

            }

            Rectangle {
                id: detailPanel
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 0
                Layout.minimumHeight: root.compactLayout ? 150 : 0
                color: Theme.canvas

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    StatusBanner {
                        Layout.fillWidth: true
                        kind: "error"
                        message: root.mutationError
                        onDismissed: root.mutationError = ""
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 66
                        Layout.leftMargin: 14
                        Layout.rightMargin: 12
                        spacing: 10

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            spacing: 1
                            Text {
                                Layout.fillWidth: true
                                text: root.activeTab === 0
                                    ? AgendaTranslations.formatDate(root.selectedDate, "dddd, d MMMM")
                                    : AgendaTranslations.tr("All tasks")
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.activeTab === 0
                                    ? AgendaTranslations.tr("%1 events · %2 tasks").arg(root.selectedEventCount)
                                        .arg(root.selectedTaskCount)
                                    : AgendaTranslations.tr("%n task(s)", root.taskItems.length)
                                color: Theme.textMuted
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }

                        Row {
                            spacing: 3
                            Button {
                                id: agendaTab
                                implicitWidth: root.compactLayout ? 72 : 88
                                implicitHeight: 36
                                text: AgendaTranslations.tr("Agenda")
                                checkable: true
                                checked: root.activeTab === 0
                                focusPolicy: Qt.StrongFocus
                                Accessible.name: AgendaTranslations.tr("Show selected day agenda")
                                onClicked: root.activeTab = 0
                                contentItem: Text {
                                    text: parent.text
                                    color: parent.checked ? Theme.accent : Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    radius: Theme.radiusSmall
                                    color: parent.checked ? Theme.surfaceSelected
                                        : parent.hovered ? Theme.surfaceHover : "transparent"
                                    border.width: parent.visualFocus ? 1 : 0
                                    border.color: Theme.accent
                                }
                            }
                            Button {
                                id: tasksTab
                                implicitWidth: root.compactLayout ? 68 : 82
                                implicitHeight: 36
                                text: AgendaTranslations.tr("Tasks")
                                checkable: true
                                checked: root.activeTab === 1
                                focusPolicy: Qt.StrongFocus
                                Accessible.name: AgendaTranslations.tr("Show all tasks")
                                onClicked: root.activeTab = 1
                                contentItem: Text {
                                    text: parent.text
                                    color: parent.checked ? Theme.accent : Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    radius: Theme.radiusSmall
                                    color: parent.checked ? Theme.surfaceSelected
                                        : parent.hovered ? Theme.surfaceHover : "transparent"
                                    border.width: parent.visualFocus ? 1 : 0
                                    border.color: Theme.accent
                                }
                            }
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
                            visible: root.activeTab === 0 && root.selectedAgenda.length === 0
                            iconName: "check"
                            title: AgendaTranslations.tr("Nothing planned")
                            detail: AgendaTranslations.tr("This day is clear. Add an event or task when you’re ready.")
                            actionText: AgendaTranslations.tr("Add event")
                            onAction: root.openEventComposer()
                        }

                        EmptyState {
                            anchors.fill: parent
                            visible: root.activeTab === 1 && root.taskItems.length === 0
                            iconName: "check"
                            title: AgendaTranslations.tr("No tasks yet")
                            detail: AgendaTranslations.tr("Create a local task or send it to a connected account.")
                            actionText: AgendaTranslations.tr("Add task")
                            onAction: root.openTaskComposer()
                        }

                        ListView {
                            id: agendaList
                            anchors.fill: parent
                            anchors.margins: root.compactLayout ? 8 : 12
                            visible: root.activeTab === 0 && root.selectedAgenda.length > 0
                            model: root.selectedAgenda
                            spacing: 7
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {}

                            delegate: AgendaRow {
                                required property var modelData
                                required property int index
                                width: agendaList.width - (agendaList.ScrollBar.vertical.visible ? 10 : 0)
                                kind: modelData.kind
                                entry: modelData.item
                                compact: root.compactLayout
                                destinationLabel: root.entryDestination(kind, entry)
                                pending: root.pendingEntryId !== ""
                                    && root.pendingEntryKind === kind
                                    && root.pendingEntryId === root.itemId(entry)
                                onCompletionRequested: done => root.setTaskDone(entry, done)
                                onDeleteRequested: root.requestDelete(kind, entry)
                            }
                        }

                        ListView {
                            id: taskList
                            anchors.fill: parent
                            anchors.margins: root.compactLayout ? 8 : 12
                            visible: root.activeTab === 1 && root.taskItems.length > 0
                            model: root.taskItems
                            spacing: 7
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {}

                            delegate: AgendaRow {
                                required property var modelData
                                required property int index
                                width: taskList.width - (taskList.ScrollBar.vertical.visible ? 10 : 0)
                                kind: "task"
                                entry: modelData
                                compact: root.compactLayout
                                destinationLabel: root.entryDestination("task", entry)
                                pending: root.pendingEntryId !== ""
                                    && root.pendingEntryKind === "task"
                                    && root.pendingEntryId === root.itemId(entry)
                                onCompletionRequested: done => root.setTaskDone(entry, done)
                                onDeleteRequested: root.requestDelete("task", entry)
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 60
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        spacing: 8

                        PrimaryButton {
                            Layout.fillWidth: true
                            text: AgendaTranslations.tr("Add event")
                            iconName: "compose"
                            Accessible.name: text
                            onClicked: root.openEventComposer()
                        }

                        PrimaryButton {
                            Layout.fillWidth: true
                            text: AgendaTranslations.tr("Add task")
                            iconName: "check"
                            Accessible.name: text
                            onClicked: root.openTaskComposer()
                        }
                    }
                }
            }
        }
    }

    AgendaComposer {
        id: composer
        parent: root
        destinations: root.accountDestinations
        onPayloadReady: (kind, payload) => root.submitCreatedEntry(kind, payload)
    }

    Dialog {
        id: deleteDialog
        parent: root
        modal: true
        title: root.pendingDelete && root.pendingDelete.kind === "task"
            ? AgendaTranslations.tr("Delete this task?") : AgendaTranslations.tr("Delete this event?")
        standardButtons: Dialog.Yes | Dialog.Cancel
        width: Math.min(420, Math.max(280, root.width - 40))
        height: Math.min(210, Math.max(160, root.height - 40))
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onAccepted: root.confirmDelete()
        onRejected: root.pendingDelete = null
        contentItem: Text {
            text: root.pendingDelete && root.pendingDelete.kind === "task"
                ? AgendaTranslations.tr("The task will be removed from QuickMail and its destination account.")
                : AgendaTranslations.tr("The event will be removed from QuickMail and its destination calendar.")
            color: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
    }

    Shortcut { sequence: "Ctrl+Shift+E"; onActivated: root.openEventComposer() }
    Shortcut { sequence: "Ctrl+Shift+T"; onActivated: root.openTaskComposer() }
    Shortcut { sequence: "Ctrl+T"; onActivated: root.showToday() }
    Shortcut { sequence: "Left"; onActivated: root.selectDate(new Date(
        root.selectedDate.getFullYear(), root.selectedDate.getMonth(), root.selectedDate.getDate() - 1)) }
    Shortcut { sequence: "Right"; onActivated: root.selectDate(new Date(
        root.selectedDate.getFullYear(), root.selectedDate.getMonth(), root.selectedDate.getDate() + 1)) }
}
