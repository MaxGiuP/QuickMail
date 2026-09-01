import QtQuick
import QtQuick.Controls
import ".."

ApplicationWindow {
    id: window

    visible: true
    width: 360
    height: 220
    color: Theme.canvas
    property bool checked: false

    function expect(condition, message) {
        if (condition) return
        console.error("THEME MODE TEST FAILED: " + message)
        Qt.exit(1)
    }

    function colorHex(value) {
        return String(value).toLowerCase()
    }

    Timer {
        interval: 20
        running: true
        repeat: true
        onTriggered: {
            if (!AppSettings.ready || window.checked) return
            window.checked = true
            window.expect(AppSettings.themeMode === "system"
                    && Theme.followsSystemTheme,
                "QuickMail did not default to the system theme")
            AppSettings.themeMode = "unsupported"
            window.expect(Theme.followsSystemTheme,
                "an invalid theme preference did not fall back to the system")
            AppSettings.themeMode = "system"

            Theme.loadSystemPalette('{"background":"#f7f2f0",'
                + '"on_surface":"#241f1e","primary":"#785651",'
                + '"on_primary":"#ffffff","inverse_surface":"#211d1c",'
                + '"inverse_on_surface":"#eee7e5",'
                + '"inverse_primary":"#e8bdb5","darkmode":false}')
            window.expect(!Theme.darkMode
                    && window.colorHex(Theme.canvas) === "#f7f2f0",
                "system light theme was not applied")

            AppSettings.themeMode = "dark"
            window.expect(Theme.darkMode && Theme.usesInversePalette
                    && window.colorHex(Theme.canvas) === "#211d1c"
                    && window.colorHex(Theme.accent) === "#e8bdb5",
                "dark override did not use inverse system palette roles")

            AppSettings.themeMode = "light"
            window.expect(!Theme.darkMode && !Theme.usesInversePalette
                    && window.colorHex(Theme.canvas) === "#f7f2f0",
                "light override did not select the light palette")

            AppSettings.themeMode = "system"
            window.expect(Theme.followsSystemTheme && !Theme.darkMode,
                "returning to the system theme did not restore automatic mode")
            Qt.quit()
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: window.expect(false, "settings never became ready")
    }
}
