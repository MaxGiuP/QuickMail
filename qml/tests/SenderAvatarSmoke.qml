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
        id: providerAvatar
        x: 148
        y: 20
        width: 48
        height: 48
        displayName: "Provider Contact"
        avatarUrl: "https://avatars.githubusercontent.com/u/1?v=4"
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
        avatarUrl: "javascript:alert(1)"
        allowRemoteContent: true
    }

    Timer {
        interval: 50
        running: true
        repeat: false
        onTriggered: {
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
            window.expect(providerAvatar.normalizedAvatarUrl
                    === "https://avatars.githubusercontent.com/u/1?v=4"
                    && providerAvatar.candidateAt(0) === providerAvatar.normalizedAvatarUrl,
                "a valid provider-supplied HTTPS photo was not preferred")
            window.expect(humanCompanyAvatar.candidateCount === 1
                    && humanCompanyAvatar.candidateAt(0).indexOf(
                        "https://www.gravatar.com/avatar/") === 0,
                "a human sender was misleadingly represented by an employer favicon")
            window.expect(unsafeAvatar.normalizedAddress === ""
                    && unsafeAvatar.normalizedAvatarUrl === ""
                    && unsafeAvatar.candidateCount === 0
                    && unsafeAvatar.requestedSource === "",
                "an unsafe address or image scheme reached the image loader")
            window.expect(personalAvatar.requestedSource === ""
                    && automatedAvatar.requestedSource === ""
                    && providerAvatar.requestedSource === "",
                "remote-content opt-out did not suppress avatar requests")

            const images = []
            window.descendantsWithName(personalAvatar, "senderAvatarImage", images)
            window.expect(images.length === 1 && images[0].asynchronous
                    && images[0].cache,
                "avatar loading is not asynchronous and cache-enabled")
            const initials = []
            window.descendantsWithName(personalAvatar, "senderAvatarInitials", initials)
            window.expect(initials.length === 1 && initials[0].text === "AA",
                "the clean initials fallback was not retained")
            Qt.quit()
        }
    }
}
