# iOS device slice. Everything platform-shaped must live in this file:
# libultrahdr forwards only CMAKE_TOOLCHAIN_FILE into the libjpeg-turbo
# ExternalProject sub-build (UHDR_CMAKE_ARGS), not the individual OSX vars.
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
# try_compile of an executable would attempt to link an iOS app binary;
# a static library is enough to prove the compiler works.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
