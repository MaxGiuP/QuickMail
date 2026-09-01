import QtQuick

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
        "color": true,
        "float": true,
        "font": true,
        "font-family": true,
        "font-kerning": true,
        "font-size": true,
        "font-style": true,
        "font-variant": true,
        "font-weight": true,
        "line-height": true,
        "margin-bottom": true,
        "margin-left": true,
        "margin-right": true,
        "margin-top": true,
        "padding": true,
        "padding-bottom": true,
        "padding-left": true,
        "padding-right": true,
        "padding-top": true,
        "text-decoration": true,
        "text-indent": true,
        "text-transform": true,
        "vertical-align": true,
        "white-space": true,
        "word-spacing": true
    })
    readonly property string renderedHtml: documentForMessage()
    readonly property real rendererHeight: Math.max(160, nativeRenderer.contentHeight + 8)

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
                return isFinite(number) ? String.fromCodePoint(number) : ""
            })
    }

    function isSafeStyleProperty(name) {
        return safeStyleProperties[String(name || "").toLowerCase()] === true
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

    function documentForMessage() {
        const source = normalizeBodyBackground(
            sanitizeImageSources(removeExecutableMarkup(html)))
        const head = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<style type=\"text/css\">"
            + ":root{color-scheme:only light}html,body{margin:0;padding:0;max-width:100%;}"
            + "body{background-color:" + cssColor(pageColor)
            + ";color:" + cssColor(foregroundColor)
            + ";font-family:sans-serif;font-size:15px;line-height:1.55;overflow-wrap:anywhere}"
            + "img{max-width:100%;height:auto}a{color:" + cssColor(linkColor) + "}"
            + "blockquote{margin-left:12px;padding-left:12px;border-left:3px solid "
            + cssColor(mutedColor) + "}table{border-collapse:collapse;max-width:100%}"
            + "td,th{padding:4px}</style>"
        if (/<head(?:\s[^>]*)?>/i.test(source))
            return source.replace(/<head(?:\s[^>]*)?>/i,
                function(match) { return match + head })
        if (/<html(?:\s[^>]*)?>/i.test(source))
            return source.replace(/<html(?:\s[^>]*)?>/i,
                function(match) { return match + "<head>" + head + "</head>" })
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

    TextEdit {
        id: nativeRenderer
        anchors.fill: parent
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
        selectedTextColor: root.pageColor
        font.family: "sans-serif"
        font.pixelSize: 15
        onLinkActivated: link => root.requestExternalOpen(link)
    }

    onImplicitHeightChanged: preferredHeightChanged(implicitHeight)
}
