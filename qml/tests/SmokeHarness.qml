import QtQuick
import Quickshell

ShellRoot {
    Loader {
        source: "tests/" + String(Quickshell.env("QUICKMAIL_SMOKE") || "") + ".qml"
        onStatusChanged: {
            if (status === Loader.Error) {
                console.error("QML SMOKE TEST FAILED: could not load " + source)
                Qt.exit(1)
            }
        }
    }
}
