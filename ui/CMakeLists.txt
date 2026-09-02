cmake_minimum_required(VERSION 3.22)

project(quickmail-ui VERSION 0.1.0 LANGUAGES CXX)

find_package(Qt6 6.8 REQUIRED COMPONENTS
    Core Gui Multimedia Network PdfQuick Qml Quick QuickControls2
)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(quickmail-ui
    main.cpp
    hosttypes.cpp
    hosttypes.h
)

target_compile_features(quickmail-ui PRIVATE cxx_std_20)
target_compile_definitions(quickmail-ui PRIVATE
    QUICKMAIL_SOURCE_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../qml"
    QUICKMAIL_VERSION="${PROJECT_VERSION}"
)
target_link_libraries(quickmail-ui PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Multimedia
    Qt6::Network
    Qt6::PdfQuick
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
)

install(TARGETS quickmail-ui RUNTIME DESTINATION bin)

include(CTest)
if(BUILD_TESTING)
    find_package(Qt6 6.8 REQUIRED COMPONENTS Test)
    qt_add_executable(quickmail-hosttypes-test
        tests/hosttypes_test.cpp
        hosttypes.cpp
        hosttypes.h
    )
    target_compile_features(quickmail-hosttypes-test PRIVATE cxx_std_20)
    target_link_libraries(quickmail-hosttypes-test PRIVATE
        Qt6::Core
        Qt6::Network
        Qt6::Test
    )
    add_test(NAME quickmail-hosttypes COMMAND quickmail-hosttypes-test)
endif()
