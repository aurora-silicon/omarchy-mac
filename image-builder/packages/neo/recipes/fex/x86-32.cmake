# SPDX-License-Identifier: MIT
# Source-backed packaging toolchain for pinned public multiarch development sysroot.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR i686)
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES X86_DEV_ROOTFS)
set(CMAKE_SYSROOT "${X86_DEV_ROOTFS}")
set(CMAKE_C_COMPILER /usr/lib/llvm22/bin/clang)
set(CMAKE_CXX_COMPILER /usr/lib/llvm22/bin/clang++)
set(CMAKE_C_COMPILER_TARGET i686-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET i686-linux-gnu)
set(CMAKE_C_FLAGS_INIT "-B${X86_DEV_ROOTFS}/usr/lib/gcc/x86_64-redhat-linux/16/32")
set(CMAKE_CXX_FLAGS_INIT "-B${X86_DEV_ROOTFS}/usr/lib/gcc/x86_64-redhat-linux/16/32 -isystem ${X86_DEV_ROOTFS}/usr/include/c++/16 -isystem ${X86_DEV_ROOTFS}/usr/include/c++/16/x86_64-redhat-linux/32")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -L${X86_DEV_ROOTFS}/usr/lib/gcc/x86_64-redhat-linux/16/32 -L${X86_DEV_ROOTFS}/usr/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld -L${X86_DEV_ROOTFS}/usr/lib/gcc/x86_64-redhat-linux/16/32 -L${X86_DEV_ROOTFS}/usr/lib")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld -L${X86_DEV_ROOTFS}/usr/lib/gcc/x86_64-redhat-linux/16/32 -L${X86_DEV_ROOTFS}/usr/lib")
# Do not force compiler success: CMake must prove the actual guest ABI/linker.

# Build-tool executables remain native; dependency headers/libraries are guest.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(PKG_CONFIG_EXECUTABLE /usr/bin/pkg-config CACHE FILEPATH "Native pkg-config" FORCE)
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${X86_DEV_ROOTFS}")
set(ENV{PKG_CONFIG_LIBDIR} "${X86_DEV_ROOTFS}/usr/lib/pkgconfig:${X86_DEV_ROOTFS}/usr/share/pkgconfig")
