import QtQuick
import QtQuick.Controls
import ".."
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 420
    height: 700
    color: Theme.canvas
    property int stage: 0
    property int attempts: 0

    function expect(condition, message) {
        if (condition) return
        console.error("ATTACHMENT VIEWER TEST FAILED: " + message)
        Qt.exit(1)
    }

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        const itemChildren = item.children || []
        for (let index = 0; index < itemChildren.length; ++index) {
            const match = findNamed(itemChildren[index], name)
            if (match) return match
        }
        return null
    }

    AttachmentViewer {
        id: viewer
        parent: Overlay.overlay
    }

    PdfAttachmentView {
        id: pdfFixture
        visible: false
        width: 388
        height: 600
        source: "file:///usr/share/doc/qt6/examples/pdf/multipage/resources/test.pdf"
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            ++window.attempts
            if (window.attempts > 70) {
                window.expect(false, "timed out while loading attachment previews")
                return
            }

            if (window.stage === 0) {
                window.expect(viewer.previewKindFor("application/pdf", "report.bin", 10)
                        === "pdf", "PDF MIME type was not recognized")
                window.expect(viewer.previewKindFor("application/octet-stream", "photo.webp", 10)
                        === "image", "image extension was not recognized")
                window.expect(viewer.previewKindFor("audio/flac", "sound.bin", 10)
                        === "audio", "audio MIME type was not recognized")
                window.expect(viewer.previewKindFor("video/mp4", "clip.bin", 10)
                        === "video", "video MIME type was not recognized")
                window.expect(viewer.previewKindFor("application/octet-stream", "notes.docx", 10)
                        === "office", "office document was not recognized")
                window.expect(viewer.previewKindFor(
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        "spreadsheet", 10) === "office",
                    "office MIME type without an extension was not recognized")
                window.expect(viewer.previewKindFor("application/json", "payload.bin", 10)
                        === "text", "safe structured text was not recognized")
                window.expect(viewer.previewKindFor("application/octet-stream", "archive.zip", 10)
                        === "binary", "unknown binary did not receive a bounded reader")
                window.expect(!viewer.showFile({
                    path: "relative/file.pdf", filename: "file.pdf",
                    contentType: "application/pdf", size: 10
                }), "relative attachment path was accepted")

                const themePath = "/etc/hosts"
                window.expect(viewer.showFile({
                    path: themePath, filename: "hosts.txt",
                    contentType: "text/plain", size: 4096
                }), "text attachment did not open")
                window.stage = 1
                return
            }

            if (window.stage === 1) {
                if (viewer.textLoading || viewer.textContent === "") return
                window.expect(viewer.visible && viewer.previewKind === "text",
                    "text attachment did not use the in-app text reader")
                window.expect(viewer.textContent.toLowerCase().indexOf("localhost") >= 0,
                    "text reader did not load literal file content")
                viewer.close()
                window.stage = 2
                return
            }

            if (window.stage === 2) {
                if (viewer.visible) return
                const themePath = "/etc/hosts"
                window.expect(viewer.showFile({
                    path: themePath, filename: "opaque.bin",
                    contentType: "application/octet-stream", size: 4096
                }), "binary attachment did not open")
                window.stage = 3
                return
            }

            if (window.stage === 3) {
                if (viewer.binaryLoading || viewer.binaryContent === "") return
                window.expect(viewer.previewKind === "binary"
                        && viewer.binaryContent.indexOf("00000000") >= 0,
                    "bounded binary inspection did not produce a hex preview")
                viewer.close()
                window.stage = 4
                return
            }

            if (window.stage === 4) {
                if (viewer.visible || !pdfFixture.ready) return
                window.expect(pdfFixture.pageCount > 0,
                    "native PDF reader did not load a real multi-page document")
                window.expect(pdfFixture.compactToolbar,
                    "narrow PDF reader did not use its compact controls")
                const previousPage = window.findNamed(
                    pdfFixture, "pdfPreviousPageButton")
                const zoomOut = window.findNamed(pdfFixture, "pdfZoomOutButton")
                window.expect(previousPage !== null && zoomOut !== null,
                    "PDF navigation or zoom controls were not rendered")
                if (previousPage && zoomOut) {
                    const previousPosition = previousPage.mapToItem(pdfFixture, 0, 0)
                    const zoomPosition = zoomOut.mapToItem(pdfFixture, 0, 0)
                    window.expect(previousPosition.y + previousPage.height <= zoomPosition.y,
                        "compact PDF navigation and zoom controls overlap")
                }
                window.expect(viewer.showFile({
                    path: "/usr/share/doc/qt6/examples/pdf/multipage/resources/test.pdf",
                    filename: "test.pdf", contentType: "application/pdf", size: 1000
                }), "PDF attachment did not open")
                window.stage = 5
                return
            }

            if (window.stage === 5) {
                if (!viewer.contentReady) return
                window.expect(viewer.visible && viewer.pdfActive,
                    "PDF attachment did not use the in-app PDF reader")
                viewer.close()
                Qt.exit(0)
            }
        }
    }
}
