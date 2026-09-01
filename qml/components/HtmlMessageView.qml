import QtQuick
import QtQuick.Controls as Controls

Item {
    id: root

    property string html: ""
    property bool allowRemoteContent: true
    property color foregroundColor: "#202124"
    property color mutedColor: "#6b7280"
    property color linkColor: "#2563eb"
    property color pageColor: "#ffffff"
    property bool failed: false
    signal externalLinkRequested(url url)
    signal renderingFailed()
    signal preferredHeightChanged(real height)

    readonly property var safeStyleProperties: ({
        "background-color": true,
        "border": true,
        "border-bottom": true,
        "border-bottom-color": true,
        "border-bottom-style": true,
        "border-bottom-width": true,
        "border-collapse": true,
        "border-color": true,
        "border-left": true,
        "border-left-color": true,
        "border-left-style": true,
        "border-left-width": true,
        "border-right": true,
        "border-right-color": true,
        "border-right-style": true,
        "border-right-width": true,
        "border-style": true,
        "border-top": true,
        "border-top-color": true,
        "border-top-style": true,
        "border-top-width": true,
        "border-width": true,
        "box-sizing": true,
        "color": true,
        "direction": true,
        "display": true,
        "float": true,
        "font": true,
        "font-family": true,
        "font-kerning": true,
        "font-size": true,
        "font-style": true,
        "font-variant": true,
        "font-weight": true,
        "height": true,
        "letter-spacing": true,
        "line-height": true,
        "margin-bottom": true,
        "margin-left": true,
        "margin-right": true,
        "margin-top": true,
        "max-height": true,
        "max-width": true,
        "min-height": true,
        "min-width": true,
        "object-fit": true,
        "overflow": true,
        "overflow-wrap": true,
        "overflow-x": true,
        "overflow-y": true,
        "padding": true,
        "padding-bottom": true,
        "padding-left": true,
        "padding-right": true,
        "padding-top": true,
        "table-layout": true,
        "text-align": true,
        "text-decoration": true,
        "text-indent": true,
        "text-overflow": true,
        "text-transform": true,
        "vertical-align": true,
        "white-space": true,
        "width": true,
        "word-break": true,
        "word-wrap": true,
        "word-spacing": true
    })
    readonly property var boundedDimensionStyleProperties: ({
        "height": true,
        "max-height": true,
        "max-width": true,
        "min-height": true,
        "min-width": true,
        "width": true
    })
    readonly property string safeNamedColors: "aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray grey green greenyellow honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan teal thistle tomato transparent turquoise violet wheat white whitesmoke yellow yellowgreen"
    readonly property string renderedHtml: documentForMessage()
    readonly property color effectivePageColor: messageBackgroundColor()
    readonly property real rendererHeight: Math.max(160, nativeRenderer.contentHeight + 8)
    readonly property real renderedContentWidth: Math.max(width, nativeRenderer.contentWidth)
    readonly property bool hasHorizontalOverflow: nativeRenderer.contentWidth > width + 1
    readonly property bool horizontalScrollAvailable: horizontalViewport.interactive
        && horizontalViewport.contentWidth > horizontalViewport.width + 1

    implicitHeight: rendererHeight

    function cssColor(value) {
        // QColor's string representation can include alpha first, while CSS
        // expects alpha last. Building the value explicitly avoids swapping
        // channels for non-opaque theme colors.
        function channel(component) {
            const byte = Math.max(0, Math.min(255,
                Math.round(Number(component) * 255)))
            return byte.toString(16).padStart(2, "0")
        }
        if (value && value.r !== undefined) {
            const rgb = "#" + channel(value.r) + channel(value.g) + channel(value.b)
            return Number(value.a) < 1 ? rgb + channel(value.a) : rgb
        }
        const text = String(value || "")
        return /^#[0-9a-f]{3,8}$/i.test(text) ? text : "#000000"
    }

    function decodeNumericEntities(value) {
        return String(value || "").replace(
            /&#(?:x([0-9a-f]+)|([0-9]+));?/gi,
            function(_match, hex, decimal) {
                const number = parseInt(hex || decimal,
                    hex ? 16 : 10)
                // String.fromCodePoint throws outside the Unicode scalar
                // range. HTML also treats null and surrogate references as
                // replacement characters, so keep malformed sender markup
                // from aborting the renderer or the CSS safety pass.
                if (!isFinite(number) || number <= 0 || number > 0x10ffff
                        || (number >= 0xd800 && number <= 0xdfff))
                    return "\ufffd"
                return String.fromCodePoint(number)
            })
    }

    function isSafeStyleProperty(name) {
        return safeStyleProperties[String(name || "").toLowerCase()] === true
    }

    function isSafeCssDimension(value) {
        let normalized = String(value || "").trim().toLowerCase()
        normalized = normalized.replace(/\s*!important\s*$/i, "").trim()
        if (["auto", "none", "inherit", "initial", "unset", "revert",
                "min-content", "max-content", "fit-content", "stretch"]
                .indexOf(normalized) >= 0)
            return true

        const match = normalized.match(
            /^((?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))(%|px|q|vw|vh|vmin|vmax|em|rem|lh|rlh|pc|ex|ch|cap|ic|pt|in|cm|mm)?$/i)
        if (!match) return false
        const number = Number(match[1])
        if (!isFinite(number) || number < 0) return false
        const unit = String(match[2] || "").toLowerCase()
        const maximum = unit === "%" || unit === "vw" || unit === "vh"
                || unit === "vmin" || unit === "vmax" ? 1000
            : unit === "em" || unit === "rem" || unit === "lh"
                || unit === "rlh" || unit === "pc" ? 1024
            : unit === "ex" || unit === "ch" || unit === "cap"
                || unit === "ic" ? 2048
            : unit === "pt" ? 12288
            : unit === "in" ? 170
            : unit === "cm" ? 430
            : unit === "mm" ? 4300 : 16384
        return number <= maximum
    }

    function sanitizeStyleDeclarations(value) {
        const declarations = String(value || "").split(";")
        const kept = []
        for (let index = 0; index < declarations.length; ++index) {
            const declaration = declarations[index]
            const colon = declaration.indexOf(":")
            if (colon <= 0) continue
            const property = declaration.substring(0, colon).trim().toLowerCase()
            const styleValue = declaration.substring(colon + 1).trim()
            if (!isSafeStyleProperty(property) || styleValue === "") continue

            // Decode numeric entities before testing. Backslashes are rejected
            // too, so CSS escapes cannot disguise a resource-bearing value.
            const inspected = decodeNumericEntities(styleValue).toLowerCase()
            if (inspected.indexOf("\\") >= 0
                    || /(?:url|image-set|cross-fade|expression)\s*\(/i.test(inspected)
                    || inspected.indexOf("@import") >= 0
                    || inspected.indexOf("behavior:") >= 0)
                continue
            if (boundedDimensionStyleProperties[property] === true
                    && !isSafeCssDimension(styleValue))
                continue
            kept.push(property + ":" + styleValue)
        }
        return kept.join(";")
    }

    function sanitizeStyleMarkup(source) {
        let result = String(source || "")
        result = result.replace(
            /\s+style\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi,
            function(_match, doubleQuoted, singleQuoted, bare) {
                const cleaned = sanitizeStyleDeclarations(
                    doubleQuoted !== undefined ? doubleQuoted
                        : (singleQuoted !== undefined ? singleQuoted : bare))
                if (cleaned === "") return ""
                return " style=\"" + cleaned.replace(/\"/g, "&quot;") + "\""
            })
        result = result.replace(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi,
            function(_match, css) {
                const withoutComments = String(css || "")
                    .replace(/\/\*[\s\S]*?\*\//g, "")
                const rules = []
                withoutComments.replace(/([^{}]+)\{([^{}]*)\}/g,
                    function(_rule, selector, declarations) {
                        const cleanSelector = String(selector || "").trim()
                        const cleanDeclarations = sanitizeStyleDeclarations(declarations)
                        if (cleanSelector !== "" && cleanDeclarations !== ""
                                && cleanSelector.indexOf("@") < 0
                                && /^[a-z0-9_#.*,:>+~\[\]()=\"'\-\s]+$/i.test(cleanSelector))
                            rules.push(cleanSelector + "{" + cleanDeclarations + "}")
                        return ""
                    })
                return rules.length > 0 ? "<style>" + rules.join("") + "</style>" : ""
            })
        return result
    }

    function removeExecutableMarkup(source) {
        // The daemon performs the authoritative HTML5 allowlist pass. This
        // second, deliberately conservative pass keeps direct component use
        // safe and makes the non-browser execution boundary explicit.
        let result = String(source || "")
            .replace(/<(script|iframe|frameset|object|embed|applet|svg|math|video|audio|canvas)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
            .replace(/<(script|iframe|frame|frameset|object|embed|applet|svg|math|video|audio|canvas|source|track)\b[^>]*\/?\s*>/gi, "")
            .replace(/<\/?(?:form|button|input|textarea|select|option)\b[^>]*>/gi, "")
            .replace(/<(?:meta|base|link)\b[^>]*\/?\s*>/gi, "")
            .replace(/\s+on[a-z0-9_-]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
            .replace(/\s+(?:srcset|lowsrc|dynsrc|poster|background|action|formaction|ping|download|codebase|manifest|xlink:href)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
        return sanitizeStyleMarkup(result)
    }

    function sanitizeImageSourcesForPolicy(source, remoteAllowed) {
        const filtered = String(source || "")
        if (!remoteAllowed)
            return filtered.replace(/<img\b[^>]*\/?\s*>/gi, "")

        return filtered.replace(/<img\b([^>]*)\/?\s*>/gi,
            function(_tag, attributes) {
                let safeAttributes = String(attributes || "")
                safeAttributes = safeAttributes.replace(
                    /\s+src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi,
                    function(_attribute, doubleQuoted, singleQuoted, bare) {
                        const candidate = String(doubleQuoted !== undefined
                            ? doubleQuoted : (singleQuoted !== undefined
                                ? singleQuoted : bare)).trim()
                        if (!/^https?:\/\//i.test(candidate)) return ""
                        return " src=\"" + candidate.replace(/\"/g, "&quot;") + "\""
                    })
                return "<img" + safeAttributes + ">"
            })
    }

    function sanitizeImageSources(source) {
        return sanitizeImageSourcesForPolicy(source, allowRemoteContent)
    }

    function normalizeBodyBackground(source) {
        return String(source || "").replace(/<body\b([^>]*)>/i,
            function(tag, attributes) {
                const match = String(attributes || "").match(
                    /\s+bgcolor\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
                if (!match) return tag
                const color = String(match[1] !== undefined ? match[1]
                    : (match[2] !== undefined ? match[2] : match[3])).trim()
                if (!/^(?:#[0-9a-f]{3,8}|[a-z][a-z-]{0,31})$/i.test(color))
                    return tag
                if (/\bbackground-color\s*:/i.test(attributes)) return tag
                if (/\sstyle\s*=\s*"/i.test(attributes))
                    return tag.replace(/\sstyle\s*=\s*"([^"]*)"/i,
                        function(_style, value) {
                            return " style=\"" + value + ";background-color:" + color + "\""
                        })
                if (/\sstyle\s*=\s*'/i.test(attributes))
                    return tag.replace(/\sstyle\s*=\s*'([^']*)'/i,
                        function(_style, value) {
                            return " style='" + value + ";background-color:" + color + "'"
                        })
                return "<body" + attributes + " style=\"background-color:"
                    + color + "\">"
            })
    }

    function parsedCssColor(value) {
        const text = String(value || "").trim()
        if (/^#[0-9a-f]{3,8}$/i.test(text)) return Qt.color(text)
        if (/^[a-z]+$/i.test(text)
                && (" " + safeNamedColors + " ").indexOf(
                    " " + text.toLowerCase() + " ") >= 0)
            return Qt.color(text)
        const match = text.match(/^rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s*,\s*([0-9.]+))?\s*\)$/i)
        if (!match) return null
        const red = Math.max(0, Math.min(255, Number(match[1]))) / 255
        const green = Math.max(0, Math.min(255, Number(match[2]))) / 255
        const blue = Math.max(0, Math.min(255, Number(match[3]))) / 255
        const alpha = match[4] === undefined
            ? 1 : Math.max(0, Math.min(1, Number(match[4])))
        if (![red, green, blue, alpha].every(isFinite)) return null
        return Qt.rgba(red, green, blue, alpha)
    }

    function selectorTargetsMessageBody(value) {
        const selectors = String(value || "").split(",")
        for (let index = 0; index < selectors.length; ++index) {
            const compounds = selectors[index].trim().split(/\s+|[>+~]/)
                .filter(function(part) { return part !== "" })
            if (compounds.length === 0) continue
            const target = compounds[compounds.length - 1].toLowerCase()
            // A body wrapper mentioned only as an ancestor must not color the
            // whole viewport (for example `.quickmail-body .card`).
            if (/^body(?:[#.:\[].*)?$/.test(target)
                    || /^(?:[a-z][a-z0-9_-]*)?\.quickmail-body(?:[#.:\[].*)?$/.test(target))
                return true
        }
        return false
    }

    function stylesheetBodyBackground(source) {
        const stylePattern = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi
        let selected = null
        let styleMatch
        while ((styleMatch = stylePattern.exec(String(source || ""))) !== null) {
            const css = String(styleMatch[1] || "")
                .replace(/\/\*[\s\S]*?\*\//g, "")
            const rulePattern = /([^{}]+)\{([^{}]*)\}/g
            let rule
            while ((rule = rulePattern.exec(css)) !== null) {
                if (!selectorTargetsMessageBody(rule[1])) continue
                const declarations = String(rule[2] || "").split(";")
                for (let index = 0; index < declarations.length; ++index) {
                    const declaration = declarations[index]
                    const colon = declaration.indexOf(":")
                    if (colon <= 0 || declaration.substring(0, colon).trim()
                            .toLowerCase() !== "background-color")
                        continue
                    const value = declaration.substring(colon + 1)
                        .replace(/\s*!important\s*$/i, "").trim()
                    const parsed = parsedCssColor(value)
                    if (parsed !== null) selected = parsed
                }
            }
        }
        return selected
    }

    function messageBackgroundColor() {
        const source = String(html || "")
        const stylesheetColor = stylesheetBodyBackground(source)
        const body = source.match(/<body\b([^>]*)>/i)
        const quickmailBody = source.match(
            /<div\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bquickmail-body\b[^"]*"|'[^']*\bquickmail-body\b[^']*'))([^>]*)>/i)
        const candidates = []
        if (body) candidates.push(body[1])
        if (quickmailBody) candidates.push(quickmailBody[1])
        for (let index = 0; index < candidates.length; ++index) {
            const attributes = candidates[index]
            const style = attributes.match(
                /\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)')/i)
            if (style) {
                const color = String(style[1] !== undefined ? style[1] : style[2])
                    .match(/(?:^|;)\s*background-color\s*:\s*([^;]+)/i)
                if (color) {
                    const parsed = parsedCssColor(String(color[1])
                        .replace(/\s*!important\s*$/i, "").trim())
                    if (parsed !== null) return parsed
                }
            }
            const legacy = attributes.match(
                /\sbgcolor\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
            if (legacy) {
                const parsed = parsedCssColor(legacy[1] !== undefined ? legacy[1]
                    : (legacy[2] !== undefined ? legacy[2] : legacy[3]))
                if (parsed !== null) return parsed
            }
        }
        return stylesheetColor !== null ? stylesheetColor : pageColor
    }

    function documentForMessage() {
        const source = normalizeBodyBackground(
            sanitizeImageSources(removeExecutableMarkup(html)))
        const head = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<style type=\"text/css\">"
            + ":root{color-scheme:only light}"
            + "html,body{margin:0;padding:0;width:100%;max-width:100%;box-sizing:border-box;}"
            + "body{background-color:" + cssColor(effectivePageColor)
            + ";color:" + cssColor(foregroundColor)
            + ";font-family:sans-serif;font-size:15px;line-height:1.55;"
            + "overflow-wrap:anywhere;overflow-x:auto}"
            + ".quickmail-body{display:block;width:100%;max-width:100%;min-width:0;"
            + "box-sizing:border-box;overflow-x:auto}"
            + "img{max-width:100%!important;height:auto}a{color:"
            + cssColor(linkColor) + "}"
            + "blockquote{margin-left:12px;padding-left:12px;border-left:3px solid "
            + cssColor(mutedColor) + "}"
            + "table{border-collapse:collapse;max-width:100%!important}"
            + "td,th{padding:4px;max-width:100%;overflow-wrap:anywhere;word-break:break-word}"
            + "pre{max-width:100%;white-space:pre-wrap;overflow-wrap:anywhere}</style>"
        if (/<head(?:\s[^>]*)?>/i.test(source)) {
            if (/<\/head\s*>/i.test(source))
                return source.replace(/<\/head\s*>/i,
                    function(match) { return head + match })
            return source.replace(/<head(?:\s[^>]*)?>/i,
                function(match) { return match + head })
        }
        if (/<html(?:\s[^>]*)?>/i.test(source))
            return source.replace(/<html(?:\s[^>]*)?>/i,
                function(match) { return match + "<head>" + head + "</head>" })
        if (/<body(?:\s[^>]*)?>/i.test(source))
            return "<!doctype html><html><head>" + head + "</head>" + source
                + "</html>"
        return "<!doctype html><html><head>" + head + "</head><body>" + source
            + "</body></html>"
    }

    function requestExternalOpen(url) {
        const value = String(url || "")
        const separator = value.indexOf(":")
        const scheme = separator > 0 ? value.substring(0, separator).toLowerCase() : ""
        if (scheme === "http" || scheme === "https" || scheme === "mailto")
            externalLinkRequested(url)
    }

    Rectangle {
        anchors.fill: parent
        color: root.effectivePageColor
    }

    Flickable {
        id: horizontalViewport
        anchors.fill: parent
        contentWidth: Math.max(width, nativeRenderer.contentWidth)
        contentHeight: height
        clip: true
        interactive: contentWidth > width + 1
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        Controls.ScrollBar.horizontal: Controls.ScrollBar {
            policy: Controls.ScrollBar.AsNeeded
        }

        TextEdit {
            id: nativeRenderer
            width: horizontalViewport.width
            height: horizontalViewport.height
            baseUrl: "about:blank"
            text: root.renderedHtml
            textFormat: TextEdit.RichText
            wrapMode: TextEdit.Wrap
            readOnly: true
            selectByMouse: true
            activeFocusOnPress: true
            persistentSelection: true
            color: root.foregroundColor
            selectionColor: root.linkColor
            selectedTextColor: root.effectivePageColor
            font.family: "sans-serif"
            font.pixelSize: 15
            onLinkActivated: link => root.requestExternalOpen(link)
        }
    }

    onHtmlChanged: horizontalViewport.contentX = 0
    onImplicitHeightChanged: preferredHeightChanged(implicitHeight)
}
