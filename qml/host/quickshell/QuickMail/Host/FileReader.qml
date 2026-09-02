import QtQuick
import Quickshell.Io as QuickshellIo

QtObject {
    id: root

    property string path: ""
    property bool preload: false
    property string _content: ""
    readonly property string content: _content

    signal loaded()
    signal loadFailed(string error)

    function reload() {
        file.reload()
    }

    property QuickshellIo.FileView file: QuickshellIo.FileView {
        path: root.path
        preload: root.preload
        watchChanges: false
        printErrors: false
        onLoaded: {
            root._content = text()
            root.loaded()
        }
        onLoadFailed: error => {
            root._content = ""
            root.loadFailed(QuickshellIo.FileViewError.toString(error))
        }
    }
}
