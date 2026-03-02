cmake_minimum_required(VERSION 3.16)
project(SecurityEngine CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Windows DLL ターゲット
add_library(SecurityEngine SHARED
    src/SecurityEngine.cpp
)

target_include_directories(SecurityEngine PRIVATE include)

# Windows 専用ライブラリ
if(WIN32)
    target_link_libraries(SecurityEngine
        advapi32
        shlwapi
        shell32
    )
    target_compile_definitions(SecurityEngine PRIVATE SECURITYENGINE_EXPORTS)
endif()

# インストール設定
install(TARGETS SecurityEngine
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)
install(FILES include/SecurityEngine.h DESTINATION include)
