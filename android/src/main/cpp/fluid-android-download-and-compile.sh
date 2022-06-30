#!/bin/bash
# Android cross-compile environment setup script for Fluidsynth, Glib and dependencies
# Author  : Tom Moebert
# Date    : 2018-09-06
# License : CC0 1.0 Universal
# If you have questions or need support, contact our mailing list:
# https://lists.nongnu.org/mailman/listinfo/fluid-dev

set -ex

# Create a standalone toolchain first, see https://developer.android.com/ndk/guides/standalone_toolchain
#${NDK}/build/tools/make_standalone_toolchain.py --arch ${ANDROID_ARCH} --api ${ANDROID_API} --stl=libc++ --install-dir=${NDK_TOOLCHAIN}

#WARNING:__main__:make_standalone_toolchain.py is no longer necessary. The
#$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin directory contains target-specific scripts that perform
#the same task. For example, instead of:

#    $ python $NDK/build/tools/make_standalone_toolchain.py \
#        --arch arm --api 28 --install-dir toolchain
#    $ toolchain/bin/clang++ src.cpp

#Instead use:

#    $ $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi${ANDROID_API}-clang++ src.cpp

ICONV_VERSION=1.16
wget http://ftp.gnu.org/pub/gnu/libiconv/libiconv-${ICONV_VERSION}.tar.gz
tar zxvf libiconv-${ICONV_VERSION}.tar.gz
pushd libiconv-${ICONV_VERSION}
./configure --host=${TARGET} --prefix=${PREFIX} --disable-rpath
make -j4
make install
popd

FFI_VERSION=3.3
wget ftp://sourceware.org/pub/libffi/libffi-${FFI_VERSION}.tar.gz
tar zxvf libffi-${FFI_VERSION}.tar.gz
pushd libffi-${FFI_VERSION}
# install headers into the conventional ${PREFIX}/include rather than ${PREFIX}/lib/libffi-3.2.1/include.
sed -e '/^includesdir/ s/$(libdir).*$/$(includedir)/' -i include/Makefile.in
sed -e '/^includedir/ s/=.*$/=@includedir@/' -e 's/^Cflags: -I${includedir}/Cflags:/' -i libffi.pc.in
./configure --host=${TARGET} --prefix=${PREFIX} --enable-static
make -j4
make install
popd


GETTEXT_VERSION=0.21
wget http://ftp.gnu.org/pub/gnu/gettext/gettext-${GETTEXT_VERSION}.tar.gz
tar zxvf gettext-${GETTEXT_VERSION}.tar.gz
pushd gettext-${GETTEXT_VERSION}
./configure --host=${TARGET}  --prefix=${PREFIX} --disable-rpath --disable-libasprintf --disable-java --disable-native-java --disable-openmp --disable-curses
make -j4
make install
popd

GLIB_VERSION=2.58 #need to switch to meson build system to use a more recent version 
GLIB_EXTRAVERSION=3
wget http://ftp.gnome.org/pub/gnome/sources/glib/${GLIB_VERSION}/glib-${GLIB_VERSION}.${GLIB_EXTRAVERSION}.tar.xz
tar xvf glib-${GLIB_VERSION}.${GLIB_EXTRAVERSION}.tar.xz
pushd glib-${GLIB_VERSION}.${GLIB_EXTRAVERSION}
cat << EOF > android.cache
glib_cv_long_long_format=ll
glib_cv_stack_grows=no
glib_cv_sane_realloc=yes
glib_cv_have_strlcpy=no
glib_cv_va_val_copy=yes
glib_cv_rtldglobal_broken=no
glib_cv_uscore=no
glib_cv_monotonic_clock=no
ac_cv_func_nonposix_getpwuid_r=no
ac_cv_func_posix_getpwuid_r=no
ac_cv_func_posix_getgrgid_r=no
glib_cv_use_pid_surrogate=yes
ac_cv_func_printf_unix98=no
ac_cv_func_vsnprintf_c99=yes
ac_cv_func_realloc_0_nonnull=yes
ac_cv_func_realloc_works=yes
EOF

chmod a-x android.cache
NOCONFIGURE=true ./autogen.sh
./configure --host=${ANDROID_TARGET} --prefix=${PREFIX} --disable-dependency-tracking --cache-file=android.cache --enable-included-printf --enable-static --with-pcre=no --enable-libmount=no --with-libiconv=gnu
make -j4
make install
popd


OBOE_VERSION=1.6.1
wget https://github.com/google/oboe/archive/${OBOE_VERSION}.tar.gz
tar zxvf ${OBOE_VERSION}.tar.gz
pushd oboe-${OBOE_VERSION}
mkdir -p build
pushd build
cmake -G "Unix Makefiles" -DCMAKE_MAKE_PROGRAM=make \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_NATIVE_API_LEVEL=${ANDROID_API} \
    -DANDROID_ABI=${ANDROID_ABI_CMAKE} \
    -DANDROID_PLATFORM=android-${ANDROID_API} \
    -DBUILD_SHARED_LIBS=0 .. \
    -DCMAKE_VERBOSE_MAKEFILE=1
make -j4
# need to manually install oboe as it doesn't provide an install target
cp liboboe.a* ${PREFIX}/lib/
cp -ur ../include/oboe ${PREFIX}/include
# create a custom pkgconfig file for oboe to allow fluidsynth to find it
cat << EOF > ${PKG_CONFIG_PATH}/oboe-1.0.pc
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Oboe
Description: Oboe library
Version: ${OBOE_VERSION}
Libs: -L\${libdir} -loboe -landroid -llog -lstdc++
Cflags: -I\${includedir}
EOF

popd
popd

FLUIDSYNTH_VERSION=2.2.4
wget https://github.com/FluidSynth/fluidsynth/archive/v${FLUIDSYNTH_VERSION}.tar.gz
tar zxvf v${FLUIDSYNTH_VERSION}.tar.gz
#cp fluid_oboe.cpp fluidsynth-${FLUIDSYNTH_VERSION}/src/drivers/\
pushd fluidsynth-${FLUIDSYNTH_VERSION}
rm -rf build
mkdir -p build
pushd build
cmake -G "Unix Makefiles" -DCMAKE_MAKE_PROGRAM=make \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_NATIVE_API_LEVEL=${ANDROID_API} \
    -DANDROID_ABI=${ANDROID_ABI_CMAKE} \
    -DANDROID_TOOLCHAIN=${CC} \
    -DANDROID_NDK=${NDK} \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} \
    -DCMAKE_VERBOSE_MAKEFILE=1 \
    -Denable-libsndfile=0 \
    -Denable-opensles=1 \
    -Denable-oboe=1 \
    -Denable-dbus=0 \
    -Denable-oss=0 ..
make -j4 || true

#correcting src/gentables/CMakeCache.txt
sed -i s,'^CMAKE_C_FLAGS:STRING=.*','CMAKE_C_FLAGS:STRING=-fPIE -fPIC -I/usr/include -Werror=implicit-function-declaration',g src/gentables/CMakeCache.txt
make -j4


make install
popd
popd
