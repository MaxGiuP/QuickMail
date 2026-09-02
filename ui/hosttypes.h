#pragma once

#include <QFileSystemWatcher>
#include <QLocalSocket>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>
#include <QVariantList>

class HostSettingsStore : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool allowRemoteContent READ allowRemoteContent WRITE setAllowRemoteContent NOTIFY allowRemoteContentChanged)
    Q_PROPERTY(bool compactMessageList READ compactMessageList WRITE setCompactMessageList NOTIFY compactMessageListChanged)
    Q_PROPERTY(bool composeFormattingExpanded READ composeFormattingExpanded WRITE setComposeFormattingExpanded NOTIFY composeFormattingExpandedChanged)
    Q_PROPERTY(int readerZoomPercent READ readerZoomPercent WRITE setReaderZoomPercent NOTIFY readerZoomPercentChanged)
    Q_PROPERTY(QString themeMode READ themeMode WRITE setThemeMode NOTIFY themeModeChanged)
    Q_PROPERTY(bool useThemeEmailColors READ useThemeEmailColors WRITE setUseThemeEmailColors NOTIFY useThemeEmailColorsChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)

public:
    explicit HostSettingsStore(QObject *parent = nullptr);
    ~HostSettingsStore() override;

    bool allowRemoteContent() const;
    bool compactMessageList() const;
    bool composeFormattingExpanded() const;
    int readerZoomPercent() const;
    QString themeMode() const;
    bool useThemeEmailColors() const;
    bool ready() const;

    void setAllowRemoteContent(bool value);
    void setCompactMessageList(bool value);
    void setComposeFormattingExpanded(bool value);
    void setReaderZoomPercent(int value);
    void setThemeMode(const QString &value);
    void setUseThemeEmailColors(bool value);

signals:
    void allowRemoteContentChanged();
    void compactMessageListChanged();
    void composeFormattingExpandedChanged();
    void readerZoomPercentChanged();
    void themeModeChanged();
    void useThemeEmailColorsChanged();
    void readyChanged();

private:
    void load();
    void scheduleSave();
    void save();
    QString settingsPath() const;

    bool m_allowRemoteContent = true;
    bool m_compactMessageList = false;
    bool m_composeFormattingExpanded = true;
    int m_readerZoomPercent = 100;
    QString m_themeMode = QStringLiteral("system");
    bool m_useThemeEmailColors = true;
    bool m_ready = false;
    bool m_dirty = false;
    QTimer m_saveTimer;
};

class PlatformBridge final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool systemAnimationsEnabled READ systemAnimationsEnabled NOTIFY systemAnimationsEnabledChanged)
    Q_PROPERTY(QString systemPaletteText READ systemPaletteText NOTIFY systemPaletteTextChanged)

public:
    explicit PlatformBridge(QObject *parent = nullptr);
    ~PlatformBridge() override;

    bool systemAnimationsEnabled() const;
    QString systemPaletteText() const;

    Q_INVOKABLE QString env(const QString &name) const;
    Q_INVOKABLE bool execDetached(const QVariantList &command) const;

signals:
    void systemAnimationsEnabledChanged();
    void systemPaletteTextChanged();

private:
    void readInitialAnimationPreference();
    void startAnimationMonitor();
    void applyAnimationPreference(const QByteArray &output);
    void refreshPaletteWatch();
    void loadSystemPalette();
    QString palettePath() const;

    bool m_systemAnimationsEnabled = true;
    bool m_animationPreferenceSeen = false;
    QString m_systemPaletteText;
    QFileSystemWatcher m_paletteWatcher;
    QProcess m_animationReadProcess;
    QProcess m_animationMonitorProcess;
};

class RpcTransport : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString defaultSocketPath READ defaultSocketPath CONSTANT)
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectionStateChanged)

public:
    explicit RpcTransport(QObject *parent = nullptr);

    QString defaultSocketPath() const;
    QString path() const;
    void setPath(const QString &value);
    bool connected() const;

    Q_INVOKABLE void connectSocket();
    Q_INVOKABLE void disconnectSocket();
    Q_INVOKABLE void write(const QString &frame);

signals:
    void pathChanged();
    void connectionStateChanged();
    void lineReceived(const QString &line);
    void errorOccurred(const QString &message);

private:
    void consumeReadyRead();

    QString m_path;
    QLocalSocket m_socket;
    QByteArray m_readBuffer;
    bool m_lastConnected = false;
};

class ProcessRunner : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList command READ command WRITE setCommand NOTIFY commandChanged)
    Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
    Q_PROPERTY(QString stdoutText READ stdoutText NOTIFY stdoutTextChanged)
    Q_PROPERTY(QString stderrText READ stderrText NOTIFY stderrTextChanged)

public:
    explicit ProcessRunner(QObject *parent = nullptr);
    ~ProcessRunner() override;

    QVariantList command() const;
    void setCommand(const QVariantList &value);
    bool running() const;
    void setRunning(bool value);
    QString stdoutText() const;
    QString stderrText() const;

signals:
    void commandChanged();
    void runningChanged();
    void stdoutTextChanged();
    void stderrTextChanged();
    void exited(int exitCode, int exitStatus);

private:
    void start();
    void stop();

    QVariantList m_command;
    QProcess m_process;
    QString m_stdoutText;
    QString m_stderrText;
    bool m_running = false;
};

class FileReader : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(bool preload READ preload WRITE setPreload NOTIFY preloadChanged)
    Q_PROPERTY(QString content READ content NOTIFY contentChanged)

public:
    explicit FileReader(QObject *parent = nullptr);

    QString path() const;
    void setPath(const QString &value);
    bool preload() const;
    void setPreload(bool value);
    QString content() const;

    Q_INVOKABLE void reload();

signals:
    void pathChanged();
    void preloadChanged();
    void contentChanged();
    void loaded();
    void loadFailed(const QString &message);

private:
    void failLoad(const QString &message);

    QString m_path;
    QString m_content;
    bool m_preload = false;
};
