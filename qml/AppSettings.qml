pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property alias allowRemoteContent: settingsAdapter.allowRemoteContent
    property alias compactMessageList: settingsAdapter.compactMessageList
    property alias composeFormattingExpanded: settingsAdapter.composeFormattingExpanded
    property alias readerZoomPercent: settingsAdapter.readerZoomPercent
    property alias useThemeEmailColors: settingsAdapter.useThemeEmailColors
    readonly property bool ready: internal.ready
    // Loading a persisted opt-out is asynchronous. Keep every network-backed
    // renderer fail-closed until that choice is known.
    readonly property bool effectiveAllowRemoteContent: ready && allowRemoteContent
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
        // The file is tiny. Completing each debounced write synchronously
        // prevents an older async snapshot from overwriting rapid changes
        // such as successive Ctrl+wheel zoom steps.
        blockWrites: true

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
            // Compact rows are optional so message previews remain visible by
            // default while denser inboxes are one click away.
            property bool compactMessageList: false
            // The composer keeps its richer controls visible by default, but
            // the compact state is remembered when screen space matters more.
            property bool composeFormattingExpanded: true
            // Reader zoom is shared across messages so switching mail never
            // unexpectedly changes the user's preferred reading size.
            property int readerZoomPercent: 100
            // Matching the application palette is the safe, readable default;
            // original sender colors remain available from QuickMail settings.
            property bool useThemeEmailColors: true
        }
    }
}
