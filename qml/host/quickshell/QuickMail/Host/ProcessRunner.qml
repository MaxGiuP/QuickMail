import Quickshell.Io as QuickshellIo

QuickshellIo.Process {
    readonly property string stdoutText: stdoutCollector.text
    readonly property string stderrText: stderrCollector.text

    stdout: stdoutCollector
    stderr: stderrCollector

    property QuickshellIo.StdioCollector stdoutCollector:
        QuickshellIo.StdioCollector {
            waitForEnd: true
        }
    property QuickshellIo.StdioCollector stderrCollector:
        QuickshellIo.StdioCollector {
            waitForEnd: true
        }
}
