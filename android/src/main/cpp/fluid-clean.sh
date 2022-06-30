set -ex

ICONV_VERSION=1.16
pushd libiconv-${ICONV_VERSION}
make clean
popd

FFI_VERSION=3.3
pushd libffi-${FFI_VERSION}
make clean
popd


GETTEXT_VERSION=0.21
pushd gettext-${GETTEXT_VERSION}
make clean
popd

GLIB_VERSION=2.58 #need to switch to meson build system to use a more recent version 
GLIB_EXTRAVERSION=3
pushd glib-${GLIB_VERSION}.${GLIB_EXTRAVERSION}
make clean
popd


OBOE_VERSION=1.6.1
pushd oboe-${OBOE_VERSION}
rm -rf build
mkdir -p build
pushd build
make clean
popd
popd

FLUIDSYNTH_VERSION=2.2.4
pushd fluidsynth-${FLUIDSYNTH_VERSION}
rm -rf build
mkdir -p build
pushd build
make clean
popd
popd
