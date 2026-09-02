pragma Singleton

import QtQuick
import QuickMail.Host as Host

Host.SettingsStore {
    id: root

    // Loading a persisted opt-out is asynchronous. Keep every network-backed
    // renderer fail-closed until that choice is known.
    readonly property bool effectiveAllowRemoteContent: ready && allowRemoteContent
}
