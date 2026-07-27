# iOS simulator slice (Apple Silicon hosts only — no x86_64 slice by design,
# matching the app's arm64-only support).
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphonesimulator)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
