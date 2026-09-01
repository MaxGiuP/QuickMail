import QtQuick
import QtQuick.Controls
import ".."

TextArea {
    id: root

    property bool internalUpdate: false
    readonly property string bodyText: plainBodyText()
    readonly property string bodyHtml: richBodyHtml()
    signal userEdited()

    textFormat: TextEdit.RichText
    color: Theme.text
    selectionColor: Theme.accentSoft
    selectedTextColor: Theme.text
    font.family: Theme.fontFamily
    font.pixelSize: 14
    wrapMode: TextEdit.Wrap
    selectByMouse: true
    background: null

    function escapeHtml(value) {
        return String(value || "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
    }

    function plainTextToHtml(value) {
        return escapeHtml(String(value || "")
            .replace(/\r\n?/g, "\n")
            .replace(/[\u2028\u2029]/g, "\n"))
            .replace(/\n/g, "<br>")
    }

    function stripTypingMarkers(value) {
        return String(value || "")
            .replace(/\u200b/g, "")
            .replace(/&#(?:8203|x200b);/gi, "")
    }

    function plainBodyText() {
        return stripTypingMarkers(getText(0, length))
            .replace(/[\u2028\u2029]/g, "\n")
    }

    function richBodyHtml() {
        return plainBodyText() === "" ? "" : stripTypingMarkers(text)
    }

    function loadMessageBody(plainText, htmlText) {
        internalUpdate = true
        const html = String(htmlText || "")
        text = html !== "" ? html : plainTextToHtml(plainText)
        cursorPosition = length
        deselect()
        internalUpdate = false
    }

    function selectedHtmlFragment() {
        const formatted = getFormattedText(selectionStart, selectionEnd)
        const startMarker = "<!--StartFragment-->"
        const endMarker = "<!--EndFragment-->"
        const start = formatted.indexOf(startMarker)
        const end = formatted.indexOf(endMarker)
        if (start >= 0 && end >= start + startMarker.length)
            return formatted.substring(start + startMarker.length, end)
        return plainTextToHtml(selectedText)
    }

    function replaceSelectionWithHtml(html, logicalLength) {
        const start = selectionStart
        const end = selectionEnd
        internalUpdate = true
        remove(start, end)
        insert(start, html)
        select(start, start + logicalLength)
        internalUpdate = false
        userEdited()
        Qt.callLater(function() { root.forceActiveFocus() })
    }

    function applyInlineStyle(style) {
        const hasSelection = selectionStart !== selectionEnd
        const fragment = hasSelection ? selectedHtmlFragment() : "&#8203;"
        const logicalLength = hasSelection ? selectionEnd - selectionStart : 1
        replaceSelectionWithHtml("<span style=\"" + style + "\">"
            + fragment + "</span>", logicalLength)
        return true
    }

    function applyBold() {
        return applyInlineStyle("font-weight:700")
    }

    function applyItalic() {
        return applyInlineStyle("font-style:italic")
    }

    function applyUnderline() {
        return applyInlineStyle("text-decoration:underline")
    }

    function applyStrikeout() {
        return applyInlineStyle("text-decoration:line-through")
    }

    function applyFontSize(pixelSize) {
        const size = Math.round(Number(pixelSize))
        if (!Number.isFinite(size) || size < 10 || size > 32) return false
        return applyInlineStyle("font-size:" + size + "px")
    }

    function applyTextColor(value) {
        const colorValue = String(value || "").toLowerCase()
        if (!/^#[0-9a-f]{6}$/.test(colorValue)) return false
        return applyInlineStyle("color:" + colorValue)
    }

    function applyHighlight(value) {
        const colorValue = String(value || "").toLowerCase()
        if (!/^#[0-9a-f]{6}$/.test(colorValue)) return false
        return applyInlineStyle("background-color:" + colorValue
            + ";color:#202124")
    }

    function clearSelectionFormatting() {
        if (selectionStart === selectionEnd) return false
        const plain = selectedText
        replaceSelectionWithHtml(plainTextToHtml(plain), plain.length)
        return true
    }

    onTextChanged: {
        if (!internalUpdate && activeFocus) userEdited()
    }
}
