pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import ".."

Rectangle {
    id: root

    property url source
    property bool video: false
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property string errorText: player.errorString

    color: Theme.canvas

    function togglePlayback() {
        if (root.playing) player.pause()
        else player.play()
    }

    function formatDuration(milliseconds) {
        const totalSeconds = Math.max(0, Math.floor(Number(milliseconds || 0) / 1000))
        const hours = Math.floor(totalSeconds / 3600)
        const minutes = Math.floor((totalSeconds % 3600) / 60)
        const seconds = totalSeconds % 60
        const paddedSeconds = seconds < 10 ? "0" + seconds : String(seconds)
        if (hours <= 0) return minutes + ":" + paddedSeconds
        const paddedMinutes = minutes < 10 ? "0" + minutes : String(minutes)
        return hours + ":" + paddedMinutes + ":" + paddedSeconds
    }

    function seekBy(milliseconds) {
        player.position = Math.max(0, Math.min(player.duration,
            player.position + Number(milliseconds || 0)))
    }

    onVisibleChanged: if (!visible) player.stop()
    onSourceChanged: player.stop()

    MediaPlayer {
        id: player
        source: root.source
        audioOutput: AudioOutput { id: audioOutput }
        videoOutput: root.video ? videoOutput : null
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            VideoOutput {
                id: videoOutput
                anchors.fill: parent
                visible: root.video
                fillMode: VideoOutput.PreserveAspectFit
            }

            ColumnLayout {
                anchors.centerIn: parent
                visible: !root.video
                spacing: 12
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: Theme.icon("audio")
                    color: Theme.accent
                    font.family: Theme.iconFont
                    font.pixelSize: 72
                }
                Text {
                    text: "Audio attachment"
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                }
            }

            EmptyState {
                anchors.fill: parent
                visible: player.error !== MediaPlayer.NoError
                iconName: "error"
                title: "Media preview unavailable"
                detail: root.errorText || "This media format could not be decoded."
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: Theme.surfaceRaised
            border.width: 1
            border.color: Theme.borderSoft

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 12
                spacing: 8

                IconButton {
                    objectName: "mediaPlaybackButton"
                    iconName: root.playing ? "pause" : "play"
                    tip: root.playing ? "Pause (Space)" : "Play (Space)"
                    enabled: player.error === MediaPlayer.NoError
                    onClicked: root.togglePlayback()
                }
                Text {
                    text: root.formatDuration(player.position)
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }
                Slider {
                    id: seekSlider
                    Layout.fillWidth: true
                    from: 0
                    to: Math.max(1, player.duration)
                    enabled: player.seekable && player.duration > 0
                    onMoved: player.position = value
                    Binding {
                        target: seekSlider
                        property: "value"
                        value: player.position
                        when: !seekSlider.pressed
                    }
                }
                Text {
                    text: root.formatDuration(player.duration)
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }
                IconButton {
                    iconName: audioOutput.muted ? "muted" : "volume"
                    tip: audioOutput.muted ? "Unmute" : "Mute"
                    onClicked: audioOutput.muted = !audioOutput.muted
                }
                Slider {
                    Layout.preferredWidth: 92
                    from: 0
                    to: 1
                    value: audioOutput.volume
                    onMoved: audioOutput.volume = value
                }
            }
        }
    }

    Shortcut {
        sequence: "Space"
        enabled: root.visible
        onActivated: root.togglePlayback()
    }
    Shortcut {
        sequence: "Left"
        enabled: root.visible && player.seekable
        onActivated: root.seekBy(-5000)
    }
    Shortcut {
        sequence: "Right"
        enabled: root.visible && player.seekable
        onActivated: root.seekBy(5000)
    }
}
