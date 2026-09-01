pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import ".."

Popup {
    id: root

    objectName: "attachmentViewer"
    modal: true
    dim: true
    focus: true
    padding: 0
    closePolicy: Popup.CloseOnEscape
    width: parent ? Math.min(1120, Math.max(360, parent.width - 32)) : 900
    height: parent ? Math.min(860, Math.max(480, parent.height - 32)) : 700
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0

    property string sourcePath: ""
    property url sourceUrl: ""
    property string filename: "Attachment"
    property string contentType: "application/octet-stream"
    property double fileSize: 0
    property string previewKind: "binary"
    property string previewError: ""
    property string textContent: ""
    property string binaryContent: ""
    property bool textLoading: false
    property bool binaryLoading: false
    property bool wrapText: true
    property real imageZoom: 1
    property int requestGeneration: 0
    property bool officeConverting: false
    property bool officeCleanupPending: false
    property string officeInputPath: ""
    property string officePdfPath: ""
    property url convertedPdfUrl: ""
    readonly property int maximumTextBytes: 2 * 1024 * 1024
    readonly property int maximumTextCharacters: 1000000
    readonly property int binaryPreviewBytes: 65536
    readonly property bool compactLayout: width < 640
    readonly property bool pdfActive: previewKind === "pdf"
        || (previewKind === "office" && String(convertedPdfUrl) !== "")
    readonly property bool contentReady: contentLoader.status === Loader.Ready
    readonly property var officeExtensions: [
        "doc", "docx", "dot", "dotx", "odt", "ott", "rtf",
        "xls", "xlsx", "xlsm", "xlt", "xltx", "ods", "ots",
        "ppt", "pptx", "pptm", "pot", "potx", "odp", "otp",
        "wpd", "pages", "numbers", "key", "epub"
    ]

    signal saveRequested(string sourcePath, string filename)

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusLarge
        border.width: 1
        border.color: Theme.border
    }

    function safeFilename(value) {
        let result = String(value || "Attachment")
            .replace(/[\u0000-\u001f\\/]/g, "_").trim()
        if (result === "" || result === "." || result === "..") result = "Attachment"
        return result.substring(0, 160)
    }

    function normalizedContentType(value) {
        return String(value || "application/octet-stream")
            .split(";")[0].trim().toLowerCase()
    }

    function fileExtension(value) {
        const match = String(value || "").toLowerCase().match(/\.([a-z0-9]{1,12})$/)
        return match ? match[1] : ""
    }

    function localFileUrl(path) {
        const value = String(path || "")
        if (value === "" || value[0] !== "/" || value.indexOf("\u0000") >= 0)
            return ""
        return "file://" + value.split("/").map(function(part) {
            return encodeURIComponent(part)
        }).join("/")
    }

    function isOfficeExtension(extension) {
        return officeExtensions.indexOf(String(extension || "").toLowerCase()) >= 0
    }

    function officeExtensionFor(typeValue, filenameValue) {
        const extension = fileExtension(filenameValue)
        if (isOfficeExtension(extension)) return extension
        switch (normalizedContentType(typeValue)) {
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "docx"
        case "application/vnd.oasis.opendocument.text": return "odt"
        case "application/rtf": return "rtf"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
            return "xlsx"
        case "application/vnd.oasis.opendocument.spreadsheet": return "ods"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return "pptx"
        case "application/vnd.oasis.opendocument.presentation": return "odp"
        case "application/epub+zip": return "epub"
        case "application/vnd.apple.pages": return "pages"
        case "application/vnd.apple.numbers": return "numbers"
        case "application/vnd.apple.keynote": return "key"
        default: return ""
        }
    }

    function isTextExtension(extension) {
        return [
            "txt", "md", "markdown", "log", "csv", "tsv", "json", "jsonl",
            "xml", "html", "htm", "css", "js", "mjs", "ts", "tsx", "jsx",
            "qml", "py", "rs", "c", "h", "cpp", "hpp", "java", "kt", "go",
            "rb", "php", "sh", "bash", "zsh", "fish", "ps1", "sql", "yaml",
            "yml", "toml", "ini", "cfg", "conf", "diff", "patch", "tex", "svg",
            "eml", "ics", "vcf"
        ].indexOf(String(extension || "").toLowerCase()) >= 0
    }

    function isRasterImageType(type, extension) {
        const allowedTypes = [
            "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp",
            "image/tiff", "image/avif", "image/heif", "image/heic",
            "image/x-portable-pixmap", "image/x-portable-graymap"
        ]
        const allowedExtensions = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff",
            "avif", "heif", "heic", "ppm", "pgm"
        ]
        return allowedTypes.indexOf(type) >= 0 || allowedExtensions.indexOf(extension) >= 0
    }

    function previewKindFor(typeValue, filenameValue, sizeValue) {
        const type = normalizedContentType(typeValue)
        const extension = fileExtension(filenameValue)
        const size = Math.max(0, Number(sizeValue || 0))
        if (type === "application/pdf" || extension === "pdf") return "pdf"
        if (isRasterImageType(type, extension)) return "image"
        if (type.startsWith("audio/") || ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].indexOf(extension) >= 0)
            return "audio"
        if (type.startsWith("video/") || ["mp4", "m4v", "webm", "mkv", "mov", "avi", "ogv"].indexOf(extension) >= 0)
            return "video"
        if (officeExtensionFor(type, filenameValue) !== "") return "office"
        if ((type.startsWith("text/") || isTextExtension(extension)
                || [
                    "application/json", "application/ld+json", "application/xml",
                    "application/javascript", "application/x-javascript",
                    "application/x-sh", "application/yaml", "application/toml",
                    "application/sql", "image/svg+xml"
                ].indexOf(type) >= 0) && size <= maximumTextBytes)
            return "text"
        return "binary"
    }

    function humanSize(value) {
        const bytes = Math.max(0, Number(value || 0))
        if (bytes < 1024) return Math.round(bytes) + " B"
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(bytes < 10240 ? 1 : 0) + " KB"
        return (bytes / (1024 * 1024)).toFixed(1) + " MB"
    }

    function kindLabel() {
        switch (previewKind) {
        case "pdf": return "PDF document"
        case "image": return "Image"
        case "text": return "Text / code"
        case "audio": return "Audio"
        case "video": return "Video"
        case "office": return officeConverting ? "Preparing document preview…" : "Document preview"
        default: return "Binary inspection · first 64 KB"
        }
    }

    function isDaemonCachePath(path) {
        const value = String(path || "")
        const slash = value.lastIndexOf("/")
        if (slash <= 0) return false
        const basename = value.substring(slash + 1)
        return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(basename)
    }

    function showFile(result) {
        if (officeCopyProcess.running || officeConvertProcess.running) return false
        const path = String(result && result.path || "")
        const url = localFileUrl(path)
        if (url === "") return false

        ++requestGeneration
        sourcePath = path
        sourceUrl = url
        filename = safeFilename(result && result.filename)
        contentType = normalizedContentType(result && (result.contentType
            || result.content_type))
        fileSize = Math.max(0, Number(result && result.size || 0))
        previewError = ""
        textContent = ""
        binaryContent = ""
        imageZoom = 1
        convertedPdfUrl = ""
        officeConverting = false
        officeCleanupPending = false
        previewKind = previewKindFor(contentType, filename, fileSize)
        open()

        if (previewKind === "text") {
            textLoading = true
            Qt.callLater(function() { textFile.reload() })
        } else if (previewKind === "binary") {
            Qt.callLater(root.startBinaryPreview)
        } else if (previewKind === "office") {
            Qt.callLater(root.startOfficePreview)
        }
        return true
    }

    function startBinaryPreview(preserveError) {
        if (!visible || previewKind !== "binary" || sourcePath === "") return
        binaryLoading = true
        binaryContent = ""
        if (preserveError !== true) previewError = ""
        binaryTimeout.restart()
        hexProcess.request = requestGeneration
        hexProcess.command = ["xxd", "-g", "1", "-l", String(binaryPreviewBytes),
            "--", sourcePath]
        hexProcess.running = true
    }

    function officePreviewFailed(message) {
        officeTimeout.stop()
        officeConverting = false
        previewError = String(message || "QuickMail could not prepare this document preview.")
        previewKind = "binary"
        startBinaryPreview(true)
    }

    function startOfficePreview() {
        if (!visible || previewKind !== "office" || sourcePath === "") return
        const extension = officeExtensionFor(contentType, filename)
        if (extension === "" || !isDaemonCachePath(sourcePath)) {
            officePreviewFailed("This document cannot be converted safely in place.")
            return
        }
        officeConverting = true
        previewError = ""
        officeTimeout.restart()
        officeInputPath = sourcePath + ".quickmail-preview." + extension
        officePdfPath = sourcePath + ".quickmail-preview.pdf"
        officeCopyProcess.request = requestGeneration
        officeCopyProcess.command = ["install", "-m", "0600", "--", sourcePath,
            officeInputPath]
        officeCopyProcess.running = true
    }

    function copyOfficePreviewFinished(exitCode, request) {
        if (request !== requestGeneration || previewKind !== "office") {
            officeCleanupPending = true
            cleanupOfficeArtifacts()
            return
        }
        if (exitCode !== 0) {
            officePreviewFailed("QuickMail could not stage this document for preview.")
            return
        }
        const directory = sourcePath.substring(0, sourcePath.lastIndexOf("/"))
        officeConvertProcess.request = request
        officeConvertProcess.command = [
            "libreoffice", "--headless", "--safe-mode", "--nologo", "--nodefault",
            "--norestore", "--nolockcheck", "--convert-to", "pdf", "--outdir",
            directory, officeInputPath
        ]
        officeConvertProcess.running = true
    }

    function convertOfficePreviewFinished(exitCode, request) {
        if (request !== requestGeneration || !visible || previewKind !== "office") {
            officeCleanupPending = true
            cleanupOfficeArtifacts()
            return
        }
        officeConverting = false
        officeTimeout.stop()
        if (exitCode !== 0) {
            officePreviewFailed("This office document could not be converted to a safe PDF preview.")
            return
        }
        convertedPdfUrl = localFileUrl(officePdfPath)
        if (String(convertedPdfUrl) === "")
            officePreviewFailed("The converted document path was invalid.")
    }

    function cleanupOfficeArtifacts() {
        if (officeCopyProcess.running || officeConvertProcess.running) {
            officeCleanupPending = true
            return
        }
        if (!isDaemonCachePath(sourcePath) || (officeInputPath === "" && officePdfPath === ""))
            return
        const paths = ["rm", "-f", "--"]
        if (officeInputPath !== "") paths.push(officeInputPath)
        if (officePdfPath !== "") paths.push(officePdfPath)
        officeInputPath = ""
        officePdfPath = ""
        officeCleanupPending = false
        cleanupProcess.command = paths
        cleanupProcess.running = true
    }

    function openExternally() {
        if (String(sourceUrl) === "" || !Qt.openUrlExternally(sourceUrl))
            previewError = "No external application is available for this file."
    }

    onClosed: {
        ++requestGeneration
        if (hexProcess.running) hexProcess.running = false
        if (officeCopyProcess.running || officeConvertProcess.running)
            officeCleanupPending = true
        textLoading = false
        binaryLoading = false
        binaryTimeout.stop()
        officeTimeout.stop()
        cleanupOfficeArtifacts()
    }

    FileView {
        id: textFile
        path: root.previewKind === "text" ? root.sourcePath : ""
        preload: root.previewKind === "text" && root.sourcePath !== ""
        watchChanges: false
        printErrors: false
        onLoaded: {
            if (root.previewKind !== "text" || path !== root.sourcePath) return
            const loadedText = text()
            root.textContent = loadedText.length > root.maximumTextCharacters
                ? loadedText.substring(0, root.maximumTextCharacters)
                    + "\n\n[Preview truncated at 1,000,000 characters]"
                : loadedText
            root.textLoading = false
        }
        onLoadFailed: {
            if (root.previewKind !== "text") return
            root.textLoading = false
            root.previewError = "QuickMail could not read this text attachment."
        }
    }

    Process {
        id: hexProcess
        property int request: 0
        stdout: StdioCollector { id: hexOutput; waitForEnd: true }
        stderr: StdioCollector { id: hexError; waitForEnd: true }
        onExited: (exitCode, exitStatus) => {
            if (request !== root.requestGeneration || root.previewKind !== "binary") return
            binaryTimeout.stop()
            root.binaryLoading = false
            if (exitCode === 0 && hexOutput.text !== "") {
                root.binaryContent = hexOutput.text
            } else {
                root.previewError = "QuickMail could not inspect this binary file."
                    + (hexError.text !== "" ? " " + hexError.text.trim() : "")
            }
        }
    }

    Process {
        id: officeCopyProcess
        property int request: 0
        onExited: (exitCode, exitStatus) => {
            root.copyOfficePreviewFinished(exitCode, request)
            if (root.officeCleanupPending) root.cleanupOfficeArtifacts()
        }
    }

    Process {
        id: officeConvertProcess
        property int request: 0
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: (exitCode, exitStatus) => {
            root.convertOfficePreviewFinished(exitCode, request)
            if (root.officeCleanupPending) root.cleanupOfficeArtifacts()
        }
    }

    Process { id: cleanupProcess }

    Timer {
        id: binaryTimeout
        interval: 5000
        repeat: false
        onTriggered: {
            if (!root.binaryLoading) return
            if (hexProcess.running) hexProcess.running = false
            root.binaryLoading = false
            root.previewError = "Binary inspection is unavailable on this system."
        }
    }

    Timer {
        id: officeTimeout
        interval: 30000
        repeat: false
        onTriggered: {
            if (!root.officeConverting) return
            if (officeCopyProcess.running) officeCopyProcess.running = false
            if (officeConvertProcess.running) officeConvertProcess.running = false
            root.officePreviewFailed("The office preview took too long to prepare.")
        }
    }

    contentItem: ColumnLayout {
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.compactLayout ? 104 : 64
            color: Theme.surfaceRaised
            radius: Theme.radiusLarge

            GridLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                columns: root.compactLayout ? 1 : 2
                rows: root.compactLayout ? 2 : 1
                columnSpacing: 10
                rowSpacing: 4

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        Layout.fillWidth: true
                        text: root.filename
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        elide: Text.ElideMiddle
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.kindLabel() + " · " + root.humanSize(root.fileSize)
                        textFormat: Text.PlainText
                        color: Theme.textMuted
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                RowLayout {
                    Layout.alignment: root.compactLayout ? Qt.AlignLeft : Qt.AlignRight
                    spacing: 2

                    Button {
                        visible: root.previewKind === "text" || root.previewKind === "binary"
                        flat: true
                        checkable: true
                        checked: root.wrapText
                        text: "Wrap"
                        onClicked: root.wrapText = checked
                    }
                    IconButton {
                        iconName: "external"
                        tip: "Open in another application (Ctrl+O)"
                        onClicked: root.openExternally()
                    }
                    IconButton {
                        iconName: "save"
                        tip: "Save a copy (Ctrl+S)"
                        onClicked: root.saveRequested(root.sourcePath, root.filename)
                    }
                    IconButton {
                        id: closeButton
                        objectName: "attachmentViewerCloseButton"
                        iconName: "close"
                        tip: "Close (Esc)"
                        onClicked: root.close()
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.previewError !== "" ? 38 : 0
            visible: root.previewError !== ""
            color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.13)
            border.width: 1
            border.color: Theme.warning

            Text {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                text: root.previewError
                textFormat: Text.PlainText
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: 12
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }

        Loader {
            id: contentLoader
            objectName: "attachmentContentLoader"
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: root.visible
            sourceComponent: root.pdfActive ? pdfComponent
                : root.previewKind === "image" ? imageComponent
                : root.previewKind === "text" ? textComponent
                : root.previewKind === "audio" || root.previewKind === "video"
                    ? mediaComponent
                : root.previewKind === "office" ? officeComponent : binaryComponent
        }
    }

    Component {
        id: pdfComponent
        PdfAttachmentView {
            source: root.previewKind === "office" ? root.convertedPdfUrl : root.sourceUrl
        }
    }

    Component {
        id: imageComponent
        Item {
            Flickable {
                id: imageFlick
                anchors.fill: parent
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                contentWidth: Math.max(width, previewImage.width)
                contentHeight: Math.max(height, previewImage.height)
                ScrollBar.horizontal: ScrollBar {}
                ScrollBar.vertical: ScrollBar {}

                Image {
                    id: previewImage
                    width: imageFlick.width * root.imageZoom
                    height: imageFlick.height * root.imageZoom
                    source: root.sourceUrl
                    asynchronous: true
                    cache: false
                    autoTransform: true
                    fillMode: Image.PreserveAspectFit
                    sourceSize.width: Math.min(4096, Math.max(1, width))
                    sourceSize.height: Math.min(4096, Math.max(1, height))
                }
            }

            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 14
                spacing: 4

                IconButton {
                    iconName: "zoomOut"
                    tip: "Zoom out"
                    enabled: root.imageZoom > 0.5
                    onClicked: root.imageZoom = Math.max(0.5, root.imageZoom / 1.25)
                }
                Button {
                    text: Math.round(root.imageZoom * 100) + "%"
                    flat: true
                    onClicked: root.imageZoom = 1
                }
                IconButton {
                    iconName: "zoomIn"
                    tip: "Zoom in"
                    enabled: root.imageZoom < 8
                    onClicked: root.imageZoom = Math.min(8, root.imageZoom * 1.25)
                }
            }

            BusyIndicator {
                anchors.centerIn: parent
                running: previewImage.status === Image.Loading
                visible: running
            }
            EmptyState {
                anchors.fill: parent
                visible: previewImage.status === Image.Error
                iconName: "image"
                title: "Image preview unavailable"
                detail: "This image format could not be decoded safely."
            }
        }
    }

    Component {
        id: textComponent
        Item {
            BusyIndicator {
                anchors.centerIn: parent
                running: root.textLoading
                visible: running
            }
            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                visible: !root.textLoading
                ScrollBar.horizontal.policy: root.wrapText
                    ? ScrollBar.AlwaysOff : ScrollBar.AsNeeded
                TextArea {
                    objectName: "attachmentTextPreview"
                    text: root.textContent
                    textFormat: Text.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: root.wrapText ? TextEdit.WrapAnywhere : TextEdit.NoWrap
                    color: Theme.text
                    selectionColor: Theme.accentSoft
                    selectedTextColor: Theme.text
                    font.family: "monospace"
                    font.pixelSize: 13
                    background: null
                }
            }
        }
    }

    Component {
        id: mediaComponent
        MediaAttachmentView {
            source: root.sourceUrl
            video: root.previewKind === "video"
        }
    }

    Component {
        id: officeComponent
        Item {
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 440)
                spacing: 14
                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: root.officeConverting
                }
                Text {
                    Layout.fillWidth: true
                    text: "Preparing a read-only PDF preview…"
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 17
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    Layout.fillWidth: true
                    text: "The original attachment is not modified."
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }

    Component {
        id: binaryComponent
        Item {
            BusyIndicator {
                anchors.centerIn: parent
                running: root.binaryLoading
                visible: running
            }
            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                visible: !root.binaryLoading
                ScrollBar.horizontal.policy: root.wrapText
                    ? ScrollBar.AlwaysOff : ScrollBar.AsNeeded
                TextArea {
                    objectName: "attachmentBinaryPreview"
                    text: root.binaryContent !== "" ? root.binaryContent
                        : "No readable preview is available for this file."
                    textFormat: Text.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: root.wrapText ? TextEdit.WrapAnywhere : TextEdit.NoWrap
                    color: Theme.text
                    selectionColor: Theme.accentSoft
                    selectedTextColor: Theme.text
                    font.family: "monospace"
                    font.pixelSize: 12
                    background: null
                }
            }
        }
    }

    Shortcut {
        sequences: [StandardKey.Save]
        enabled: root.visible && root.sourcePath !== ""
        onActivated: root.saveRequested(root.sourcePath, root.filename)
    }
    Shortcut {
        sequences: [StandardKey.Open]
        enabled: root.visible && String(root.sourceUrl) !== ""
        onActivated: root.openExternally()
    }
    Shortcut {
        sequences: [StandardKey.ZoomIn]
        enabled: root.visible && root.previewKind === "image" && root.imageZoom < 8
        onActivated: root.imageZoom = Math.min(8, root.imageZoom * 1.25)
    }
    Shortcut {
        sequences: [StandardKey.ZoomOut]
        enabled: root.visible && root.previewKind === "image" && root.imageZoom > 0.5
        onActivated: root.imageZoom = Math.max(0.5, root.imageZoom / 1.25)
    }
    Shortcut {
        sequence: "Ctrl+0"
        enabled: root.visible && root.previewKind === "image"
        onActivated: root.imageZoom = 1
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.visible
        onActivated: root.close()
    }
}
