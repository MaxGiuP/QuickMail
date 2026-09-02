#include "hosttypes.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>

namespace {
constexpr qint64 kMaximumSettingsBytes = 64 * 1024;
constexpr qint64 kMaximumPreviewBytes = 4 * 1024 * 1024;
constexpr qsizetype kMaximumRpcFrameBytes = 16 * 1024 * 1024;
constexpr qsizetype kMaximumProcessOutputCharacters = 4 * 1024 * 1024;

QString configHome()
{
    const QString configured = qEnvironmentVariable("XDG_CONFIG_HOME").trimmed();
    return configured.isEmpty() ? QDir::homePath() + QStringLiteral("/.config") : configured;
}

QString runtimeHome()
{
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR").trimmed();
    if (runtime.isEmpty()) {
        runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    }
    return QDir::isAbsolutePath(runtime) ? runtime : QString();
}

QString stateHome()
{
    const QString configured = qEnvironmentVariable("XDG_STATE_HOME").trimmed();
    return configured.isEmpty() ? QDir::homePath() + QStringLiteral("/.local/state") : configured;
}

QStringList commandStrings(const QVariantList &values)
{
    QStringList result;
    result.reserve(values.size());
    for (const QVariant &value : values) {
        result.push_back(value.toString());
    }
    return result;
}

void stopProcess(QProcess &process)
{
    if (process.state() == QProcess::NotRunning) return;
    process.blockSignals(true);
    process.terminate();
    if (!process.waitForFinished(250)) {
        process.kill();
        process.waitForFinished(250);
    }
}

bool appendBoundedOutput(QString &destination, const QByteArray &bytes)
{
    const qsizetype remaining = kMaximumProcessOutputCharacters - destination.size();
    if (remaining <= 0) return false;
    const QString text = QString::fromUtf8(bytes);
    destination.append(text.left(remaining));
    return !text.isEmpty();
}
} // namespace

HostSettingsStore::HostSettingsStore(QObject *parent)
    : QObject(parent)
{
    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(100);
    connect(&m_saveTimer, &QTimer::timeout, this, &HostSettingsStore::save);
    QTimer::singleShot(0, this, &HostSettingsStore::load);
}

HostSettingsStore::~HostSettingsStore()
{
    if (m_dirty) {
        m_saveTimer.stop();
        save();
    }
}

bool HostSettingsStore::allowRemoteContent() const { return m_allowRemoteContent; }
bool HostSettingsStore::compactMessageList() const { return m_compactMessageList; }
bool HostSettingsStore::composeFormattingExpanded() const { return m_composeFormattingExpanded; }
int HostSettingsStore::readerZoomPercent() const { return m_readerZoomPercent; }
QString HostSettingsStore::themeMode() const { return m_themeMode; }
bool HostSettingsStore::useThemeEmailColors() const { return m_useThemeEmailColors; }
bool HostSettingsStore::ready() const { return m_ready; }

void HostSettingsStore::setAllowRemoteContent(bool value)
{
    if (m_allowRemoteContent == value) return;
    m_allowRemoteContent = value;
    emit allowRemoteContentChanged();
    scheduleSave();
}

void HostSettingsStore::setCompactMessageList(bool value)
{
    if (m_compactMessageList == value) return;
    m_compactMessageList = value;
    emit compactMessageListChanged();
    scheduleSave();
}

void HostSettingsStore::setComposeFormattingExpanded(bool value)
{
    if (m_composeFormattingExpanded == value) return;
    m_composeFormattingExpanded = value;
    emit composeFormattingExpandedChanged();
    scheduleSave();
}

void HostSettingsStore::setReaderZoomPercent(int value)
{
    value = qBound(50, value, 200);
    if (m_readerZoomPercent == value) return;
    m_readerZoomPercent = value;
    emit readerZoomPercentChanged();
    scheduleSave();
}

void HostSettingsStore::setThemeMode(const QString &value)
{
    if (m_themeMode == value) return;
    m_themeMode = value;
    emit themeModeChanged();
    scheduleSave();
}

void HostSettingsStore::setUseThemeEmailColors(bool value)
{
    if (m_useThemeEmailColors == value) return;
    m_useThemeEmailColors = value;
    emit useThemeEmailColorsChanged();
    scheduleSave();
}

QString HostSettingsStore::settingsPath() const
{
    return configHome() + QStringLiteral("/quickmail.json");
}

void HostSettingsStore::load()
{
    QFile file(settingsPath());
    bool shouldSaveDefaults = false;
    if (file.exists()) {
        if (file.size() < 0 || file.size() > kMaximumSettingsBytes
                || !file.open(QIODevice::ReadOnly)) {
            qWarning("QuickMail could not safely read its existing settings");
            return;
        }
        const QByteArray contents = file.read(kMaximumSettingsBytes + 1);
        const QJsonDocument document = QJsonDocument::fromJson(contents);
        if (contents.size() > kMaximumSettingsBytes
                || file.error() != QFileDevice::NoError || !document.isObject()) {
            qWarning("QuickMail's existing settings are invalid");
            return;
        }
        if (!QFile::setPermissions(settingsPath(),
                QFileDevice::ReadOwner | QFileDevice::WriteOwner)) {
            qWarning("QuickMail could not restrict its settings file permissions");
        }
        const QJsonObject values = document.object();
        if (values.value(QStringLiteral("allowRemoteContent")).isBool())
            m_allowRemoteContent = values.value(QStringLiteral("allowRemoteContent")).toBool();
        if (values.value(QStringLiteral("compactMessageList")).isBool())
            m_compactMessageList = values.value(QStringLiteral("compactMessageList")).toBool();
        if (values.value(QStringLiteral("composeFormattingExpanded")).isBool())
            m_composeFormattingExpanded = values.value(QStringLiteral("composeFormattingExpanded")).toBool();
        if (values.value(QStringLiteral("readerZoomPercent")).isDouble())
            m_readerZoomPercent = qBound(50, values.value(QStringLiteral("readerZoomPercent")).toInt(), 200);
        if (values.value(QStringLiteral("themeMode")).isString())
            m_themeMode = values.value(QStringLiteral("themeMode")).toString();
        if (values.value(QStringLiteral("useThemeEmailColors")).isBool())
            m_useThemeEmailColors = values.value(QStringLiteral("useThemeEmailColors")).toBool();
    } else {
        shouldSaveDefaults = true;
    }

    emit allowRemoteContentChanged();
    emit compactMessageListChanged();
    emit composeFormattingExpandedChanged();
    emit readerZoomPercentChanged();
    emit themeModeChanged();
    emit useThemeEmailColorsChanged();
    m_ready = true;
    emit readyChanged();
    if (shouldSaveDefaults) scheduleSave();
}

void HostSettingsStore::scheduleSave()
{
    if (!m_ready) return;
    m_dirty = true;
    m_saveTimer.start();
}

void HostSettingsStore::save()
{
    if (!m_ready || !m_dirty) return;
    const QString directory = QFileInfo(settingsPath()).absolutePath();
    if (!QDir().mkpath(directory)) {
        qWarning("QuickMail could not create its settings directory");
        return;
    }

    const QJsonObject values {
        {QStringLiteral("allowRemoteContent"), m_allowRemoteContent},
        {QStringLiteral("compactMessageList"), m_compactMessageList},
        {QStringLiteral("composeFormattingExpanded"), m_composeFormattingExpanded},
        {QStringLiteral("readerZoomPercent"), m_readerZoomPercent},
        {QStringLiteral("themeMode"), m_themeMode},
        {QStringLiteral("useThemeEmailColors"), m_useThemeEmailColors},
    };

    QSaveFile file(settingsPath());
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning("QuickMail could not open its settings file for writing");
        return;
    }
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    const QByteArray contents = QJsonDocument(values).toJson(QJsonDocument::Indented);
    if (file.write(contents) != contents.size() || !file.commit()) {
        qWarning("QuickMail could not save its settings");
        return;
    }
    m_dirty = false;
}

PlatformBridge::PlatformBridge(QObject *parent)
    : QObject(parent)
{
    connect(&m_paletteWatcher, &QFileSystemWatcher::fileChanged,
            this, [this] { loadSystemPalette(); });
    connect(&m_paletteWatcher, &QFileSystemWatcher::directoryChanged,
            this, [this] { loadSystemPalette(); });
    connect(&m_animationReadProcess, &QProcess::readyReadStandardOutput,
            this, [this] { applyAnimationPreference(m_animationReadProcess.readAllStandardOutput()); });
    connect(&m_animationMonitorProcess, &QProcess::readyReadStandardOutput,
            this, [this] { applyAnimationPreference(m_animationMonitorProcess.readAllStandardOutput()); });
    connect(&m_animationReadProcess,
            qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this](int, QProcess::ExitStatus) {
                if (!m_animationPreferenceSeen && !m_systemAnimationsEnabled) {
                    m_systemAnimationsEnabled = true;
                    emit systemAnimationsEnabledChanged();
                }
            });
    readInitialAnimationPreference();
    startAnimationMonitor();
    loadSystemPalette();
}

PlatformBridge::~PlatformBridge()
{
    stopProcess(m_animationReadProcess);
    stopProcess(m_animationMonitorProcess);
}

bool PlatformBridge::systemAnimationsEnabled() const { return m_systemAnimationsEnabled; }
QString PlatformBridge::systemPaletteText() const { return m_systemPaletteText; }

QString PlatformBridge::env(const QString &name) const
{
    return qEnvironmentVariable(name.toUtf8().constData());
}

bool PlatformBridge::execDetached(const QVariantList &command) const
{
    const QStringList values = commandStrings(command);
    if (values.isEmpty() || values.first().isEmpty()) return false;
    return QProcess::startDetached(values.first(), values.mid(1));
}

void PlatformBridge::readInitialAnimationPreference()
{
    m_animationReadProcess.start(QStringLiteral("gsettings"), {
        QStringLiteral("get"), QStringLiteral("org.gnome.desktop.interface"),
        QStringLiteral("enable-animations")
    });
}

void PlatformBridge::startAnimationMonitor()
{
    m_animationMonitorProcess.start(QStringLiteral("gsettings"), {
        QStringLiteral("monitor"), QStringLiteral("org.gnome.desktop.interface"),
        QStringLiteral("enable-animations")
    });
}

void PlatformBridge::applyAnimationPreference(const QByteArray &output)
{
    const QString normalized = QString::fromUtf8(output).trimmed().toLower();
    bool value;
    if (normalized == QStringLiteral("true") || normalized.endsWith(QStringLiteral(": true"))) {
        value = true;
    } else if (normalized == QStringLiteral("false") || normalized.endsWith(QStringLiteral(": false"))) {
        value = false;
    } else {
        return;
    }
    m_animationPreferenceSeen = true;
    if (m_systemAnimationsEnabled == value) return;
    m_systemAnimationsEnabled = value;
    emit systemAnimationsEnabledChanged();
}

QString PlatformBridge::palettePath() const
{
    return stateHome() + QStringLiteral("/quickshell/user/generated/colors.json");
}

void PlatformBridge::refreshPaletteWatch()
{
    const QString path = palettePath();
    const QString directory = QFileInfo(path).absolutePath();
    if (QFileInfo::exists(directory) && !m_paletteWatcher.directories().contains(directory))
        m_paletteWatcher.addPath(directory);
    if (QFileInfo::exists(path) && !m_paletteWatcher.files().contains(path))
        m_paletteWatcher.addPath(path);
}

void PlatformBridge::loadSystemPalette()
{
    refreshPaletteWatch();
    QFile file(palettePath());
    QString next;
    if (file.size() <= 1024 * 1024 && file.open(QIODevice::ReadOnly))
        next = QString::fromUtf8(file.readAll());
    if (m_systemPaletteText == next) return;
    m_systemPaletteText = next;
    emit systemPaletteTextChanged();
}

RpcTransport::RpcTransport(QObject *parent)
    : QObject(parent), m_path(defaultSocketPath())
{
    connect(&m_socket, &QLocalSocket::readyRead, this, &RpcTransport::consumeReadyRead);
    connect(&m_socket, &QLocalSocket::stateChanged, this, [this] {
        const bool nowConnected = connected();
        if (m_lastConnected == nowConnected) return;
        m_lastConnected = nowConnected;
        emit connectionStateChanged();
    });
    connect(&m_socket, &QLocalSocket::errorOccurred, this,
            [this](QLocalSocket::LocalSocketError) {
                emit errorOccurred(QStringLiteral("Mail service unavailable"));
            });
}

QString RpcTransport::defaultSocketPath() const
{
    const QString runtime = runtimeHome();
    return runtime.isEmpty() ? QString()
                             : runtime + QStringLiteral("/quickmail/daemon.sock");
}

QString RpcTransport::path() const { return m_path; }

void RpcTransport::setPath(const QString &value)
{
    if (m_path == value || value.contains(QChar::Null)) return;
    m_path = value;
    emit pathChanged();
}

bool RpcTransport::connected() const
{
    return m_socket.state() == QLocalSocket::ConnectedState;
}

void RpcTransport::connectSocket()
{
    if (connected() || m_path.isEmpty()) return;
    if (m_socket.state() != QLocalSocket::UnconnectedState) m_socket.abort();
    m_readBuffer.clear();
    m_socket.connectToServer(m_path, QIODevice::ReadWrite);
}

void RpcTransport::disconnectSocket()
{
    m_socket.abort();
    m_readBuffer.clear();
}

void RpcTransport::write(const QString &frame)
{
    if (!connected()) return;
    m_socket.write(frame.toUtf8());
    m_socket.flush();
}

void RpcTransport::consumeReadyRead()
{
    const auto rejectOversizedFrame = [this] {
        m_readBuffer.clear();
        emit errorOccurred(QStringLiteral("The mail service response was too large"));
        m_socket.abort();
    };

    while (m_socket.bytesAvailable() > 0) {
        const qsizetype remaining = kMaximumRpcFrameBytes + 1 - m_readBuffer.size();
        if (remaining <= 0) {
            rejectOversizedFrame();
            return;
        }
        const qint64 available = m_socket.bytesAvailable();
        const qint64 readSize = qMin<qint64>(available, remaining);
        const QByteArray chunk = m_socket.read(readSize);
        if (chunk.isEmpty()) break;
        m_readBuffer.append(chunk);

        while (true) {
            const qsizetype newline = m_readBuffer.indexOf('\n');
            if (newline < 0) break;
            if (newline > kMaximumRpcFrameBytes) {
                rejectOversizedFrame();
                return;
            }
            const QByteArray line = m_readBuffer.left(newline);
            m_readBuffer.remove(0, newline + 1);
            emit lineReceived(QString::fromUtf8(line));
        }
        if (m_readBuffer.size() > kMaximumRpcFrameBytes) {
            rejectOversizedFrame();
            return;
        }
    }
}

ProcessRunner::ProcessRunner(QObject *parent)
    : QObject(parent)
{
    connect(&m_process, &QProcess::readyReadStandardOutput, this, [this] {
        if (appendBoundedOutput(m_stdoutText, m_process.readAllStandardOutput()))
            emit stdoutTextChanged();
    });
    connect(&m_process, &QProcess::readyReadStandardError, this, [this] {
        if (appendBoundedOutput(m_stderrText, m_process.readAllStandardError()))
            emit stderrTextChanged();
    });
    connect(&m_process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
            this, [this](int exitCode, QProcess::ExitStatus status) {
                m_running = false;
                emit runningChanged();
                emit exited(exitCode, static_cast<int>(status));
            });
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return;
        m_running = false;
        emit runningChanged();
        emit exited(127, static_cast<int>(QProcess::CrashExit));
    });
}

ProcessRunner::~ProcessRunner()
{
    stopProcess(m_process);
}

QVariantList ProcessRunner::command() const { return m_command; }

void ProcessRunner::setCommand(const QVariantList &value)
{
    if (m_command == value) return;
    m_command = value;
    emit commandChanged();
}

bool ProcessRunner::running() const { return m_running; }

void ProcessRunner::setRunning(bool value)
{
    if (value == m_running) return;
    value ? start() : stop();
}

QString ProcessRunner::stdoutText() const { return m_stdoutText; }
QString ProcessRunner::stderrText() const { return m_stderrText; }

void ProcessRunner::start()
{
    const QStringList values = commandStrings(m_command);
    if (values.isEmpty() || values.first().isEmpty()) {
        emit exited(127, static_cast<int>(QProcess::CrashExit));
        return;
    }
    if (m_process.state() != QProcess::NotRunning) return;
    m_stdoutText.clear();
    m_stderrText.clear();
    emit stdoutTextChanged();
    emit stderrTextChanged();
    m_running = true;
    emit runningChanged();
    m_process.start(values.first(), values.mid(1));
}

void ProcessRunner::stop()
{
    if (m_process.state() != QProcess::NotRunning) m_process.kill();
}

FileReader::FileReader(QObject *parent)
    : QObject(parent)
{
}

QString FileReader::path() const { return m_path; }

void FileReader::setPath(const QString &value)
{
    if (m_path == value) return;
    m_path = value;
    emit pathChanged();
    if (m_path.isEmpty() && !m_content.isEmpty()) {
        m_content.clear();
        emit contentChanged();
    }
    if (m_preload && !m_path.isEmpty()) QTimer::singleShot(0, this, &FileReader::reload);
}

bool FileReader::preload() const { return m_preload; }

void FileReader::setPreload(bool value)
{
    if (m_preload == value) return;
    m_preload = value;
    emit preloadChanged();
    if (m_preload && !m_path.isEmpty()) QTimer::singleShot(0, this, &FileReader::reload);
}

QString FileReader::content() const { return m_content; }

void FileReader::reload()
{
    if (m_path.isEmpty() || m_path.contains(QChar::Null)) {
        failLoad(QStringLiteral("Invalid file path"));
        return;
    }
    QFile file(m_path);
    const QFileInfo fileInfo(file);
    if (!fileInfo.exists() || !fileInfo.isFile()
            || fileInfo.size() < 0 || fileInfo.size() > kMaximumPreviewBytes
            || !file.open(QIODevice::ReadOnly)) {
        failLoad(QStringLiteral("Could not read file"));
        return;
    }
    const QByteArray contents = file.read(kMaximumPreviewBytes + 1);
    if (contents.size() > kMaximumPreviewBytes
            || file.error() != QFileDevice::NoError) {
        failLoad(QStringLiteral("Could not read file"));
        return;
    }
    m_content = QString::fromUtf8(contents);
    emit contentChanged();
    emit loaded();
}

void FileReader::failLoad(const QString &message)
{
    if (!m_content.isEmpty()) {
        m_content.clear();
        emit contentChanged();
    }
    emit loadFailed(message);
}
