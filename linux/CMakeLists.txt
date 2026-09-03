cmake_minimum_required(VERSION 3.16)
project(rplayhub-android-linux CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)

pkg_check_modules(SDL2 REQUIRED sdl2)
pkg_check_modules(AVCODEC REQUIRED libavcodec)
pkg_check_modules(AVFORMAT REQUIRED libavformat)
pkg_check_modules(SWSCALE REQUIRED libswscale)
pkg_check_modules(AVUTIL REQUIRED libavutil)

# Fetch Dear ImGui automatically at configure time
include(FetchContent)
FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG        v1.91.8
)
FetchContent_MakeAvailable(imgui)

# Build Dear ImGui with SDL2 and SDLRenderer backends as static library
add_library(imgui STATIC
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_sdl2.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_sdlrenderer2.cpp
)
target_include_directories(imgui PUBLIC
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
    ${SDL2_INCLUDE_DIRS}
)
target_link_libraries(imgui PUBLIC ${SDL2_LIBRARIES})

include_directories(
    src
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
    ${SDL2_INCLUDE_DIRS}
    ${AVCODEC_INCLUDE_DIRS}
    ${AVFORMAT_INCLUDE_DIRS}
    ${SWSCALE_INCLUDE_DIRS}
    ${AVUTIL_INCLUDE_DIRS}
)

set(SOURCES
    src/main.cc
    src/net/tcp_socket.cc
    src/net/tcp_listener.cc
    src/adb/adb_client.cc
    src/protocol/base128.cc
    src/protocol/control_messages.cc
    src/video/video_decoder.cc
    src/session/agent_session.cc
    src/ui/gui_app.cc
)

add_executable(rplayhub-android-linux ${SOURCES})

target_link_libraries(rplayhub-android-linux PRIVATE
    imgui
    ${SDL2_LIBRARIES}
    ${AVCODEC_LIBRARIES}
    ${AVFORMAT_LIBRARIES}
    ${SWSCALE_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    Threads::Threads
)

add_executable(test_session
    src/test_session.cc
    src/net/tcp_socket.cc
    src/net/tcp_listener.cc
    src/adb/adb_client.cc
    src/protocol/base128.cc
    src/protocol/control_messages.cc
    src/video/video_decoder.cc
    src/session/agent_session.cc
)

target_link_libraries(test_session PRIVATE
    ${AVCODEC_LIBRARIES}
    ${AVFORMAT_LIBRARIES}
    ${SWSCALE_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    Threads::Threads
)
