#!/bin/bash
# Android cross-compile environment setup script for Glib
# Author  : Zengwen Yuan
# Date    : 2016-07-16
# License : Creative Commons Attribution-ShareAlike 4.0
# http://zwyuan.github.io/2016/07/17/cross-compile-glib-for-android/
#
# Modified by Tom Moebert to provide an Android cross compilation toolchain for fluidsynth 2.0
# Date: 2018-09-06

# Set Android target arch
export ARCH=x86_64 #arm, aarch64, i686, x86_64
export ANDROID_ARCH=x86_64 # armv7a, aarch64, i686, x86_64
# the target to be used by cmake, keep both in sync!
# https://developer.android.com/ndk/guides/cmake
export ANDROID_ABI_CMAKE=x86_64 #armeabi-v7a, arm64-v8a, x86, x86_64
export ANDROID_TARGET_ABI= #eabi, (nothing), (nothing), (nothing)


# Android NDK sources and standalone toolchain is put here
export DEV=${PWD}

# This is a symlink pointing to the real Android NDK r10e
export NDK=${DEV}/android-ndk

# All the built binaries, libs and their headers will be installed here
export PREFIX=${DEV}/opt/android-${ANDROID_ARCH}

# The path of standalone NDK toolchain
# Refer to https://developer.android.com/ndk/guides/standalone_toolchain.html
export NDK_TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/

# Don't mix up .pc files from your host and build target
export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
# setting PKG_CONFIG_PATH alone does not seem to be enough to avoid mixing up with the host, also set PKG_CONFIG_LIBDIR
export PKG_CONFIG_LIBDIR=${PKG_CONFIG_PATH}

# Set Android target API level
# when compiling with clang use at least 28 as this makes sure that android provides the posix_spawn functions, so the compilation of gettext will (should) work out of the box
# it's probably a bug of gettext, if posix_spawn is not available it replaces it with its own implementation. Autotools of gettext set HAVE_POSIX_SPAWN==0 (which is correct) but for some reason REPLACE_POSIX_SPAWN==0 (which is wrong, as it should be 1).
# 
# NOTE: With NDK r21d and updated packages everything is fine using api 23. Using api 28 makes the generated library not compatible with android 8 and below devices (missing some symbols in system libraries)
export ANDROID_API=23



# The cross-compile toolchain we use
export ANDROID_TARGET=${ARCH}-linux-android${ANDROID_TARGET_ABI}
export ANDROID_TARGET_API=${ANDROID_ARCH}-linux-android${ANDROID_TARGET_ABI}${ANDROID_API}

# the --target to be used by autotools
export TARGET=${ARCH}-eabi

# Add the standalone toolchain to the search path.
export PATH=$PATH:${PREFIX}/bin:${PREFIX}/lib:${PREFIX}/include:${NDK_TOOLCHAIN}/bin

# Tell configure what tools to use.
export AR=${ANDROID_TARGET}-ar
export AS=${ANDROID_TARGET_API}-clang
export CC=${ANDROID_TARGET_API}-clang
export CXX=${ANDROID_TARGET_API}-clang++
export LD=${ANDROID_TARGET}-ld
export STRIP=${ANDROID_TARGET}-strip
export RANLIB=${ANDROID_TARGET}-ranlib

# Tell configure what flags Android requires.
# Using C99 for all compilations by default. Turn Wimplicit-function-declaration into errors. Else autotools will be fooled when checking for available functions (that in fact are NOT available) and compilation will fail later on.
# Also disable clangs integrated assembler, as the hand written assembly of libffi is not recognized by it, cf. https://crbug.com/801303
export CFLAGS="-fPIE -fPIC -I${PREFIX}/include --sysroot=${NDK_TOOLCHAIN}/sysroot -I${NDK_TOOLCHAIN}/sysroot/include -Werror=implicit-function-declaration -fno-integrated-as"
export CXXFLAGS=${CFLAGS}
export CPPFLAGS=${CFLAGS}
export LDFLAGS="-pie -Wl,-rpath-link=-I${NDK_TOOLCHAIN}/sysroot/usr/lib -L${NDK_TOOLCHAIN}/sysroot/usr/lib -L${PREFIX}/lib -L${NDK_TOOLCHAIN}/lib"
