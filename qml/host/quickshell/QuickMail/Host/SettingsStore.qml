import QtQuick
import Quickshell.Io as QuickshellIo

QuickshellIo.FileView {
    id: root

    property alias allowRemoteContent: settingsAdapter.allowRemoteContent
    property alias compactMessageList: settingsAdapter.compactMessageList
    property alias composeFormattingExpanded: settingsAdapter.composeFormattingExpanded
    property alias readerZoomPercent: settingsAdapter.readerZoomPercent
    property alias themeMode: settingsAdapter.themeMode
    property alias useThemeEmailColors: settingsAdapter.useThemeEmailColors
    property bool _ready: false
    readonly property bool ready: _ready
    readonly property string configHome: {
        const configured = String(PlatformBridge.env("XDG_CONFIG_HOME") || "")
        if (configured !== "") return configured
        const home = String(PlatformBridge.env("HOME") || "")
        return home !== "" ? home + "/.config" : ""
    }
    readonly property string settingsPath: configHome !== ""
        ? configHome + "/quickmail.json" : ""

    path: settingsPath
    watchChanges: false
    // The file is tiny. Completing each debounced write synchronously prevents
    // an older async snapshot from overwriting rapid preference changes.
    blockWrites: true

    onAdapterUpdated: {
        if (root._ready) writeTimer.restart()
    }
    onLoaded: root._ready = true
    onLoadFailed: error => {
        if (error === QuickshellIo.FileViewError.FileNotFound) {
            root._ready = true
            writeTimer.restart()
        } else {
            console.warn("QuickMail could not load its settings:", error)
        }
    }

    property Timer writeTimer: Timer {
        interval: 100
        repeat: false
        onTriggered: root.writeAdapter()
    }

    // The Quickshell qmltypes metadata leaves FileViewAdapter unqualified,
    // even though JsonAdapter is its declared subclass.
    // qmllint disable unresolved-type
    adapter: QuickshellIo.JsonAdapter {
        id: settingsAdapter

        property bool allowRemoteContent: true
        property bool compactMessageList: false
        property bool composeFormattingExpanded: true
        property int readerZoomPercent: 100
        property string themeMode: "system"
        property bool useThemeEmailColors: true
    }
}
