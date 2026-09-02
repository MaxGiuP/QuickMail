pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io as QuickshellIo

QtObject {
    id: root

    property bool _systemAnimationsEnabled: true
    property bool _systemAnimationsPreferenceSeen: false
    property string _systemPaletteText: ""
    readonly property bool systemAnimationsEnabled: _systemAnimationsEnabled
    readonly property string systemPaletteText: _systemPaletteText
    readonly property string systemPalettePath: {
        const stateHome = String(env("XDG_STATE_HOME") || "").trim()
        const home = String(env("HOME") || "").trim()
        const stateRoot = stateHome !== "" ? stateHome
            : home !== "" ? home + "/.local/state" : ""
        return stateRoot !== ""
            ? stateRoot + "/quickshell/user/generated/colors.json" : ""
    }

    function env(name) {
        return Quickshell.env(String(name))
    }

    function execDetached(args) {
        Quickshell.execDetached(args)
    }

    function applySystemAnimationsPreference(value) {
        const normalized = value === undefined || value === null
            ? "" : String(value).trim().toLowerCase()
        if (normalized === "true" || normalized.endsWith(": true")) {
            _systemAnimationsEnabled = true
            _systemAnimationsPreferenceSeen = true
        } else if (normalized === "false" || normalized.endsWith(": false")) {
            _systemAnimationsEnabled = false
            _systemAnimationsPreferenceSeen = true
        }
    }

    property QuickshellIo.Process animationsReadProcess: QuickshellIo.Process {
        command: ["gsettings", "get", "org.gnome.desktop.interface",
            "enable-animations"]
        running: true
        stdout: QuickshellIo.StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applySystemAnimationsPreference(text)
        }
        stderr: QuickshellIo.StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && !root._systemAnimationsPreferenceSeen)
                root._systemAnimationsEnabled = true
        }
    }

    property QuickshellIo.Process animationsMonitorProcess: QuickshellIo.Process {
        command: ["gsettings", "monitor", "org.gnome.desktop.interface",
            "enable-animations"]
        running: true
        stdout: QuickshellIo.SplitParser {
            splitMarker: "\n"
            onRead: data => root.applySystemAnimationsPreference(data)
        }
        stderr: QuickshellIo.StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && !root._systemAnimationsPreferenceSeen)
                root._systemAnimationsEnabled = true
        }
    }

    property QuickshellIo.FileView systemPaletteFile: QuickshellIo.FileView {
        path: root.systemPalettePath
        watchChanges: true
        blockWrites: true
        onFileChanged: reload()
        onLoaded: root._systemPaletteText = text()
        onLoadFailed: error => {
            if (error !== QuickshellIo.FileViewError.FileNotFound)
                console.warn("[QuickMail] Could not load the system Material palette:", error)
            root._systemPaletteText = ""
        }
    }
}
