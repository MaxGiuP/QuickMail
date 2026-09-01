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

    readonly property string renderedHtml: documentForMessage()
    implicitHeight: Math.max(160, richText.contentHeight + 8)

    function cssColor(color) {
        return String(color)
    }

    function removeExecutableMarkup(source) {
        // QTextDocument does not execute browser JavaScript, but stripping
        // executable/interactive markup makes that boundary explicit and
        // prevents unsupported elements from leaking confusing text.
        return String(source || "")
            .replace(/<(script|style|iframe|object|embed|applet)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
            .replace(/<(script|style|iframe|object|embed|applet)\b[^>]*\/?\s*>/gi, "")
            .replace(/<\/?(?:form|button|input|textarea|select|option)\b[^>]*>/gi, "")
            .replace(/<(?:meta|base|link)\b[^>]*\/?\s*>/gi, "")
            .replace(/\s+on[a-z0-9_-]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
    }

    function blockRemoteResources(source) {
        let filtered = String(source || "")
        // The daemon has already allowlist-sanitized resource URLs. Removing
        // every image/resource carrier here makes the privacy toggle
        // independent of URL spelling or entity encoding.
        filtered = filtered.replace(/<img\b[^>]*\/?\s*>/gi, "")
        filtered = filtered.replace(
            /\s+(?:src|srcset|background|poster)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi,
            "")
        return filtered
    }

    function documentForMessage() {
        let source = removeExecutableMarkup(html)
        if (!allowRemoteContent) source = blockRemoteResources(source)
        const head = "<style type=\"text/css\">"
            + "body{margin:0;padding:0;background-color:" + cssColor(pageColor)
            + ";color:" + cssColor(foregroundColor)
            + ";font-family:sans-serif;font-size:15px;line-height:155%}"
            + "a{color:" + cssColor(linkColor) + "}"
            + "blockquote{margin-left:12px;padding-left:12px;border-left:3px solid "
            + cssColor(mutedColor) + "}table{border-collapse:collapse}td,th{padding:4px}"
            + "</style>"
        if (/<head(?:\s[^>]*)?>/i.test(source))
            return source.replace(/<head(?:\s[^>]*)?>/i,
                function(match) { return match + head })
        if (/<html(?:\s[^>]*)?>/i.test(source))
            return source.replace(/<html(?:\s[^>]*)?>/i,
                function(match) { return match + "<head>" + head + "</head>" })
        return "<!doctype html><html><head>" + head + "</head><body>" + source + "</body></html>"
    }

    function requestExternalOpen(url) {
        const value = String(url || "")
        const separator = value.indexOf(":")
        const scheme = separator > 0 ? value.substring(0, separator).toLowerCase() : ""
        if (scheme === "http" || scheme === "https" || scheme === "mailto")
            externalLinkRequested(url)
    }

    TextEdit {
        id: richText
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
