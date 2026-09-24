# Standalone Qt host

This directory contains the first standalone Qt Quick host for Gambito. It keeps
the Rust daemon and its Unix socket protocol unchanged while replacing the
QuickShell window host with `QQmlApplicationEngine` and a small Qt socket bridge.

Build and smoke-test it from the repository:

```sh
cmake -S standalone -B target/qt-build -DCMAKE_BUILD_TYPE=Release
cmake --build target/qt-build -j2
QT_QPA_PLATFORM=offscreen timeout 5s target/qt-build/gambito-qt
```

The current host is intentionally parallel to the QuickShell launcher while the
remaining host-specific features (multiple windows, live theme file watching and
desktop integration) are moved across. The daemon, QML views and IPC messages
remain shared during this transition.
