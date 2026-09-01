import QtQuick
import QtQuick.Effects
import ".."

Item {
    id: root

    property string displayName: ""
    property string address: ""
    property string avatarUrl: ""
    property bool allowRemoteContent: true
    property color backgroundColor: Theme.accentSoft
    property color foregroundColor: Theme.accent

    property int candidateIndex: 0
    readonly property string normalizedAddress: normalizeAddress(address)
    readonly property string normalizedAvatarUrl: safeHttpsUrl(avatarUrl)
    readonly property string senderDomain: domainFromAddress(normalizedAddress)
    // Gravatar's transparent fallback keeps the local initials visible and
    // avoids a warning-producing 404 for most senders.
    readonly property string gravatarUrl: normalizedAddress === "" ? ""
        : "https://www.gravatar.com/avatar/" + Qt.md5(normalizedAddress)
            + "?d=blank&s=128"
    readonly property string brandIconUrl: isPersonalMailboxDomain(senderDomain)
        || senderDomain === "" ? ""
            : "https://icons.duckduckgo.com/ip3/" + senderDomain + ".ico"
    readonly property int candidateCount: candidates().length
    readonly property string activeSource: allowRemoteContent
        ? candidateAt(candidateIndex) : ""
    readonly property string requestedSource: String(avatarImage.source)
    readonly property int imageStatus: avatarImage.status
    readonly property bool showingImage: avatarImage.status === Image.Ready
        && activeSource !== ""

    function resetCandidates() {
        candidateIndex = 0
    }

    function safePublicHost(value) {
        const host = String(value || "").toLowerCase().replace(/\.$/, "")
        if (host.length === 0 || host.length > 253 || host.indexOf("..") >= 0)
            return ""
        if (!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})$/.test(host))
            return ""
        const blocked = ["localhost", "local", "lan", "home", "internal",
            "invalid", "test", "example"]
        const labels = host.split(".")
        if (blocked.indexOf(labels[labels.length - 1]) >= 0) return ""
        const reserved = ["example.com", "example.net", "example.org"]
        for (let index = 0; index < reserved.length; ++index) {
            if (host === reserved[index] || host.endsWith("." + reserved[index]))
                return ""
        }
        return host
    }

    function normalizeAddress(value) {
        let addressValue = String(value || "").trim().toLowerCase()
        const bracketed = addressValue.match(/<([^<>]+)>/)
        if (bracketed) addressValue = bracketed[1].trim()
        if (addressValue.length === 0 || addressValue.length > 254
                || /[\u0000-\u0020\u007f-\u009f]/.test(addressValue))
            return ""
        const separator = addressValue.lastIndexOf("@")
        if (separator <= 0 || separator !== addressValue.indexOf("@")) return ""
        const local = addressValue.substring(0, separator)
        const domain = safePublicHost(addressValue.substring(separator + 1))
        if (local.length > 64 || domain === "" || local[0] === "."
                || local[local.length - 1] === "." || local.indexOf("..") >= 0)
            return ""
        const punctuation = ".!#$%&'*+-/=?^_`{|}~"
        for (let index = 0; index < local.length; ++index) {
            const code = local.charCodeAt(index)
            const alphaNumeric = code >= 48 && code <= 57
                || code >= 97 && code <= 122
            if (!alphaNumeric && punctuation.indexOf(local[index]) < 0) return ""
        }
        return local + "@" + domain
    }

    function domainFromAddress(value) {
        const separator = String(value || "").lastIndexOf("@")
        return separator > 0 ? value.substring(separator + 1) : ""
    }

    function safeHttpsUrl(value) {
        const candidate = String(value || "").trim()
        if (candidate.length === 0 || candidate.length > 2048
                || !candidate.toLowerCase().startsWith("https://")
                || /[\u0000-\u0020\u007f-\u009f]/.test(candidate))
            return ""
        const remainder = candidate.substring(8)
        const boundary = remainder.search(/[/?#]/)
        const authority = boundary < 0 ? remainder : remainder.substring(0, boundary)
        if (authority === "" || authority.indexOf("@") >= 0) return ""
        const colon = authority.lastIndexOf(":")
        const host = colon < 0 ? authority : authority.substring(0, colon)
        if (colon >= 0 && authority.substring(colon + 1) !== "443") return ""
        return safePublicHost(host) === "" ? "" : candidate
    }

    function isPersonalMailboxDomain(value) {
        const domain = String(value || "").toLowerCase()
        const exact = ["gmail.com", "googlemail.com", "icloud.com", "me.com",
            "mac.com", "proton.me", "protonmail.com", "fastmail.com", "aol.com",
            "gmx.com", "gmx.net", "mail.com", "hey.com", "pm.me"]
        if (exact.indexOf(domain) >= 0) return true
        const families = ["outlook.", "hotmail.", "live.", "msn.", "yahoo."]
        for (let index = 0; index < families.length; ++index) {
            if (domain.startsWith(families[index])) return true
        }
        return false
    }

    function automatedSender() {
        const separator = normalizedAddress.indexOf("@")
        const local = separator < 0 ? "" : normalizedAddress.substring(0, separator)
        return /(?:^|[-_.])(no-?reply|notifications?|alerts?|news|jobs?|support)(?:$|[-_.])/.test(local)
    }

    function candidates() {
        const result = []
        function append(value) {
            if (value !== "" && result.indexOf(value) < 0) result.push(value)
        }
        append(normalizedAvatarUrl)
        if (automatedSender()) append(brandIconUrl)
        append(gravatarUrl)
        return result
    }

    function candidateAt(index) {
        const values = candidates()
        return index >= 0 && index < values.length ? values[index] : ""
    }

    onAddressChanged: resetCandidates()
    onAvatarUrlChanged: resetCandidates()
    onAllowRemoteContentChanged: resetCandidates()

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.backgroundColor

        Text {
            objectName: "senderAvatarInitials"
            anchors.centerIn: parent
            text: Theme.initials(root.displayName || root.normalizedAddress)
            textFormat: Text.PlainText
            color: root.foregroundColor
            font.family: Theme.fontFamily
            font.pixelSize: Math.max(9, Math.round(root.width * 0.31))
            font.weight: Font.Bold
        }
    }

    Image {
        id: avatarImage
        objectName: "senderAvatarImage"
        anchors.fill: parent
        source: root.activeSource
        sourceSize.width: Math.max(64, Math.ceil(root.width * 2))
        sourceSize.height: Math.max(64, Math.ceil(root.height * 2))
        asynchronous: true
        cache: true
        smooth: true
        mipmap: true
        fillMode: Image.PreserveAspectCrop
        visible: root.showingImage

        onStatusChanged: {
            if (status === Image.Error
                    && root.candidateIndex + 1 < root.candidateCount)
                ++root.candidateIndex
        }

        layer.enabled: visible
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: avatarMask
        }
    }

    Item {
        id: avatarMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "white"
        }
    }
}
