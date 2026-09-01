pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property alias allowRemoteContent: settingsAdapter.allowRemoteContent
    readonly property bool ready: internal.ready
    readonly property string configHome: {
        const configured = String(Quickshell.env("XDG_CONFIG_HOME") || "")
        if (configured !== "") return configured
        const home = String(Quickshell.env("HOME") || "")
        return home !== "" ? home + "/.config" : ""
    }
    readonly property string settingsPath: configHome !== ""
        ? configHome + "/quickmail.json" : ""

    QtObject {
        id: internal
        property bool ready: false
    }

    Timer {
        id: writeTimer
        interval: 100
        repeat: false
        onTriggered: settingsFile.writeAdapter()
    }

    FileView {
        id: settingsFile
        path: root.settingsPath
        watchChanges: false

        onAdapterUpdated: {
            if (internal.ready) writeTimer.restart()
        }
        onLoaded: internal.ready = true
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                internal.ready = true
                writeTimer.restart()
            } else {
                console.warn("QuickMail could not load its settings:", error)
            }
        }

        // The Quickshell qmltypes metadata leaves FileViewAdapter unqualified,
        // even though JsonAdapter is its declared subclass.
        // qmllint disable unresolved-type
        adapter: JsonAdapter {
            id: settingsAdapter

            // Keep the familiar mail-client behaviour by default. People who
            // prefer stricter privacy can disable it from the reader menu.
            property bool allowRemoteContent: true
        }
    }
}
