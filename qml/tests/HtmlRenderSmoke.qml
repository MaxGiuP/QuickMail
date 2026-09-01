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
            + "background-image:url(http://tracker.invalid/background.png)}"
            + "a{color:#cc0000}</style>"
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

    HtmlMessageView {
        id: authoredPairRenderer
        visible: false
        width: 300
        useThemeColors: false
        html: "<style>.quickmail-body{background:#dbeafe;color:#123456}</style>"
            + "<div class='quickmail-body'><table bgcolor='#ffffff'><tr><td>"
            + "<h3>Default dark text</h3></td></tr></table></div>"
    }

    HtmlMessageView {
        id: alphaRenderer
        visible: false
        width: 300
        useThemeColors: false
        html: "<div class='quickmail-body' style='background:#11223344'>Alpha</div>"
    }

    HtmlMessageView {
        id: darkThemeRenderer
        visible: false
        width: 300
        trustedSanitizedHtml: true
        foregroundColor: "#f1f3f6"
        mutedColor: "#858e9d"
        linkColor: "#66aaf0"
        pageColor: "#181b21"
        html: "<style>.quickmail-body{background-color:#fafafa !important;"
            + "color:#111111 !important}.card{background:#eeeeee;color:#171717}</style>"
            + "<div class='quickmail-body' style='background:#fefefe!important;"
            + "color:#121212!important;padding:8px'><table bgcolor='#ededed'>"
            + "<tr><td><font color='#131313'>Dark-mode mail</font></td></tr></table>"
            + "<a style='color:#141414' href='https://example.com/dark'>Link</a>"
            + "<pre>literal color='literal-token' style='layout-token'</pre></div>"
    }

    HtmlMessageView {
        id: lightThemeRenderer
        visible: false
        width: 300
        trustedSanitizedHtml: true
        foregroundColor: "#202124"
        linkColor: "#2563eb"
        pageColor: "#f7f7f8"
        html: "<style>.quickmail-body{background:#101114;color:#f5f5f5}</style>"
            + "<div class='quickmail-body' bgcolor='#111214' color='#f4f4f4'>"
            + "Light-mode mail</div>"
    }

    HtmlMessageView {
        id: invalidPaletteRenderer
        visible: false
        width: 300
        foregroundColor: "#777777"
        linkColor: "#777777"
        pageColor: "#777777"
        html: "<p>Readable fallback</p>"
    }

    Timer {
        interval: 50
        running: true
        repeat: false
        onTriggered: {
            window.expect(renderer.renderedHtml.indexOf("background-color:#123456") < 0
                    && renderer.renderedHtml.indexOf("color:#fedcba") < 0,
                "sender card colors overrode the light theme palette")
            window.expect(renderer.renderedHtml.indexOf("background-color:#f4f1ea") < 0,
                "legacy body background color overrode the light theme")
            window.expect(renderer.renderedHtml
                    .indexOf("body{background-color:#ffffff;color:#202124") >= 0,
                "light theme colors were not applied to the document viewport")
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
            window.expect(Qt.colorEqual(renderer.effectivePageColor, "#ffffff"),
                "light theme background did not cover the native renderer viewport")
            window.expect(Qt.colorEqual(sanitizedFragmentRenderer.effectivePageColor,
                    "#ffffff") && sanitizedFragmentRenderer.renderedHtml
                    .indexOf("rgb(243, 242, 240)") < 0,
                "sanitized body-wrapper color overrode the light theme")
            window.expect(Qt.colorEqual(stylesheetBackgroundRenderer.effectivePageColor,
                    "#ffffff") && stylesheetBackgroundRenderer.renderedHtml
                    .indexOf("#dbeafe") < 0
                    && stylesheetBackgroundRenderer.renderedHtml.indexOf("#ef4444") < 0,
                "stylesheet colors overrode the light theme")
            window.expect(Qt.colorEqual(authoredPairRenderer.effectivePageColor, "#dbeafe")
                    && Qt.colorEqual(authoredPairRenderer.effectiveForegroundColor, "#123456")
                    && authoredPairRenderer.renderedHtml
                        .indexOf("background-color:#dbeafe") >= 0,
                "authored solid background shorthand or root foreground was lost")
            window.expect(renderer.renderedHtml.indexOf("a{color:#2563eb}") >= 0
                    && renderer.renderedHtml.indexOf("#cc0000") < 0,
                "sender link colour overrode the light theme")
            window.expect(Qt.colorEqual(renderer.effectiveForegroundColor, "#202124"),
                "light theme foreground was not used")
            window.expect(Qt.colorEqual(darkThemeRenderer.effectivePageColor, "#181b21")
                    && Qt.colorEqual(darkThemeRenderer.effectiveForegroundColor, "#f1f3f6")
                    && darkThemeRenderer.renderedHtml
                        .indexOf(":root{color-scheme:dark}") >= 0
                    && darkThemeRenderer.renderedHtml
                        .indexOf("body{background-color:#181b21;color:#f1f3f6") >= 0,
                "dark theme canvas and foreground were not applied together")
            window.expect(darkThemeRenderer.renderedHtml.indexOf("#fafafa") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#111111") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#eeeeee") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#171717") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#fefefe") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#121212") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#ededed") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#131313") < 0
                    && darkThemeRenderer.renderedHtml.indexOf("#141414") < 0,
                "sender colors survived dark-theme normalization")
            window.expect(darkThemeRenderer.renderedHtml.indexOf("padding:8px") >= 0,
                "theme normalization discarded non-color sender layout")
            window.expect(darkThemeRenderer.renderedHtml
                    .indexOf("literal color='literal-token' style='layout-token'") >= 0,
                "literal color-like prose was mistaken for HTML attributes")
            window.expect(Qt.colorEqual(lightThemeRenderer.effectivePageColor, "#f7f7f8")
                    && Qt.colorEqual(lightThemeRenderer.effectiveForegroundColor, "#202124")
                    && lightThemeRenderer.renderedHtml
                        .indexOf(":root{color-scheme:light}") >= 0
                    && lightThemeRenderer.renderedHtml.indexOf("#101114") < 0
                    && lightThemeRenderer.renderedHtml.indexOf("#f5f5f5") < 0
                    && lightThemeRenderer.renderedHtml.indexOf("#111214") < 0
                    && lightThemeRenderer.renderedHtml.indexOf("#f4f4f4") < 0,
                "light theme palette did not replace dark sender colors")
            window.expect(invalidPaletteRenderer.contrastRatio(
                        invalidPaletteRenderer.paintedColor(
                            invalidPaletteRenderer.effectiveForegroundColor,
                            invalidPaletteRenderer.effectivePageColor),
                        invalidPaletteRenderer.effectivePageColor) >= 4.5
                    && Qt.colorEqual(invalidPaletteRenderer.effectiveLinkColor,
                        invalidPaletteRenderer.effectiveForegroundColor),
                "invalid custom palette did not receive a readable text fallback")
            window.expect(alphaRenderer.parsedCssColor("#11223344").r < 0.08
                    && alphaRenderer.parsedCssColor("#11223344").b > 0.19
                    && alphaRenderer.parsedCssColor("#11223344").a > 0.26
                    && alphaRenderer.parsedCssColor("#11223344").a < 0.28,
                "CSS alpha-last hex channels were interpreted as Qt ARGB")
            window.expect(alphaRenderer.isPureCssColor("#123456")
                    && alphaRenderer.isPureCssColor("rgb(1, 2, 3)")
                    && !alphaRenderer.isPureCssColor("url(https://tracker.invalid/bg)" )
                    && !alphaRenderer.isPureCssColor("linear-gradient(red, blue)"),
                "solid-background shorthand accepted a resource or gradient")
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
