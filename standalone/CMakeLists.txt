cmake_minimum_required(VERSION 3.24)
project(gambito-qt LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick Network)

add_executable(gambito-qt qt_host.cpp)
target_link_libraries(gambito-qt PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network)

install(TARGETS gambito-qt RUNTIME DESTINATION bin)
install(DIRECTORY ui/ DESTINATION share/gambito/qt-ui FILES_MATCHING PATTERN "*.qml" PATTERN "qmldir")
