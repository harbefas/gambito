import QtQml

QtObject {
    signal read(string data)
    function feed(data) { read(data); }
}
