pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    readonly property string systemPalettePath: {
        const stateHome = String(Quickshell.env("XDG_STATE_HOME") || "").trim()
        const home = String(Quickshell.env("HOME") || "").trim()
        const stateRoot = stateHome !== "" ? stateHome : home !== "" ? home + "/.local/state" : ""
        return stateRoot !== "" ? stateRoot + "/quickshell/user/generated/colors.json" : ""
    }
    property var systemPalette: ({})
    readonly property bool followsSystemPalette: Object.keys(systemPalette).length > 0
    readonly property string themeMode: {
        const requested = String(AppSettings.themeMode || "").toLowerCase()
        return requested === "dark" || requested === "light" ? requested : "system"
    }
    readonly property bool followsSystemTheme: themeMode === "system"
    readonly property bool systemDarkMode: {
        const declared = systemPalette ? systemPalette.darkmode : undefined
        if (typeof declared === "boolean") return declared
        if (String(declared).toLowerCase() === "true") return true
        if (String(declared).toLowerCase() === "false") return false
        const background = systemPaletteValue("background")
        return background !== "" ? colorLuminance(background) < 0.5 : true
    }
    readonly property bool darkMode: followsSystemTheme
        ? systemDarkMode : themeMode === "dark"
    readonly property bool usesInversePalette: !followsSystemTheme
        && darkMode !== systemDarkMode

    readonly property color canvas: paletteColor("background", "#111318", "#f8f7fa")
    readonly property color surface: paletteColor("surface_container_low", "#181b21", "#ffffff")
    readonly property color surfaceRaised: paletteColor("surface_container", "#20242c", "#f0eef2")
    readonly property color surfaceHover: paletteColor("surface_container_high", "#292e37", "#e7e5e9")
    readonly property color surfaceSelected: paletteColor("secondary_container", "#263d57", "#dbe8f6")
    readonly property color border: paletteColor("outline", "#343a45", "#77777f")
    readonly property color borderSoft: paletteColor("outline_variant", "#292e37", "#c8c6cc")
    readonly property color text: paletteColor("on_surface", "#f1f3f6", "#1b1b1f")
    readonly property color textSecondary: paletteColor("on_surface_variant", "#b4bbc6", "#47464d")
    readonly property color textMuted: paletteColor("outline", "#858e9d", "#77777f")
    readonly property color accent: paletteColor("primary", "#66aaf0", "#315f88")
    readonly property color accentText: paletteColor("on_primary", "#111318", "#ffffff")
    readonly property color accentSoft: paletteColor("primary_container", "#1f4b73", "#d2e4f7")
    readonly property color accentSoftText: paletteColor("on_primary_container", "#f1f3f6", "#102f49")
    readonly property color danger: paletteColor("error", "#ff7078", "#ba1a1a")
    readonly property color dangerText: paletteColor("on_error", "#111318", "#ffffff")
    readonly property color warning: paletteColor("tertiary", "#f0bd6a", "#805600")
    readonly property color success: darkMode ? "#72d6a2" : "#256d4a"

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

    function systemPaletteValue(name) {
        const value = root.systemPalette ? root.systemPalette[name] : undefined
        return typeof value === "string" && value !== "" ? value : ""
    }

    function colorLuminance(value) {
        const color = Qt.darker(value, 1)
        const channel = function(component) {
            return component <= 0.04045 ? component / 12.92
                : Math.pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g)
            + 0.0722 * channel(color.b)
    }

    function contrastText(value) {
        return colorLuminance(value) > 0.42 ? "#171317" : "#fff8f7"
    }

    function inversePaletteColor(name, fallback) {
        const background = systemPaletteValue("inverse_surface") || fallback
        const foreground = systemPaletteValue("inverse_on_surface")
            || (root.darkMode ? "#f1f3f6" : "#1b1b1f")
        const primary = systemPaletteValue("inverse_primary")
            || (root.darkMode ? "#b7c9dd" : "#315f88")
        switch (name) {
        case "background":
        case "surface": return background
        case "surface_container_low":
            return root.darkMode ? Qt.lighter(background, 1.06) : Qt.darker(background, 1.015)
        case "surface_container":
            return root.darkMode ? Qt.lighter(background, 1.13) : Qt.darker(background, 1.04)
        case "surface_container_high":
            return root.darkMode ? Qt.lighter(background, 1.21) : Qt.darker(background, 1.075)
        case "secondary_container":
        case "primary_container":
            return root.darkMode ? Qt.darker(primary, 1.65) : Qt.lighter(primary, 2.05)
        case "outline":
            return root.darkMode ? Qt.darker(foreground, 1.55) : Qt.lighter(foreground, 2.2)
        case "outline_variant":
            return root.darkMode ? Qt.darker(foreground, 2.25) : Qt.lighter(foreground, 3.25)
        case "on_surface": return foreground
        case "on_surface_variant":
            return root.darkMode ? Qt.darker(foreground, 1.22) : Qt.lighter(foreground, 1.5)
        case "primary": return primary
        case "on_primary": return contrastText(primary)
        case "on_primary_container": return foreground
        case "error": return systemPaletteValue("error_container")
                || (root.darkMode ? "#ffb4ab" : "#ba1a1a")
        case "on_error": return contrastText(inversePaletteColor("error", fallback))
        case "tertiary": return systemPaletteValue("inverse_primary") || primary
        default: return fallback
        }
    }

    function paletteColor(name, darkFallback, lightFallback) {
        const fallback = root.darkMode ? darkFallback : lightFallback
        if (root.usesInversePalette) return inversePaletteColor(name, fallback)
        return systemPaletteValue(name) || fallback
    }

    function loadSystemPalette(text) {
        try {
            const parsed = JSON.parse(String(text || ""))
            root.systemPalette = parsed && typeof parsed === "object" ? parsed : ({})
        } catch (error) {
            console.warn("[QuickMail] Could not parse the system Material palette:", error)
            root.systemPalette = ({})
        }
    }

    property FileView systemPaletteFile: FileView {
        path: root.systemPalettePath
        watchChanges: true
        blockWrites: true
        onFileChanged: reload()
        onLoaded: root.loadSystemPalette(text())
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound)
                console.warn("[QuickMail] Could not load the system Material palette:", error)
            root.systemPalette = ({})
        }
    }

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
            error: "\ue000", chevron: "\ue5cc", account: "\ue853", settings: "\ue8b8",
            calendar: "\ue935", thread: "\ue0bf"
        }
        return icons[name] || "\ue88e"
    }
}
