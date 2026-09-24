# Standalone Qt host

This directory contains the standalone Qt Quick host for Gambito. It keeps the
Rust daemon and its Unix socket protocol unchanged and uses `QQmlApplicationEngine`
with small Qt socket and file-watcher bridges.

Build and smoke-test it from the repository:

```sh
cmake -S standalone -B target/qt-build -DCMAKE_BUILD_TYPE=Release
cmake --build target/qt-build -j2
QT_QPA_PLATFORM=offscreen timeout 5s target/qt-build/gambito-qt
```

Install it for the current user with:

```sh
cmake --install target/qt-build --prefix "$HOME/.local"
```

The installed `gambito-qt` entry uses the same Rust daemon service and can be
launched from any desktop menu. Pass a game id as the first argument to open it
directly, for example `gambito-qt abc12345`.

The daemon, QML views and IPC messages are shared across every window. The host
supports multiple windows, live theme files and normal desktop installation.
