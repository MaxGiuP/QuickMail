import QtQuick
import QtQuick.Controls
import "../components"

ApplicationWindow {
    id: window

    visible: true
    width: 520
    height: 180
    color: "#111318"

    function expect(condition, message) {
        if (condition) return
        console.error("SENDER AVATAR TEST FAILED: " + message)
        Qt.exit(1)
    }

    function descendantsWithName(object, name, result) {
        if (!object) return
        if (object.objectName === name) result.push(object)
        const children = object.children || []
        for (let index = 0; index < children.length; ++index)
            descendantsWithName(children[index], name, result)
    }

    property int phase: 0
    property int requestsBeforeOptOut: 0

    QtObject {
        id: fakeResolver
        property int avatarEpoch: 1
        property int requestCount: 0
        property int nextToken: 1
        property int currentToken: 0
        property int cancelCount: 0
        property string lastUrl: ""
        property var pendingCallback: null
        property var cancelledCallback: null

        function resolveAvatar(url, callback) {
            ++requestCount
            lastUrl = String(url || "")
            pendingCallback = callback
            currentToken = nextToken++
            return currentToken
        }

        function cancelAvatar(token) {
            if (Number(token) !== currentToken || currentToken === 0) return false
            cancelledCallback = pendingCallback
            pendingCallback = null
            currentToken = 0
            ++cancelCount
            return true
        }

        function completeWithLocalFile() {
            const callback = pendingCallback
            pendingCallback = null
            currentToken = 0
            callback(Qt.resolvedUrl("avatar-fixture.svg"), null)
        }

        function completeCancelledRequest() {
            const callback = cancelledCallback
            cancelledCallback = null
            callback(Qt.resolvedUrl("avatar-fixture.svg"), null)
        }
    }

    SenderAvatar {
        id: personalAvatar
        x: 20
        y: 20
        width: 48
        height: 48
        displayName: "Alice Adams"
        address: "  Alice@GMAIL.com  "
        allowRemoteContent: false
    }

    SenderAvatar {
        id: automatedAvatar
        x: 84
        y: 20
        width: 48
        height: 48
        displayName: "LinkedIn Job Alerts"
        address: "jobalerts-noreply@linkedin.com"
        allowRemoteContent: false
    }

    SenderAvatar {
        id: humanCompanyAvatar
        x: 276
        y: 20
        width: 48
        height: 48
        displayName: "Human Sender"
        address: "human@linkedin.com"
        allowRemoteContent: false
    }

    SenderAvatar {
        id: unsafeAvatar
        x: 212
        y: 20
        width: 48
        height: 48
        displayName: "Unsafe Contact"
        address: "person@localhost"
        allowRemoteContent: true
    }

    SenderAvatar {
        id: brokeredAvatar
        x: 340
        y: 20
        width: 48
        height: 48
        displayName: "Brokered Alert"
        address: "notifications@linkedin.com"
        allowRemoteContent: true
        avatarResolver: fakeResolver
    }

    Timer {
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (window.phase === 1) {
                window.expect(brokeredAvatar.requestedSource.toLowerCase()
                        .startsWith("file:///"),
                    "the daemon-cached avatar was not loaded from a local file")
                window.expect(brokeredAvatar.showingImage,
                    "the local avatar fixture did not render")
                window.requestsBeforeOptOut = fakeResolver.requestCount
                ++fakeResolver.avatarEpoch
                window.phase = 2
                return
            }
            if (window.phase === 2) {
                window.expect(fakeResolver.requestCount
                        === window.requestsBeforeOptOut + 1
                        && brokeredAvatar.pendingToken > 0,
                    "a reconnect did not create one cancelable avatar request")
                window.requestsBeforeOptOut = fakeResolver.requestCount
                brokeredAvatar.allowRemoteContent = false
                window.phase = 3
                return
            }
            if (window.phase === 3) {
                window.expect(brokeredAvatar.requestedSource === ""
                        && !brokeredAvatar.showingImage,
                    "remote-content opt-out did not clear the cached avatar")
                window.expect(fakeResolver.requestCount === window.requestsBeforeOptOut,
                    "remote-content opt-out issued another avatar request")
                window.expect(fakeResolver.cancelCount === 1
                        && brokeredAvatar.pendingToken === 0,
                    "remote-content opt-out did not cancel its queued consumer")
                fakeResolver.completeCancelledRequest()
                window.phase = 4
                return
            }
            if (window.phase === 4) {
                window.expect(brokeredAvatar.requestedSource === ""
                        && !brokeredAvatar.showingImage,
                    "a late callback restored an avatar after opt-out")
                stop()
                Qt.quit()
                return
            }

            window.expect(personalAvatar.normalizedAddress === "alice@gmail.com",
                "email addresses were not normalized before hashing")
            window.expect(personalAvatar.candidateCount === 1
                    && personalAvatar.candidateAt(0)
                        === "https://www.gravatar.com/avatar/0ce273d3249291c620af81403b14b3c1?d=blank&s=128",
                "the deterministic Gravatar URL is wrong")
            window.expect(personalAvatar.brandIconUrl === "",
                "a generic mailbox-provider logo replaced a person's fallback")
            window.expect(automatedAvatar.candidateAt(0)
                    === "https://icons.duckduckgo.com/ip3/linkedin.com.ico"
                    && automatedAvatar.candidateAt(1).indexOf(
                        "https://www.gravatar.com/avatar/") === 0,
                "automated brand senders do not prefer their own domain icon")
            window.expect(humanCompanyAvatar.candidateCount === 1
                    && humanCompanyAvatar.candidateAt(0).indexOf(
                        "https://www.gravatar.com/avatar/") === 0,
                "a human sender was misleadingly represented by an employer favicon")
            window.expect(unsafeAvatar.normalizedAddress === ""
                    && unsafeAvatar.candidateCount === 0
                    && unsafeAvatar.requestedSource === "",
                "an unsafe address or image scheme reached the image loader")
            window.expect(personalAvatar.requestedSource === ""
                    && automatedAvatar.requestedSource === "",
                "remote-content opt-out did not suppress avatar requests")
            window.expect(fakeResolver.requestCount === 1
                    && fakeResolver.lastUrl
                        === "https://icons.duckduckgo.com/ip3/linkedin.com.ico",
                "the visible avatar did not request its preferred candidate once")
            window.expect(brokeredAvatar.requestedSource === ""
                    && !brokeredAvatar.requestedSource.toLowerCase().startsWith("http"),
                "a remote URL reached Qt's image loader before daemon caching")

            const images = []
            window.descendantsWithName(personalAvatar, "senderAvatarImage", images)
            window.expect(images.length === 1 && !images[0].asynchronous
                    && images[0].cache,
                "avatar loading is not local-only and cache-enabled")
            const initials = []
            window.descendantsWithName(personalAvatar, "senderAvatarInitials", initials)
            window.expect(initials.length === 1 && initials[0].text === "AA",
                "the clean initials fallback was not retained")
            fakeResolver.completeWithLocalFile()
            window.phase = 1
        }
    }
}
