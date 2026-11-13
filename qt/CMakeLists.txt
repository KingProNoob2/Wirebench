cmake_minimum_required(VERSION 3.21)
project(WirebenchQt LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Quick Qml QuickControls2 ShaderTools)
qt_standard_project_setup(REQUIRES 6.5)

# The Swift side, built by tools/build-qt.sh: libWirebenchBridge and its header.
set(WIREBENCH_BRIDGE_DIR "" CACHE PATH "Directory holding libWirebenchBridge")
set(WIREBENCH_BRIDGE_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/WirebenchBridge/include")
find_library(WIREBENCH_BRIDGE WirebenchBridge PATHS "${WIREBENCH_BRIDGE_DIR}" NO_DEFAULT_PATH REQUIRED)

qt_add_executable(wirebench-qt src/main.cpp src/Controller.cpp src/JsonListModel.cpp)
target_include_directories(wirebench-qt PRIVATE "${WIREBENCH_BRIDGE_INCLUDE}" src)
target_link_libraries(wirebench-qt PRIVATE Qt6::Quick Qt6::Qml Qt6::QuickControls2 "${WIREBENCH_BRIDGE}")
set_target_properties(wirebench-qt PROPERTIES BUILD_RPATH "${WIREBENCH_BRIDGE_DIR}" INSTALL_RPATH "$ORIGIN")

# The dot grid's fragment shader, compiled for every graphics API at build time.
qt_add_shaders(wirebench-qt "wirebench_shaders" BATCHABLE PRECOMPILE OPTIMIZED PREFIX "/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/shaders" FILES shaders/grid.frag shaders/gauss.frag shaders/glass.frag)

set_source_files_properties(qml/AppTheme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(wirebench-qt
    URI Wirebench
    VERSION 1.0
    QML_FILES qml/Main.qml qml/AppTheme.qml qml/BlockCard.qml qml/Wire.qml qml/SheetGrid.qml qml/BlockLibrary.qml qml/Inspector.qml qml/Icon.qml qml/IconButton.qml qml/Panel.qml qml/SmoothRect.qml qml/MainMenu.qml qml/TextPrompt.qml qml/ConfirmDialog.qml qml/CardFrame.qml qml/ConfigDialog.qml qml/BuildDialog.qml qml/SettingsDialog.qml qml/PLCConfigDialog.qml qml/PopupList.qml qml/GraphicItem.qml qml/AgentWindow.qml qml/HelpWindow.qml qml/MaraflowGraphicItem.qml qml/MaraflowPageCard.qml qml/MaraflowSTDialog.qml
    RESOURCE_PREFIX /qt/qml
)
