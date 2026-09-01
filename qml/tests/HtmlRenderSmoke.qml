import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 640
    height: 480
    color: "#ffffff"
    property int externalRequests: 0
    property string externalUrl: ""
    property bool failed: false

    function expect(condition, message) {
        if (condition) return
        failed = true
        console.error("HTML RENDER TEST FAILED: " + message)
        Qt.exit(1)
    }

    HtmlMessageView {
        id: renderer
        anchors.fill: parent
        anchors.margins: 12
        allowRemoteContent: false
        foregroundColor: "#202124"
        pageColor: "#ffffff"
        html: "<!doctype html><html><head>"
            + "<style>.card{background-color:#123456;color:#fedcba;"
            + "background-image:url(http://tracker.invalid/background.png)}</style>"
            + "</head><body bgcolor='#f4f1ea'><div id='card' class='card' "
            + "style='padding:12px;font-weight:bold'>Styled mail</div>"
            + "<img src='http://tracker.invalid/pixel.png'>"
            + "<a id='safe-link' href='https://example.com/message'>Open</a>"
            + "<script>document.body.textContent='script ran'</script>"
            + "<span onclick='document.body.textContent=\"event ran\"'>event</span>"
            + "</body></html>"

        onExternalLinkRequested: url => {
            ++window.externalRequests
            window.externalUrl = String(url)
        }
    }

    Timer {
        interval: 50
        running: true
        repeat: false
        onTriggered: {
            window.expect(renderer.renderedHtml.indexOf("background-color:#123456") >= 0,
                "message background color was discarded")
            window.expect(renderer.renderedHtml.indexOf("background-color:#f4f1ea") >= 0,
                "legacy body background color was overridden by the theme")
            window.expect(renderer.renderedHtml
                    .indexOf("body{background-color:#ffffff") >= 0,
                "theme color was encoded incorrectly for CSS")
            window.expect(renderer.renderedHtml.indexOf("font-weight:bold") >= 0,
                "safe inline styling was discarded")
            window.expect(renderer.renderedHtml.indexOf("tracker.invalid") < 0,
                "blocked remote content survived document preparation")
            window.expect(renderer.renderedHtml.indexOf("<script") < 0
                    && renderer.renderedHtml.indexOf("onclick") < 0,
                "executable markup survived document preparation")
            window.expect(renderer.sanitizeImageSourcesForPolicy(
                    "<img src='https://images.example.test/mail.png'>", true)
                    .indexOf("https://images.example.test/mail.png") >= 0,
                "enabled remote image was discarded")
            renderer.requestExternalOpen("javascript:bad()")
            renderer.requestExternalOpen("file:///tmp/private")
            renderer.requestExternalOpen("https://example.com/message")
            window.expect(window.externalRequests === 1,
                "link scheme guard did not intercept exactly one safe target")
            window.expect(window.externalUrl === "https://example.com/message",
                "intercepted link target changed")
            Qt.quit()
        }
    }
}
