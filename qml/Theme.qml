pragma Singleton

import QtQuick

QtObject {
    readonly property color canvas: "#111318"
    readonly property color surface: "#181b21"
    readonly property color surfaceRaised: "#20242c"
    readonly property color surfaceHover: "#292e37"
    readonly property color surfaceSelected: "#263d57"
    readonly property color border: "#343a45"
    readonly property color borderSoft: "#292e37"
    readonly property color text: "#f1f3f6"
    readonly property color textSecondary: "#b4bbc6"
    readonly property color textMuted: "#858e9d"
    readonly property color accent: "#66aaf0"
    readonly property color accentSoft: "#1f4b73"
    readonly property color danger: "#ff7078"
    readonly property color warning: "#f0bd6a"
    readonly property color success: "#72d6a2"

    readonly property string fontFamily: "Inter"
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property int radiusSmall: 6
    readonly property int radius: 10
    readonly property int radiusLarge: 16
    readonly property int space1: 4
    readonly property int space2: 8
    readonly property int space3: 12
    readonly property int space4: 16
    readonly property int space5: 20
    readonly property int space6: 24
    readonly property int rowHeight: 64

    function initials(name) {
        const words = String(name || "?").trim().split(/\s+/)
        if (words.length === 0 || words[0] === "") return "?"
        if (words.length === 1) return words[0].slice(0, 2).toUpperCase()
        return String(words[0][0] + words[words.length - 1][0]).toUpperCase()
    }

    function icon(name) {
        const icons = {
            menu: "\ue5d2", mail: "\ue158", inbox: "\ue156", unread: "\ue0be",
            star: "\ue838", starOutline: "\ue83a", sent: "\ue163", archive: "\ue149",
            trash: "\ue872", drafts: "\ue151", folder: "\ue2c7", search: "\ue8b6",
            compose: "\ue3c9", refresh: "\ue5d5", more: "\ue5d4", back: "\ue5c4",
            reply: "\ue15e", replyAll: "\ue15f", forward: "\ue154", close: "\ue5cd",
            send: "\ue163", attach: "\ue226", check: "\ue5ca", offline: "\ue2c1",
            error: "\ue000", chevron: "\ue5cc", account: "\ue853", settings: "\ue8b8"
        }
        return icons[name] || "\ue88e"
    }
}
