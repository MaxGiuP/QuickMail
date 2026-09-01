import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 980
    height: 720
    color: Theme.canvas

    function expect(condition, message) {
        if (condition) return
        console.error("CALENDAR PANE TEST FAILED: " + message)
        Qt.exit(1)
    }

    QtObject {
        id: fakeStore

        property var accounts: [{
            id: "gmail-a", address: "alex@gmail.com", provider: "gmail", enabled: true
        }, {
            id: "outlook-a", address: "alex@outlook.com", provider: "outlook", enabled: true
        }, {
            id: "imap-a", address: "mail@example.net", provider: "imap", enabled: true
        }]
        property var tasks: [{
            id: "task-a", title: "Submit review", description: "", done: false,
            dueAt: Date.UTC(2026, 8, 1),
            createdAt: new Date(2026, 7, 30).getTime(), source: "google_tasks",
            externalId: "", account: "gmail-a"
        }, {
            id: "task-b", title: "Unscheduled", description: "", done: true,
            dueAt: null, createdAt: new Date(2026, 7, 29).getTime(), source: "local",
            externalId: "", account: ""
        }]
        property var events: [{
            id: "event-a", externalId: "", calendarId: "outlook-a",
            calendarName: "Microsoft · alex@outlook.com", title: "Planning call",
            description: "", startAt: new Date(2026, 8, 1, 10, 0).getTime(),
            endAt: new Date(2026, 8, 1, 10, 45).getTime(), allDay: false,
            readOnly: false
        }]
        property bool agendaLoading: false
        property var lastTaskPayload: null
        property var lastEventPayload: null
        property string completedTaskId: ""
        property string deletedTaskId: ""
        property string deletedEventId: ""
        property int reloads: 0

        function createTask(payload, callback) {
            lastTaskPayload = payload
            callback({ task: payload }, null)
        }

        function createCalendarEvent(payload, callback) {
            lastEventPayload = payload
            callback({ event: payload }, null)
        }

        function completeTask(task, done, callback) {
            completedTaskId = String(task.id) + ":" + String(done)
            callback({}, null)
        }

        function deleteTask(task, callback) {
            deletedTaskId = String(task.id)
            callback({}, null)
        }

        function deleteCalendarEvent(event, callback) {
            deletedEventId = String(event.id)
            callback({}, null)
        }

        function loadAgenda() { ++reloads }
    }

    CalendarPane {
        id: calendarPane
        anchors.fill: parent
        store: fakeStore
        selectedDate: new Date(2026, 8, 1)
        visibleMonth: new Date(2026, 8, 1)
    }

    AgendaComposer {
        id: composerUnderTest
        parent: window.contentItem
        destinations: calendarPane.accountDestinations
    }

    Timer {
        interval: 80
        running: true
        repeat: false
        onTriggered: {
            window.expect(calendarPane.accountDestinations.length === 3,
                "local, Gmail, and Outlook destinations were not exposed")
            window.expect(calendarPane.monthDays.length === 42,
                "month view did not build a six-week grid")
            window.expect(calendarPane.selectedAgenda.length === 2,
                "selected day did not combine its event and due task")
            window.expect(calendarPane.taskItems.length === 2,
                "all-tasks view lost an unscheduled task")
            const allDayStart = composerUnderTest.utcMidnight(new Date(2026, 8, 1))
            window.expect(allDayStart.getUTCHours() === 0
                    && allDayStart.getUTCMinutes() === 0
                    && allDayStart.getUTCSeconds() === 0,
                "all-day events were not normalized to UTC midnight")

            const googleDue = composerUnderTest.taskDueValue("2026-09-01", "17:45",
                { provider: "gmail" })
            window.expect(googleDue.getTime() === Date.UTC(2026, 8, 1),
                "Google task due dates were not normalized to UTC midnight")
            const microsoftDue = composerUnderTest.taskDueValue("2026-09-01", "17:45",
                { provider: "outlook" })
            window.expect(microsoftDue.getTime()
                    === new Date(2026, 8, 1, 17, 45).getTime(),
                "Microsoft task due times were not preserved")
            const localDue = composerUnderTest.taskDueValue("2026-09-01", "08:15",
                { provider: "local" })
            window.expect(localDue.getTime() === new Date(2026, 8, 1, 8, 15).getTime(),
                "local task due times were not preserved")

            AgendaTranslations.localeOverride = "de_DE"
            window.expect(AgendaTranslations.tr("Calendar") === "Kalender",
                "German calendar translation was not selected")
            window.expect(AgendaTranslations.tr("Due %1").arg("morgen")
                    === "Fällig: morgen",
                "German placeholder translation was not preserved")
            window.expect(AgendaTranslations.tr("%n task(s)", 1) === "1 Aufgabe"
                    && AgendaTranslations.tr("%n task(s)", 3) === "3 Aufgaben",
                "German task plurals were not translated")

            AgendaTranslations.localeOverride = "it_IT"
            window.expect(AgendaTranslations.tr("Calendar") === "Calendario",
                "Italian calendar translation was not selected")
            window.expect(AgendaTranslations.tr("Due %1").arg("domani")
                    === "Scadenza: domani",
                "Italian placeholder translation was not preserved")
            window.expect(AgendaTranslations.tr(", %n event(s)", 1) === ", 1 evento"
                    && AgendaTranslations.tr(", %n event(s)", 2) === ", 2 eventi",
                "Italian event plurals were not translated")

            AgendaTranslations.localeOverride = "fr_FR"
            window.expect(AgendaTranslations.tr("Calendar") === "Calendar"
                    && AgendaTranslations.tr("%n task(s)", 2) === "2 tasks",
                "unsupported locales did not use the English fallback")
            AgendaTranslations.localeOverride = ""

            const taskPayload = {
                id: "", title: "New task", description: "", done: false,
                dueAt: googleDue.getTime(), createdAt: Date.now(),
                source: "gmail", externalId: "", account: "gmail-a"
            }
            calendarPane.submitCreatedEntry("task", taskPayload)
            window.expect(fakeStore.lastTaskPayload.account === "gmail-a",
                "task destination account was not preserved")
            window.expect(typeof fakeStore.lastTaskPayload.dueAt === "number",
                "task dueAt was not sent as epoch milliseconds")

            const eventPayload = {
                id: "", externalId: "", calendarId: "outlook-a",
                calendarName: "Microsoft · alex@outlook.com", title: "New event",
                description: "", startAt: new Date(2026, 8, 1, 9, 0).getTime(),
                endAt: new Date(2026, 8, 1, 10, 0).getTime(), allDay: false,
                readOnly: false
            }
            calendarPane.submitCreatedEntry("event", eventPayload)
            window.expect(fakeStore.lastEventPayload.calendarId === "outlook-a",
                "event destination calendar was not preserved")
            window.expect(typeof fakeStore.lastEventPayload.startAt === "number",
                "event startAt was not sent as epoch milliseconds")

            calendarPane.setTaskDone(fakeStore.tasks[0], true)
            window.expect(fakeStore.completedTaskId === "task-a:true",
                "task completion did not reach the store")

            calendarPane.requestDelete("task", fakeStore.tasks[0])
            calendarPane.confirmDelete()
            window.expect(fakeStore.deletedTaskId === "task-a",
                "task deletion did not reach the store")

            calendarPane.requestDelete("event", fakeStore.events[0])
            calendarPane.confirmDelete()
            window.expect(fakeStore.deletedEventId === "event-a",
                "event deletion did not reach the store")
            window.expect(fakeStore.reloads >= 5,
                "successful mutations did not refresh the agenda")
            Qt.exit(0)
        }
    }
}
