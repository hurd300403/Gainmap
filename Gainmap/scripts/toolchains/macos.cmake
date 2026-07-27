# macOS slice. A toolchain file (rather than -D args) so the deployment
# target and arch reach the libjpeg-turbo sub-build the same way as on iOS.
set(CMAKE_OSX_SYSROOT macosx)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
