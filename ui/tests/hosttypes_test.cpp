#include "../hosttypes.h"

#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QProcess>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

#include <memory>

namespace {
constexpr qsizetype kMaximumRpcFrameBytes = 16 * 1024 * 1024;
constexpr qint64 kMaximumPreviewBytes = 4 * 1024 * 1024;

class ScopedEnvironmentVariable final {
public:
    ScopedEnvironmentVariable(const char *name, const QByteArray &value)
        : m_name(name),
          m_wasSet(qEnvironmentVariableIsSet(name)),
          m_originalValue(qgetenv(name))
    {
        qputenv(m_name.constData(), value);
    }

    ~ScopedEnvironmentVariable()
    {
        if (m_wasSet) {
            qputenv(m_name.constData(), m_originalValue);
        } else {
            qunsetenv(m_name.constData());
        }
    }

    ScopedEnvironmentVariable(const ScopedEnvironmentVariable &) = delete;
    ScopedEnvironmentVariable &operator=(const ScopedEnvironmentVariable &) = delete;

private:
    QByteArray m_name;
    bool m_wasSet;
    QByteArray m_originalValue;
};

void writeFile(const QString &path, const QByteArray &contents)
{
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly), qPrintable(file.errorString()));
    QCOMPARE(file.write(contents), contents.size());
    file.close();
}

QLocalSocket *connectTransport(QLocalServer &server, RpcTransport &transport,
                               const QString &socketPath)
{
    QLocalServer::removeServer(socketPath);
    if (!server.listen(socketPath)) return nullptr;

    transport.setPath(socketPath);
    transport.connectSocket();
    for (int attempt = 0;
         attempt < 100 && (!transport.connected() || !server.hasPendingConnections());
         ++attempt) {
        QTest::qWait(10);
    }
    if (!transport.connected() || !server.hasPendingConnections()) return nullptr;
    return server.nextPendingConnection();
}
} // namespace

class HostTypesTest final : public QObject {
    Q_OBJECT

private slots:
    void settingsPersistLastWriteOnDestruction();
    void settingsRejectInvalidExistingFile_data();
    void settingsRejectInvalidExistingFile();
    void fileReaderLoadsUtf8Content();
    void fileReaderFailureClearsStaleContent();
    void fileReaderRejectsOversizedFiles();
    void processRunnerReportsFailedStartOnce();
    void rpcTransportFramesCompleteLines();
    void rpcTransportRejectsOversizedTerminatedFrame();
};

void HostTypesTest::settingsPersistLastWriteOnDestruction()
{
    QTemporaryDir configDirectory;
    QVERIFY(configDirectory.isValid());
    const ScopedEnvironmentVariable configHome("XDG_CONFIG_HOME",
                                                configDirectory.path().toUtf8());
    const QString settingsPath = configDirectory.filePath(QStringLiteral("quickmail.json"));

    {
        auto settings = std::make_unique<HostSettingsStore>();
        QTRY_VERIFY(settings->ready());

        // Let the initial defaults reach disk so this specifically tests whether a
        // newer debounced write is flushed when the store is destroyed.
        QTRY_VERIFY(QFileInfo::exists(settingsPath));

        settings->setAllowRemoteContent(false);
        settings->setCompactMessageList(true);
        settings->setComposeFormattingExpanded(false);
        settings->setReaderZoomPercent(175);
        settings->setReaderZoomPercent(142);
        settings->setThemeMode(QStringLiteral("dark"));
        settings->setThemeMode(QStringLiteral("light"));
        settings->setUseThemeEmailColors(false);
    }

    QFile persistedFile(settingsPath);
    QVERIFY2(persistedFile.open(QIODevice::ReadOnly), qPrintable(persistedFile.errorString()));
    const QJsonDocument persisted = QJsonDocument::fromJson(persistedFile.readAll());
    QVERIFY(persisted.isObject());
    const QJsonObject values = persisted.object();
    QCOMPARE(values.value(QStringLiteral("allowRemoteContent")).toBool(), false);
    QCOMPARE(values.value(QStringLiteral("compactMessageList")).toBool(), true);
    QCOMPARE(values.value(QStringLiteral("composeFormattingExpanded")).toBool(), false);
    QCOMPARE(values.value(QStringLiteral("readerZoomPercent")).toInt(), 142);
    QCOMPARE(values.value(QStringLiteral("themeMode")).toString(), QStringLiteral("light"));
    QCOMPARE(values.value(QStringLiteral("useThemeEmailColors")).toBool(), false);

    HostSettingsStore reloaded;
    QTRY_VERIFY(reloaded.ready());
    QCOMPARE(reloaded.allowRemoteContent(), false);
    QCOMPARE(reloaded.compactMessageList(), true);
    QCOMPARE(reloaded.composeFormattingExpanded(), false);
    QCOMPARE(reloaded.readerZoomPercent(), 142);
    QCOMPARE(reloaded.themeMode(), QStringLiteral("light"));
    QCOMPARE(reloaded.useThemeEmailColors(), false);
}

void HostTypesTest::settingsRejectInvalidExistingFile_data()
{
    QTest::addColumn<QByteArray>("contents");

    QTest::newRow("malformed-json")
        << QByteArrayLiteral("{\"allowRemoteContent\": true");
    QTest::newRow("over-size-limit") << QByteArray(64 * 1024 + 1, 'x');
}

void HostTypesTest::settingsRejectInvalidExistingFile()
{
    QFETCH(QByteArray, contents);

    QTemporaryDir configDirectory;
    QVERIFY(configDirectory.isValid());
    const ScopedEnvironmentVariable configHome("XDG_CONFIG_HOME",
                                                configDirectory.path().toUtf8());
    writeFile(configDirectory.filePath(QStringLiteral("quickmail.json")), contents);

    HostSettingsStore settings;
    QSignalSpy readyChanged(&settings, &HostSettingsStore::readyChanged);

    // Loading is queued from the constructor. Give that callback time to run,
    // then verify an untrusted file never transitions the store to ready.
    QTest::qWait(20);
    QCOMPARE(settings.ready(), false);
    QCOMPARE(readyChanged.count(), 0);

    // This mirrors AppSettings.effectiveAllowRemoteContent. Even if the raw
    // default is permissive, network-backed rendering must stay fail-closed.
    const bool effectiveAllowRemoteContent = settings.ready()
                                             && settings.allowRemoteContent();
    QCOMPARE(effectiveAllowRemoteContent, false);
}

void HostTypesTest::fileReaderLoadsUtf8Content()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString path = directory.filePath(QStringLiteral("preview.txt"));
    const QString expected = QString::fromUtf8("Hello, QuickMail \xF0\x9F\x93\xA8\nSecond line");
    writeFile(path, expected.toUtf8());

    FileReader reader;
    QSignalSpy contentChanged(&reader, &FileReader::contentChanged);
    QSignalSpy loaded(&reader, &FileReader::loaded);
    QSignalSpy failed(&reader, &FileReader::loadFailed);
    reader.setPath(path);
    reader.reload();

    QCOMPARE(reader.content(), expected);
    QCOMPARE(contentChanged.count(), 1);
    QCOMPARE(loaded.count(), 1);
    QCOMPARE(failed.count(), 0);
}

void HostTypesTest::fileReaderFailureClearsStaleContent()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString readablePath = directory.filePath(QStringLiteral("readable.txt"));
    writeFile(readablePath, QByteArrayLiteral("content that must not remain visible"));

    FileReader reader;
    reader.setPath(readablePath);
    reader.reload();
    QVERIFY(!reader.content().isEmpty());

    QSignalSpy contentChanged(&reader, &FileReader::contentChanged);
    QSignalSpy loaded(&reader, &FileReader::loaded);
    QSignalSpy failed(&reader, &FileReader::loadFailed);
    reader.setPath(directory.filePath(QStringLiteral("missing.txt")));
    reader.reload();

    QCOMPARE(reader.content(), QString());
    QCOMPARE(contentChanged.count(), 1);
    QCOMPARE(loaded.count(), 0);
    QCOMPARE(failed.count(), 1);
    QVERIFY(!failed.first().first().toString().isEmpty());
}

void HostTypesTest::fileReaderRejectsOversizedFiles()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString path = directory.filePath(QStringLiteral("oversized.txt"));
    QFile oversized(path);
    QVERIFY2(oversized.open(QIODevice::WriteOnly), qPrintable(oversized.errorString()));
    QVERIFY(oversized.resize(kMaximumPreviewBytes + 1));
    oversized.close();

    FileReader reader;
    QSignalSpy loaded(&reader, &FileReader::loaded);
    QSignalSpy failed(&reader, &FileReader::loadFailed);
    reader.setPath(path);
    reader.reload();

    QCOMPARE(reader.content(), QString());
    QCOMPARE(loaded.count(), 0);
    QCOMPARE(failed.count(), 1);
}

void HostTypesTest::processRunnerReportsFailedStartOnce()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());

    ProcessRunner runner;
    runner.setCommand({directory.filePath(QStringLiteral("does-not-exist"))});
    QSignalSpy runningChanged(&runner, &ProcessRunner::runningChanged);
    QSignalSpy exited(&runner, &ProcessRunner::exited);
    runner.setRunning(true);

    QTRY_COMPARE_WITH_TIMEOUT(exited.count(), 1, 5000);
    QTest::qWait(50);
    QCOMPARE(exited.count(), 1);
    QCOMPARE(exited.first().at(0).toInt(), 127);
    QCOMPARE(exited.first().at(1).toInt(), static_cast<int>(QProcess::CrashExit));
    QCOMPARE(runner.running(), false);
    QCOMPARE(runner.stdoutText(), QString());
    QCOMPARE(runner.stderrText(), QString());
    QVERIFY(runningChanged.count() >= 2);
}

void HostTypesTest::rpcTransportFramesCompleteLines()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer server;
    RpcTransport transport;
    QLocalSocket *peer = connectTransport(server, transport,
                                          directory.filePath(QStringLiteral("normal.sock")));
    QVERIFY2(peer, qPrintable(server.errorString()));

    QSignalSpy lines(&transport, &RpcTransport::lineReceived);
    QSignalSpy errors(&transport, &RpcTransport::errorOccurred);
    QCOMPARE(peer->write(QByteArrayLiteral("first\npart")), qint64(10));
    peer->flush();
    QTRY_COMPARE(lines.count(), 1);
    QCOMPARE(lines.at(0).at(0).toString(), QStringLiteral("first"));

    QCOMPARE(peer->write(QByteArrayLiteral("ial\n\n")), qint64(5));
    peer->flush();
    QTRY_COMPARE(lines.count(), 3);
    QCOMPARE(lines.at(1).at(0).toString(), QStringLiteral("partial"));
    QCOMPARE(lines.at(2).at(0).toString(), QString());
    QCOMPARE(errors.count(), 0);
}

void HostTypesTest::rpcTransportRejectsOversizedTerminatedFrame()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QLocalServer server;
    RpcTransport transport;
    QLocalSocket *peer = connectTransport(server, transport,
                                          directory.filePath(QStringLiteral("oversized.sock")));
    QVERIFY2(peer, qPrintable(server.errorString()));

    QSignalSpy lines(&transport, &RpcTransport::lineReceived);
    QSignalSpy errors(&transport, &RpcTransport::errorOccurred);
    QByteArray oversized(kMaximumRpcFrameBytes + 1, 'x');
    oversized.append('\n');
    QCOMPARE(peer->write(oversized), qint64(oversized.size()));
    peer->flush();

    QTRY_VERIFY_WITH_TIMEOUT(!errors.isEmpty(), 15000);
    QCOMPARE(lines.count(), 0);
    QVERIFY(errors.first().first().toString().contains(QStringLiteral("too large"),
                                                       Qt::CaseInsensitive));
    QTRY_VERIFY(!transport.connected());
}

QTEST_GUILESS_MAIN(HostTypesTest)

#include "hosttypes_test.moc"
