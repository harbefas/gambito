#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QFile>
#include <QFileInfo>
#include <QLocalSocket>
#include <QStandardPaths>
#include <QUrl>
#include <QDebug>
#include <cstdio>

static void logMessage(QtMsgType, const QMessageLogContext &, const QString &message) {
    std::fprintf(stderr, "%s\n", message.toUtf8().constData());
}

class GambitoSocket : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString socketPath READ socketPath WRITE setSocketPath NOTIFY socketPathChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)

public:
    explicit GambitoSocket(QObject *parent = nullptr) : QObject(parent), socket_(new QLocalSocket(this)) {
        connect(socket_, &QLocalSocket::readyRead, this, &GambitoSocket::readLines);
        connect(socket_, &QLocalSocket::connected, this, &GambitoSocket::connectedChanged);
        connect(socket_, &QLocalSocket::disconnected, this, &GambitoSocket::connectedChanged);
    }

    QString socketPath() const { return path_; }
    void setSocketPath(const QString &path) {
        if (path_ == path) return;
        path_ = path;
        emit socketPathChanged();
        connectNow();
    }
    bool connected() const { return socket_->state() == QLocalSocket::ConnectedState; }

    Q_INVOKABLE void connectNow() {
        if (path_.isEmpty() || connected()) return;
        socket_->abort();
        socket_->connectToServer(path_);
    }
    Q_INVOKABLE void write(const QString &text) {
        if (!connected()) { connectNow(); return; }
        socket_->write(text.toUtf8());
        socket_->flush();
    }

signals:
    void lineReceived(const QString &line);
    void socketPathChanged();
    void connectedChanged();

private slots:
    void readLines() {
        buffer_ += socket_->readAll();
        while (true) {
            const auto end = buffer_.indexOf('\n');
            if (end < 0) break;
            const auto line = buffer_.left(end).trimmed();
            buffer_.remove(0, end + 1);
            if (!line.isEmpty()) emit lineReceived(QString::fromUtf8(line));
        }
    }

private:
    QString path_;
    QByteArray buffer_;
    QLocalSocket *socket_;
};

class QtHost : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE QString env(const QString &name) const { return qEnvironmentVariable(name.toUtf8().constData()); }
};

static QString defaultSocketPath() {
    const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    return (runtime.isEmpty() ? QStringLiteral("/tmp") : runtime) + QStringLiteral("/gambito/socket");
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    qInstallMessageHandler(logMessage);
    app.setApplicationName(QStringLiteral("Gambito"));
    app.setApplicationDisplayName(QStringLiteral("Gambito"));

    qmlRegisterType<GambitoSocket>("Gambito.Host", 1, 0, "GambitoSocket");
    QtHost host;
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, [](const QList<QQmlError> &errors) {
        for (const auto &error : errors) qWarning().noquote() << error.toString();
    });
    engine.rootContext()->setContextProperty(QStringLiteral("qtHost"), &host);

    const auto root = QCoreApplication::applicationDirPath() + QStringLiteral("/../share/gambito/qt-ui/GambitoWindow.qml");
    const auto source = QFile::exists(root) ? root : QStringLiteral("standalone/ui/GambitoWindow.qml");
    engine.load(QUrl::fromLocalFile(QFileInfo(source).absoluteFilePath()));
    if (engine.rootObjects().isEmpty()) return 1;
    if (const auto game = qEnvironmentVariable("GAMBITO_GAME"); !game.isEmpty())
        engine.rootObjects().first()->setProperty("initialGame", game);
    QObject::connect(engine.rootObjects().first(), SIGNAL(finished()), &app, SLOT(quit()));
    return app.exec();
}

#include "qt_host.moc"
