@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0\.."

echo === Building rPlayHub Android Windows GUI with MSVC ===

call "%USERPROFILE%\tools\portable-msvc\msvc\setup_x64.bat"

if not exist build\msvc mkdir build\msvc

set DEPS=..\rPlayHub\deps
set CXXFLAGS=/nologo /c /O2 /Oi /Ot /MD /std:c++17 /EHsc /W3 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS /DRPLAYHUB_VERSION=\"1.1.2\" /Ilinux\src /I%DEPS%\ffmpeg-dist\include /I%DEPS%\sdl2\include /I%DEPS%\imgui /I%DEPS%\imgui\backends

echo Compiling network sources...
cl %CXXFLAGS% linux\src\net\tcp_socket.cc /Fo:build\msvc\tcp_socket.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\net\tcp_listener.cc /Fo:build\msvc\tcp_listener.obj
if errorlevel 1 exit /b 1

echo Compiling ADB and protocol sources...
cl %CXXFLAGS% linux\src\adb\adb_client.cc /Fo:build\msvc\adb_client.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\protocol\base128.cc /Fo:build\msvc\base128.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\protocol\control_messages.cc /Fo:build\msvc\control_messages.obj
if errorlevel 1 exit /b 1

echo Compiling session sources...
cl %CXXFLAGS% linux\src\session\agent_session.cc /Fo:build\msvc\agent_session.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\session\app_catalog.cc /Fo:build\msvc\app_catalog.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\session\emulator_launcher.cc /Fo:build\msvc\emulator_launcher.obj
if errorlevel 1 exit /b 1

echo Compiling video and audio sources...
cl %CXXFLAGS% linux\src\video\video_decoder.cc /Fo:build\msvc\video_decoder.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\video\stream_recorder.cc /Fo:build\msvc\stream_recorder.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\audio\audio_player.cc /Fo:build\msvc\audio_player.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\util\png_decode.cc /Fo:build\msvc\png_decode.obj
if errorlevel 1 exit /b 1

echo Compiling UI sources...
cl %CXXFLAGS% linux\src\ui\window_effects.cc /Fo:build\msvc\window_effects.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\ui\display_window.cc /Fo:build\msvc\display_window.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\ui\twin_view.cc /Fo:build\msvc\twin_view.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\ui\fold_view.cc /Fo:build\msvc\fold_view.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% linux\src\ui\gui_app.cc /Fo:build\msvc\gui_app.obj
if errorlevel 1 exit /b 1

echo Compiling main.cc...
cl %CXXFLAGS% linux\src\main.cc /Fo:build\msvc\main.obj
if errorlevel 1 exit /b 1

echo Compiling ImGui sources...
cl %CXXFLAGS% %DEPS%\imgui\imgui.cpp /Fo:build\msvc\imgui.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% %DEPS%\imgui\imgui_draw.cpp /Fo:build\msvc\imgui_draw.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% %DEPS%\imgui\imgui_tables.cpp /Fo:build\msvc\imgui_tables.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% %DEPS%\imgui\imgui_widgets.cpp /Fo:build\msvc\imgui_widgets.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% %DEPS%\imgui\backends\imgui_impl_sdl2.cpp /Fo:build\msvc\imgui_impl_sdl2.obj
if errorlevel 1 exit /b 1
cl %CXXFLAGS% %DEPS%\imgui\backends\imgui_impl_sdlrenderer2.cpp /Fo:build\msvc\imgui_impl_sdlrenderer2.obj
if errorlevel 1 exit /b 1

echo Linking rplayhub-android.exe...
link /nologo /SUBSYSTEM:CONSOLE ^
    build\msvc\tcp_socket.obj ^
    build\msvc\tcp_listener.obj ^
    build\msvc\adb_client.obj ^
    build\msvc\base128.obj ^
    build\msvc\control_messages.obj ^
    build\msvc\agent_session.obj ^
    build\msvc\app_catalog.obj ^
    build\msvc\emulator_launcher.obj ^
    build\msvc\video_decoder.obj ^
    build\msvc\stream_recorder.obj ^
    build\msvc\audio_player.obj ^
    build\msvc\png_decode.obj ^
    build\msvc\window_effects.obj ^
    build\msvc\display_window.obj ^
    build\msvc\twin_view.obj ^
    build\msvc\fold_view.obj ^
    build\msvc\gui_app.obj ^
    build\msvc\main.obj ^
    build\msvc\imgui.obj ^
    build\msvc\imgui_draw.obj ^
    build\msvc\imgui_tables.obj ^
    build\msvc\imgui_widgets.obj ^
    build\msvc\imgui_impl_sdl2.obj ^
    build\msvc\imgui_impl_sdlrenderer2.obj ^
    %DEPS%\sdl2\lib\x64\SDL2.lib ^
    %DEPS%\sdl2\lib\x64\SDL2main.lib ^
    %DEPS%\ffmpeg-dist\lib\avcodec.lib ^
    %DEPS%\ffmpeg-dist\lib\avformat.lib ^
    %DEPS%\ffmpeg-dist\lib\avutil.lib ^
    %DEPS%\ffmpeg-dist\lib\swscale.lib ^
    %DEPS%\ffmpeg-dist\lib\swresample.lib ^
    ws2_32.lib shell32.lib comdlg32.lib user32.lib gdi32.lib ole32.lib advapi32.lib bcrypt.lib secur32.lib winmm.lib dwmapi.lib ^
    /OUT:rplayhub-android.exe
if errorlevel 1 exit /b 1

echo Copying runtime DLLs and assets...
copy /y %DEPS%\sdl2\lib\x64\SDL2.dll . >nul
if not exist fonts mkdir fonts
copy /y linux\fonts\*.ttf fonts\ >nul

echo Build complete: rplayhub-android.exe
