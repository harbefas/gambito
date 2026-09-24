#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QLocalSocket>
#include <QStandardPaths>
#include <QUrl>
#include <QDebug>
#include <cstdio>
#include <functional>

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

class GambitoFile : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(bool watchChanges READ watchChanges WRITE setWatchChanges NOTIFY watchChangesChanged)
    Q_PROPERTY(QString text READ text NOTIFY textChanged)

public:
    explicit GambitoFile(QObject *parent = nullptr) : QObject(parent), watcher_(new QFileSystemWatcher(this)) {
        connect(watcher_, &QFileSystemWatcher::fileChanged, this, [this] {
            emit fileChanged();
            load();
            if (watch_) watchPath();
        });
    }
    QString path() const { return path_; }
    void setPath(const QString &path) {
        if (path_ == path) return;
        path_ = path;
        emit pathChanged();
        watchPath();
        load();
    }
    bool watchChanges() const { return watch_; }
    void setWatchChanges(bool watch) {
        if (watch_ == watch) return;
        watch_ = watch;
        emit watchChangesChanged();
        watchPath();
    }
    QString text() const { return text_; }
    Q_INVOKABLE void load() {
        QFile file(path_);
        if (!file.open(QIODevice::ReadOnly)) { text_.clear(); emit loadFailed(); return; }
        text_ = QString::fromUtf8(file.readAll());
        emit textChanged();
        emit loaded();
    }

signals:
    void pathChanged();
    void watchChangesChanged();
    void textChanged();
    void loaded();
    void loadFailed();
    void fileChanged();

private:
    void watchPath() {
        const auto files = watcher_->files();
        if (!files.isEmpty()) watcher_->removePaths(files);
        if (watch_ && !path_.isEmpty() && QFile::exists(path_)) watcher_->addPath(path_);
    }
    QString path_;
    QString text_;
    bool watch_ = false;
    QFileSystemWatcher *watcher_;
};

class QtHost : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE QString env(const QString &name) const { return qEnvironmentVariable(name.toUtf8().constData()); }
signals:
    void windowRequested(const QString &game);
    void windowFinished(QObject *window);
public slots:
    void forwardWindowRequest(const QString &game) { emit windowRequested(game); }
    void forwardWindowFinished() { emit windowFinished(sender()); }
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
    app.setDesktopFileName(QStringLiteral("gambito"));

    qmlRegisterType<GambitoSocket>("Gambito.Host", 1, 0, "GambitoSocket");
    qmlRegisterType<GambitoFile>("Gambito.Host", 1, 0, "GambitoFile");
    QtHost host;
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, [](const QList<QQmlError> &errors) {
        for (const auto &error : errors) qWarning().noquote() << error.toString();
    });
    engine.rootContext()->setContextProperty(QStringLiteral("qtHost"), &host);

    const auto root = QCoreApplication::applicationDirPath() + QStringLiteral("/../share/gambito/qt-ui/GambitoWindow.qml");
    const auto source = QFile::exists(root) ? root : QFileInfo(QStringLiteral("ui/GambitoWindow.qml")).absoluteFilePath();
    QQmlComponent component(&engine, QUrl::fromLocalFile(QFileInfo(source).absoluteFilePath()));
    if (component.isError()) {
        for (const auto &error : component.errors()) qWarning().noquote() << error.toString();
        return 1;
    }
    QList<QObject*> windows;
    std::function<void(const QString&)> createWindow;
    QObject::connect(&host, &QtHost::windowRequested, &app, [&](const QString &requested) { createWindow(requested); });
    QObject::connect(&host, &QtHost::windowFinished, &app, [&](QObject *rootObject) {
        windows.removeOne(rootObject);
        if (rootObject) rootObject->deleteLater();
        if (windows.isEmpty()) app.quit();
    });
    createWindow = [&](const QString &game) {
        QVariantMap properties;
        properties.insert(QStringLiteral("initialGame"), game);
        auto *rootObject = component.createWithInitialProperties(properties);
        if (!rootObject) return;
        windows.append(rootObject);
        QObject::connect(rootObject, SIGNAL(requestWindow(QString)), &host, SLOT(forwardWindowRequest(QString)));
        QObject::connect(rootObject, SIGNAL(finished()), &host, SLOT(forwardWindowFinished()));
    };
    QString initialGame = qEnvironmentVariable("GAMBITO_GAME");
    if (app.arguments().size() > 1) initialGame = app.arguments().at(1);
    createWindow(initialGame);
    if (windows.isEmpty()) return 1;
    return app.exec();
}

#include "qt_host.moc"
