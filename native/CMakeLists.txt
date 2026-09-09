cmake_minimum_required(VERSION 3.18)
project(patch_store_io LANGUAGES C)

# Apple embeds this archive in the signed app/Engine. ELF platforms package a
# shared library which Dart opens by its fixed, app-bundled soname.
if(APPLE)
  add_library(patch_store_io STATIC patch_store_io.c)
  foreach(symbol open_root close lock unlock read replace free)
    # FFI references are strings, invisible to the native dead-strip pass.
    target_link_options(patch_store_io INTERFACE "LINKER:-u,_psio_${symbol}")
  endforeach()
else()
  add_library(patch_store_io SHARED patch_store_io.c)
  target_link_options(patch_store_io PRIVATE "LINKER:--no-undefined")
  if(ANDROID)
    target_link_options(patch_store_io PRIVATE "LINKER:-z,max-page-size=16384")
  endif()
endif()
target_compile_features(patch_store_io PRIVATE c_std_11)
target_compile_options(patch_store_io PRIVATE -Wall -Wextra -Werror)
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  # The SDK C toolchain injects --gcc-toolchain even for its own Clang sysroot.
  target_compile_options(patch_store_io PRIVATE -Wno-unused-command-line-argument)
endif()
set_target_properties(patch_store_io PROPERTIES
  C_VISIBILITY_PRESET hidden POSITION_INDEPENDENT_CODE ON)
target_include_directories(patch_store_io PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

option(PSIO_BUILD_LINK_CHECK "Build a dead-strip/FFI symbol lookup check" OFF)
if(PSIO_BUILD_LINK_CHECK)
  add_executable(patch_store_link_check patch_store_link_check.c)
  if(APPLE)
    target_link_libraries(patch_store_link_check PRIVATE patch_store_io)
    target_link_options(patch_store_link_check PRIVATE "LINKER:-dead_strip")
  else()
    target_link_libraries(patch_store_link_check PRIVATE ${CMAKE_DL_LIBS})
  endif()
endif()
