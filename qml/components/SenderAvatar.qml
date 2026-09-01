import QtQuick
import QtQuick.Effects
import ".."

Item {
    id: root

    property string displayName: ""
    property string address: ""
    property bool allowRemoteContent: true
    property var avatarResolver: null
    property color backgroundColor: Theme.accentSoft
    property color foregroundColor: Theme.accent

    property int candidateIndex: 0
    property int resolutionGeneration: 0
    property string resolvedSource: ""
    property bool componentReady: false
    property var pendingResolver: null
    property int pendingToken: 0
    readonly property string normalizedAddress: normalizeAddress(address)
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
    readonly property int resolverEpoch: avatarResolver
        && avatarResolver.avatarEpoch !== undefined
            ? Number(avatarResolver.avatarEpoch || 0) : 0
    readonly property string requestedSource: String(avatarImage.source)
    readonly property int imageStatus: avatarImage.status
    readonly property bool showingImage: avatarImage.status === Image.Ready
        && resolvedSource !== ""

    function resetCandidates() {
        if (!componentReady) return
        cancelPendingResolution()
        ++resolutionGeneration
        resolvedSource = ""
        candidateIndex = 0
        resolveTimer.restart()
    }

    function advanceCandidate() {
        cancelPendingResolution()
        ++resolutionGeneration
        resolvedSource = ""
        if (candidateIndex + 1 >= candidateCount) return
        ++candidateIndex
        resolveTimer.restart()
    }

    function safeLocalSource(value) {
        const candidate = String(value || "").trim()
        return candidate.length <= 4096
            && candidate.toLowerCase().startsWith("file:///")
            && !/[\u0000-\u0020\u007f-\u009f]/.test(candidate)
                ? candidate : ""
    }

    function resolveCandidate() {
        if (!componentReady) return
        cancelPendingResolution()
        const generation = ++resolutionGeneration
        const remoteSource = activeSource
        resolvedSource = ""
        if (remoteSource === "" || !avatarResolver
                || typeof avatarResolver.resolveAvatar !== "function") return
        const resolver = avatarResolver
        const token = Number(resolver.resolveAvatar(remoteSource, function(source, error) {
            if (generation !== root.resolutionGeneration
                    || remoteSource !== root.activeSource) return
            root.pendingResolver = null
            root.pendingToken = 0
            const localSource = error ? "" : root.safeLocalSource(source)
            if (localSource !== "") {
                root.resolvedSource = localSource
            } else root.advanceCandidate()
        }) || 0)
        if (token > 0 && generation === resolutionGeneration
                && remoteSource === activeSource) {
            pendingResolver = resolver
            pendingToken = token
        } else if (token > 0 && typeof resolver.cancelAvatar === "function") {
            resolver.cancelAvatar(token)
        }
    }

    function cancelPendingResolution() {
        const resolver = pendingResolver
        const token = pendingToken
        pendingResolver = null
        pendingToken = 0
        if (token > 0 && resolver && typeof resolver.cancelAvatar === "function")
            resolver.cancelAvatar(token)
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
        if (automatedSender()) append(brandIconUrl)
        append(gravatarUrl)
        return result
    }

    function candidateAt(index) {
        const values = candidates()
        return index >= 0 && index < values.length ? values[index] : ""
    }

    onAddressChanged: resetCandidates()
    onAllowRemoteContentChanged: resetCandidates()
    onAvatarResolverChanged: resetCandidates()
    onResolverEpochChanged: resetCandidates()
    Component.onCompleted: {
        componentReady = true
        resetCandidates()
    }
    Component.onDestruction: cancelPendingResolution()

    Timer {
        id: resolveTimer
        interval: 0
        repeat: false
        onTriggered: root.resolveCandidate()
    }

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
        source: root.resolvedSource
        sourceSize.width: Math.max(64, Math.ceil(root.width * 2))
        sourceSize.height: Math.max(64, Math.ceil(root.height * 2))
        // HTTPS never reaches Qt's image/network stack. The daemon fetches
        // and validates a small file through Rustls before this local load.
        asynchronous: false
        cache: true
        smooth: true
        mipmap: true
        fillMode: Image.PreserveAspectCrop
        visible: root.showingImage

        onStatusChanged: {
            if (status === Image.Error) root.advanceCandidate()
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
