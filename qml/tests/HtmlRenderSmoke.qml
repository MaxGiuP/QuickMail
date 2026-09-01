import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 360
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
            + "<table id='fixed-card' width='700' align='center' bgcolor='#ffffff' "
            + "style='width:700px;max-width:700px;min-width:999999999px;"
            + "height:999999999px;text-align:center;position:fixed'>"
            + "<tr><td>"
            + "Fixed-width desktop email content that remains reachable in a narrow reader"
            + "</td></tr></table>"
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

    HtmlMessageView {
        id: sanitizedFragmentRenderer
        visible: false
        width: 300
        html: "<div class='quickmail-body newsletter' "
            + "style='background-color:rgb(243, 242, 240) !important;"
            + "width:100%;text-align:center'>"
            + "Sanitized fragment</div>"
    }

    HtmlMessageView {
        id: stylesheetBackgroundRenderer
        visible: false
        width: 300
        html: "<style>.quickmail-body{background-color:#dbeafe}"
            + ".quickmail-body .card{background-color:#ef4444}</style>"
            + "<div class='quickmail-body'><div class='card'>Stylesheet background</div></div>"
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
                    .indexOf("body{background-color:#f4f1ea") >= 0,
                "message background color was not applied to the full document viewport")
            window.expect(renderer.renderedHtml.indexOf("font-weight:bold") >= 0,
                "safe inline styling was discarded")
            window.expect(renderer.renderedHtml.indexOf("width:700px") >= 0
                    && renderer.renderedHtml.indexOf("max-width:700px") >= 0
                    && renderer.renderedHtml.indexOf("text-align:center") >= 0,
                "resource-free fixed-width layout styling was discarded")
            window.expect(renderer.renderedHtml.indexOf("position:fixed") < 0,
                "positioning CSS survived the presentation allowlist")
            window.expect(renderer.renderedHtml.indexOf("999999999") < 0,
                "an unbounded sender-controlled CSS dimension survived")
            window.expect(renderer.isSafeCssDimension("700px")
                    && renderer.isSafeCssDimension("100%")
                    && !renderer.isSafeCssDimension("999999999px")
                    && !renderer.isSafeCssDimension("calc(100% + 1px)"),
                "CSS dimension bounds do not match the renderer policy")
            window.expect(renderer.decodeNumericEntities("&#65;&#x42;") === "AB"
                    && renderer.decodeNumericEntities("x&#x110000;y") === "x\ufffdy"
                    && renderer.decodeNumericEntities("&#xD800;") === "\ufffd"
                    && renderer.decodeNumericEntities("&#0;") === "\ufffd",
                "invalid numeric entities escaped Unicode scalar range checks")
            window.expect(renderer.renderedHtml
                    .indexOf("table{border-collapse:collapse;max-width:100%!important}") >= 0,
                "narrow-viewport table constraint was not appended")
            window.expect(Qt.colorEqual(renderer.effectivePageColor, "#f4f1ea"),
                "message body background did not cover the native renderer viewport")
            window.expect(Qt.colorEqual(sanitizedFragmentRenderer.effectivePageColor,
                    "#f3f2f0") && sanitizedFragmentRenderer.renderedHtml
                    .indexOf("body{background-color:#f3f2f0") >= 0,
                "sanitized body-wrapper background did not fill the document viewport")
            window.expect(Qt.colorEqual(stylesheetBackgroundRenderer.effectivePageColor,
                    "#dbeafe") && stylesheetBackgroundRenderer.renderedHtml
                    .indexOf("body{background-color:#dbeafe") >= 0,
                "stylesheet-defined body background did not fill the document viewport")
            window.expect(renderer.parsedCssColor("inherit") === null
                    && renderer.parsedCssColor("initial") === null,
                "non-color CSS keywords were accepted as viewport colors")
            window.expect(renderer.hasHorizontalOverflow
                    && renderer.renderedContentWidth > renderer.width
                    && renderer.horizontalScrollAvailable,
                "fixed-width overflow was clipped instead of exposed by the horizontal viewport ("
                    + renderer.renderedContentWidth + " <= " + renderer.width + ")")
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
