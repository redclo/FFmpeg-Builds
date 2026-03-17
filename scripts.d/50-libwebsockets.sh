#!/bin/bash

SCRIPT_REPO="https://github.com/warmcat/libwebsockets.git"
SCRIPT_COMMIT="v4.5.4"
SCRIPT_TAGFILTER="v4.5.*"

ffbuild_depends() {
    echo base
    echo zlib
    echo openssl
}

ffbuild_enabled() {
    return 0
}

ffbuild_dockerbuild() {
    mkdir build && cd build

    local myconf=(
        -GNinja
        -DCMAKE_TOOLCHAIN_FILE="$FFBUILD_CMAKE_TOOLCHAIN"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$FFBUILD_PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DLWS_WITH_SHARED=OFF
        -DLWS_WITH_STATIC=ON
        -DLWS_WITH_SSL=OFF
        -DLWS_WITH_ZLIB=OFF
        -DLWS_WITH_PLUGINS=OFF
        -DLWS_WITHOUT_TESTAPPS=ON
        -DLWS_WITH_MINIMAL_EXAMPLES=OFF
    )

    if ! [[ $TARGET == win* || $TARGET == linux* ]]; then
        echo "Unknown target"
        return -1
    fi

    cmake "${myconf[@]}" ..
    ninja -j"$(nproc)"
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    mkdir -p "$FFBUILD_DESTPREFIX"/lib/pkgconfig

    cat >"$FFBUILD_DESTPREFIX"/lib/pkgconfig/libwebsockets.pc <<EOF
prefix=$FFBUILD_PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libwebsockets
Description: lightweight C websockets library
Version: 4.5.4
Cflags: -I\${includedir}
Libs: -L\${libdir} -lwebsockets_static
EOF

    if [[ $TARGET == win* ]]; then
        echo "Libs.private: -lws2_32 -luserenv -liphlpapi -lpsapi" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libwebsockets.pc
    else
        echo "Libs.private: -lpthread -ldl" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libwebsockets.pc
    fi
}

ffbuild_configure() {
    echo --enable-libwebsockets
}

ffbuild_unconfigure() {
    echo --disable-libwebsockets
}
