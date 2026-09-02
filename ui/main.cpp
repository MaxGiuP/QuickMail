#include "hosttypes.h"

#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QPointer>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QStandardPaths>
#include <QThread>
#include <QTimer>
#include <QtQml>

#include <optional>

namespace {
constexpr auto kApplicationId = "io.github.MaxGiuP.QuickMail";
constexpr int kMaximumCommandBytes = 2 * 1024 * 1024;

struct UiCommand {
    QString name = QStringLiteral("show");
    QString payload;
};

QString runtimeHome()
{
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR").trimmed();
    if (runtime.isEmpty()) {
        runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    }
    return QDir::isAbsolutePath(runtime) ? runtime : QString();
}

QString runtimeDirectory()
{
    const QString runtime = runtimeHome();
    return runtime.isEmpty() ? QString() : runtime + QStringLiteral("/quickmail");
}

QString uiSocketPath()
{
    const QString directory = runtimeDirectory();
    return directory.isEmpty() ? QString() : directory + QStringLiteral("/ui.sock");
}

QByteArray encodeCommand(const UiCommand &command)
{
    const QJsonObject request {
        {QStringLiteral("command"), command.name},
        {QStringLiteral("payload"), command.payload},
    };
    return QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n';
}

std::optional<bool> routeToExisting(const UiCommand &command, int timeoutMs = 300)
{
    QLocalSocket socket;
    socket.connectToServer(uiSocketPath(), QIODevice::ReadWrite);
    if (!socket.waitForConnected(timeoutMs)) return std::nullopt;

    const QByteArray request = encodeCommand(command);
    if (socket.write(request) != request.size() || !socket.waitForBytesWritten(timeoutMs))
        return false;
    if (!socket.waitForReadyRead(qMax(timeoutMs, 1200))) return false;

    const QByteArray responseBytes = socket.readLine(kMaximumCommandBytes);
    const QJsonDocument response = QJsonDocument::fromJson(responseBytes);
    if (!response.isObject()) return false;
    return response.object().value(QStringLiteral("ok")).toBool(false);
}

QString resolveQmlDirectory()
{
    QStringList candidates;
    const QString configured = qEnvironmentVariable("QUICKMAIL_QML_DIR").trimmed();
    if (!configured.isEmpty()) candidates.push_back(configured);
    candidates.push_back(QDir(QCoreApplication::applicationDirPath())
                             .absoluteFilePath(QStringLiteral("../share/quickmail/qml")));
#ifdef QUICKMAIL_SOURCE_QML_DIR
    candidates.push_back(QStringLiteral(QUICKMAIL_SOURCE_QML_DIR));
#endif

    for (const QString &candidate : candidates) {
        const QString normalized = QDir(candidate).absolutePath();
        if (QFileInfo(normalized + QStringLiteral("/StandaloneMain.qml")).isFile())
            return normalized;
    }
    return {};
}

bool parseCommand(QCommandLineParser &parser, UiCommand &command, bool &checkMode,
                  bool &stalledCloseCheck)
{
    const QCommandLineOption accountsOption(QStringLiteral("accounts"),
                                             QStringLiteral("Open account settings."));
    const QCommandLineOption calendarOption(QStringLiteral("calendar"),
                                             QStringLiteral("Open the calendar."));
    const QCommandLineOption checkOption(QStringLiteral("check"),
                                         QStringLiteral("Load the UI offscreen and exit."));
    const QCommandLineOption stalledCloseCheckOption(
        QStringLiteral("check-stalled-close"),
        QStringLiteral("Exercise stalled-draft close recovery offscreen."));
    parser.addOption(accountsOption);
    parser.addOption(calendarOption);
    parser.addOption(checkOption);
    parser.addOption(stalledCloseCheckOption);
    parser.addPositionalArgument(QStringLiteral("mailto"),
                                 QStringLiteral("A mailto: URI to compose."),
                                 QStringLiteral("[mailto:URI]"));
    parser.process(*QCoreApplication::instance());

    const QStringList positional = parser.positionalArguments();
    const int requestCount = (parser.isSet(accountsOption) ? 1 : 0)
        + (parser.isSet(calendarOption) ? 1 : 0) + (positional.isEmpty() ? 0 : 1);
    checkMode = parser.isSet(checkOption) || parser.isSet(stalledCloseCheckOption);
    stalledCloseCheck = parser.isSet(stalledCloseCheckOption);
    if (parser.isSet(checkOption) && stalledCloseCheck) {
        qCritical("Choose only one UI check mode");
        return false;
    }
    if (requestCount > 1 || positional.size() > 1 || (checkMode && requestCount > 0)) {
        qCritical("Choose only one of --accounts, --calendar, or a mailto: URI");
        return false;
    }

    if (parser.isSet(accountsOption)) {
        command.name = QStringLiteral("accounts");
    } else if (parser.isSet(calendarOption)) {
        command.name = QStringLiteral("calendar");
    } else if (!positional.isEmpty()) {
        const QString mailto = positional.first();
        if (!mailto.startsWith(QStringLiteral("mailto:"), Qt::CaseInsensitive)
                || mailto.size() > 262144 || mailto.contains(QChar::Null)) {
            qCritical("The compose request must be a valid bounded mailto: URI");
            return false;
        }
        command.name = QStringLiteral("compose");
        command.payload = mailto;
    }
    return true;
}
} // namespace

class InstanceRouter final : public QObject {
    Q_OBJECT

public:
    explicit InstanceRouter(QString socketPath, QObject *parent = nullptr)
        : QObject(parent), m_socketPath(std::move(socketPath))
    {
        m_server.setSocketOptions(QLocalServer::UserAccessOption);
        connect(&m_server, &QLocalServer::newConnection, this, &InstanceRouter::acceptConnections);
    }

    ~InstanceRouter() override
    {
        m_server.close();
        QLocalServer::removeServer(m_socketPath);
    }

    bool listen()
    {
        QLocalServer::removeServer(m_socketPath);
        if (m_server.listen(m_socketPath)) return true;
        qCritical().noquote() << "Could not create QuickMail UI socket:" << m_server.errorString();
        return false;
    }

    void setRoot(QObject *root)
    {
        m_root = root;
    }

    bool dispatch(const UiCommand &command)
    {
        if (!m_root) return false;
        QVariant accepted;
        const bool invoked = QMetaObject::invokeMethod(
            m_root, "handleCommand", Qt::DirectConnection,
            Q_RETURN_ARG(QVariant, accepted),
            Q_ARG(QVariant, QVariant(command.name)),
            Q_ARG(QVariant, QVariant(command.payload)));
        return invoked && accepted.toBool();
    }

private:
    void acceptConnections()
    {
        while (QLocalSocket *socket = m_server.nextPendingConnection()) {
            socket->setParent(this);
            connect(socket, &QLocalSocket::readyRead, this, [this, socket] {
                QByteArray buffer = socket->property("quickMailBuffer").toByteArray();
                buffer.append(socket->readAll());
                if (buffer.size() > kMaximumCommandBytes) {
                    socket->disconnectFromServer();
                    return;
                }
                const qsizetype newline = buffer.indexOf('\n');
                if (newline < 0) {
                    socket->setProperty("quickMailBuffer", buffer);
                    return;
                }

                const QJsonDocument request = QJsonDocument::fromJson(buffer.left(newline));
                UiCommand command;
                bool valid = request.isObject();
                if (valid) {
                    const QJsonObject object = request.object();
                    command.name = object.value(QStringLiteral("command")).toString();
                    command.payload = object.value(QStringLiteral("payload")).toString();
                    valid = command.name == QStringLiteral("show")
                        || command.name == QStringLiteral("accounts")
                        || command.name == QStringLiteral("calendar")
                        || (command.name == QStringLiteral("compose")
                            && command.payload.startsWith(QStringLiteral("mailto:"),
                                                          Qt::CaseInsensitive)
                            && !command.payload.contains(QChar::Null)
                            && command.payload.size() <= 262144);
                }
                const bool accepted = valid && dispatch(command);
                const QJsonObject response {{QStringLiteral("ok"), accepted}};
                socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact) + '\n');
                socket->flush();
                socket->disconnectFromServer();
            });
            connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
        }
    }

    QString m_socketPath;
    QLocalServer m_server;
    QPointer<QObject> m_root;
};

int main(int argc, char *argv[])
{
    QCoreApplication::setOrganizationName(QStringLiteral("MaxGiuP"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("github.com/MaxGiuP"));
    QCoreApplication::setApplicationName(QStringLiteral("QuickMail"));
    QCoreApplication::setApplicationVersion(QStringLiteral(QUICKMAIL_VERSION));
    QGuiApplication::setDesktopFileName(QString::fromLatin1(kApplicationId));

    QGuiApplication application(argc, argv);
    QGuiApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("mail-unread")));
    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("QuickMail standalone Qt interface"));
    parser.addHelpOption();
    parser.addVersionOption();

    UiCommand startupCommand;
    bool checkMode = false;
    bool stalledCloseCheck = false;
    if (!parseCommand(parser, startupCommand, checkMode, stalledCloseCheck)) return 2;

    const bool exerciseNativeClose = checkMode
        && QGuiApplication::platformName() == QStringLiteral("offscreen");
    if (stalledCloseCheck && !exerciseNativeClose) {
        qCritical("--check-stalled-close requires the offscreen Qt platform");
        return 2;
    }
    const QString checkRuntime = checkMode ? runtimeHome() : QString();
    const QString checkSocketPath = checkRuntime.isEmpty()
        ? QString()
        : checkRuntime + QStringLiteral("/quickmail/check-%1.sock")
            .arg(QCoreApplication::applicationPid());
    if (checkMode && !QDir::isAbsolutePath(checkSocketPath)) {
        qCritical("UI checks require a private per-user runtime directory");
        return 2;
    }

    const QString qmlDirectory = resolveQmlDirectory();
    if (qmlDirectory.isEmpty()) {
        qCritical("Could not find QuickMail's StandaloneMain.qml");
        return 1;
    }

    if (!checkMode && runtimeDirectory().isEmpty()) {
        qCritical("QuickMail requires a private per-user runtime directory");
        return 1;
    }

    if (!checkMode) {
        if (const std::optional<bool> routed = routeToExisting(startupCommand); routed.has_value())
            return *routed ? 0 : 1;
        if (!QDir().mkpath(runtimeDirectory())
                || !QFile::setPermissions(runtimeDirectory(),
                    QFileDevice::ReadOwner | QFileDevice::WriteOwner
                        | QFileDevice::ExeOwner)) {
            qCritical("Could not secure QuickMail's private runtime directory");
            return 1;
        }
    }

    std::optional<QLockFile> instanceLock;
    std::optional<InstanceRouter> router;
    if (!checkMode) {
        instanceLock.emplace(runtimeDirectory() + QStringLiteral("/ui.lock"));
        instanceLock->setStaleLockTime(0);
        if (!instanceLock->tryLock(150)) {
            for (int attempt = 0; attempt < 10; ++attempt) {
                if (const std::optional<bool> routed = routeToExisting(startupCommand, 200);
                        routed.has_value()) {
                    return *routed ? 0 : 1;
                }
                QThread::msleep(50);
            }
            qCritical("Another QuickMail UI process is starting but did not become ready");
            return 1;
        }
        router.emplace(uiSocketPath());
        if (!router->listen()) return 1;
    }

    qmlRegisterType<HostSettingsStore>("QuickMail.Host", 1, 0, "SettingsStore");
    qmlRegisterSingletonType<PlatformBridge>(
        "QuickMail.Host", 1, 0, "PlatformBridge",
        [](QQmlEngine *engine, QJSEngine *) -> QObject * {
            return new PlatformBridge(engine);
        });
    qmlRegisterType<RpcTransport>("QuickMail.Host", 1, 0, "RpcTransport");
    qmlRegisterType<ProcessRunner>("QuickMail.Host", 1, 0, "ProcessRunner");
    qmlRegisterType<FileReader>("QuickMail.Host", 1, 0, "FileReader");

    QQmlApplicationEngine engine;
    engine.addImportPath(qmlDirectory);
    engine.rootContext()->setContextProperty(QStringLiteral("quickMailCheckMode"), checkMode);
    engine.rootContext()->setContextProperty(QStringLiteral("quickMailExerciseNativeClose"),
                                             exerciseNativeClose);
    engine.rootContext()->setContextProperty(QStringLiteral("quickMailCloseTimeoutMs"),
                                             stalledCloseCheck ? 300 : 10000);
    engine.rootContext()->setContextProperty(QStringLiteral("quickMailDaemonSocketOverride"),
                                             checkSocketPath);
    engine.rootContext()->setContextProperty(
        QStringLiteral("quickMailHyprlandAvailable"),
        !qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE").isEmpty());

    bool loadFailed = false;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &application, [&loadFailed] { loadFailed = true; });
    engine.load(QUrl::fromLocalFile(qmlDirectory + QStringLiteral("/StandaloneMain.qml")));
    if (loadFailed || engine.rootObjects().isEmpty()) return 1;

    QObject *root = engine.rootObjects().constFirst();
    if (router) {
        router->setRoot(root);
        if (!router->dispatch(startupCommand)) return 1;
    }

    bool stalledCloseCheckPassed = false;
    if (stalledCloseCheck) {
        QTimer::singleShot(100, root, [root, &application] {
            QVariant accepted;
            const bool commandInvoked = QMetaObject::invokeMethod(
                root, "handleCommand", Qt::DirectConnection,
                Q_RETURN_ARG(QVariant, accepted),
                Q_ARG(QVariant, QVariant(QStringLiteral("compose"))),
                Q_ARG(QVariant, QVariant(QStringLiteral(
                    "mailto:stalled-close@example.test?subject=Close%20recovery"))));
            const bool closeInvoked = QMetaObject::invokeMethod(
                root, "close", Qt::DirectConnection);
            if (commandInvoked && accepted.toBool() && closeInvoked) return;
            qCritical("Could not start the stalled-draft close check");
            application.exit(1);
        });
        QTimer::singleShot(200, root, [root, &application] {
            const bool visible = root->property("visible").toBool();
            const bool pending = root->property("closePending").toBool();
            const bool composeVisible = root->property("composeVisible").toBool();
            if (visible && pending && composeVisible) return;
            qCritical("A pending draft close did not remain visible and recoverable");
            application.exit(1);
        });
        QTimer::singleShot(600, root,
                           [root, &application, &stalledCloseCheckPassed] {
            const bool visible = root->property("visible").toBool();
            const bool pending = root->property("closePending").toBool();
            const bool composeVisible = root->property("composeVisible").toBool();
            const QString recipient = root->property("composeRecipientText").toString();
            if (!visible || pending || !composeVisible
                    || recipient != QStringLiteral("stalled-close@example.test")) {
                qCritical("Stalled-draft close recovery did not preserve the composer");
                application.exit(1);
                return;
            }
            stalledCloseCheckPassed = true;
            application.exit(0);
        });
    } else if (checkMode) {
        QTimer::singleShot(100, root, [root, &application] {
            const char *method = root->property("visible").toBool()
                ? "close" : "requestApplicationClose";
            if (QMetaObject::invokeMethod(root, method, Qt::DirectConnection)) return;
            qCritical("Could not exercise the standalone window close path");
            application.exit(1);
        });
    }
    if (checkMode) {
        QTimer::singleShot(2000, &application, [&application] {
            qCritical("The standalone window close path did not exit");
            application.exit(1);
        });
    }
    const int exitCode = application.exec();
    return stalledCloseCheck && !stalledCloseCheckPassed ? 1 : exitCode;
}

#include "main.moc"
