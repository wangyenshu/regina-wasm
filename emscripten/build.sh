#!/usr/bin/env bash

set -eux

BASEDIR="$(pwd)"
EXTERN_DIR="$BASEDIR/extern"

AUX_BUILD="$EXTERN_DIR/emscripten/build"
AUX_PREFIX="$EXTERN_DIR/emscripten/install"

mkdir -p "$AUX_BUILD"
mkdir -p "$AUX_PREFIX/lib"
mkdir -p "$AUX_PREFIX/include"

echo "Checking native host dependencies..."
for tool in cmake pkg-config doxygen xsltproc python3 hg autoconf automake libtool make; do
    if ! command -v $tool &> /dev/null; then
        echo "ERROR: Missing HOST dependency: $tool. Please install it natively via apt/brew."
        exit 1
    fi
done

# ==============================================================================
# TOOLCHAIN SETUP: Emscripten & Qt 6
# ==============================================================================
EMSDK_VERSION="4.0.7"
QT_VERSION="6.11.1"

# --- Emscripten SDK ---
if [[ ! -d "$EXTERN_DIR/emsdk" ]]; then
    echo "Downloading Emscripten SDK..."
    git clone https://github.com/emscripten-core/emsdk.git "$EXTERN_DIR/emsdk"
fi

cd "$EXTERN_DIR/emsdk"
if [[ ! -f ".emsdk_version" ]] || [[ $(<".emsdk_version") != "$EMSDK_VERSION" ]]; then
    echo "Installing Emscripten $EMSDK_VERSION..."
    ./emsdk install "$EMSDK_VERSION"
    ./emsdk activate "$EMSDK_VERSION"
    echo "$EMSDK_VERSION" > ".emsdk_version"
fi

# Source Emscripten into the current shell so 'emcmake' and 'emmake' become available
source "$EXTERN_DIR/emsdk/emsdk_env.sh"
cd "$BASEDIR"

# --- Qt 6 WebAssembly SDK ---
# We use aqtinstall to download pre-compiled Qt binaries instead of building Qt from source.
QT_INSTALL_DIR="$EXTERN_DIR/qt"
QT_HOST_DIR="$QT_INSTALL_DIR/$QT_VERSION/gcc_64"
QT_WASM_DIR="$QT_INSTALL_DIR/$QT_VERSION/wasm_multithread"

if [[ ! -d "$QT_WASM_DIR" ]]; then
    echo "Installing Qt $QT_VERSION (Host & WebAssembly) via aqtinstall..."
    
    python3 -m pip install --upgrade aqtinstall
    
    python3 -m aqt install-qt linux desktop "$QT_VERSION" linux_gcc_64 -O "$QT_INSTALL_DIR"
    
    python3 -m aqt install-qt all_os wasm "$QT_VERSION" wasm_multithread -O "$QT_INSTALL_DIR"
fi


# ==============================================================================
# DEPENDENCIES
# ==============================================================================

# GMP
(
    mkdir -p "$AUX_BUILD/gmp"
    cd "$AUX_BUILD/gmp"
    if [[ ! -d "$EXTERN_DIR/gmp" ]]; then
        echo "Downloading GMP source..."
        hg clone https://gmplib.org/repo/gmp/ "$EXTERN_DIR/gmp"
        cd "$EXTERN_DIR/gmp" && ./.bootstrap && cd -
    fi
    if [[ ! -f config.status ]]; then
        CC_FOR_BUILD=/usr/bin/gcc ABI=standard \
        emconfigure "$EXTERN_DIR/gmp/configure" \
            --build i686-pc-linux-gnu --host none \
            --disable-assembly --enable-cxx \
            --prefix="$AUX_PREFIX"
    fi
    emmake make -j8
    emmake make install
)

# libxml2
(
    mkdir -p "$AUX_BUILD/libxml2"
    cd "$AUX_BUILD/libxml2"
    
    if [[ ! -d "$EXTERN_DIR/libxml2" ]]; then
        echo "Downloading libxml2 source..."
        git clone --depth 1 https://gitlab.gnome.org/GNOME/libxml2.git "$EXTERN_DIR/libxml2"
        
        cd "$EXTERN_DIR/libxml2" && NOCONFIGURE=1 ./autogen.sh && cd -
    fi
    
    if [[ ! -f Makefile ]]; then
        echo "Configuring libxml2 for WebAssembly..."
        emconfigure "$EXTERN_DIR/libxml2/configure" \
            --build=i686-pc-linux-gnu \
            --host=wasm32-unknown-emscripten \
            --prefix="$AUX_PREFIX" \
            --disable-shared \
            --without-python \
            --without-zlib \
            --without-iconv \
            --without-icu \
            --without-modules
    fi
    
    emmake make -j8
    emmake make install
)

# --- LMDB ---
(
    mkdir -p "$AUX_BUILD/lmdb"
    cd "$AUX_BUILD/lmdb"
    
    if [[ ! -d "$EXTERN_DIR/lmdb" ]]; then
        echo "Downloading LMDB source..."
        git clone https://github.com/LMDB/lmdb.git "$EXTERN_DIR/lmdb"
    fi
    
    cd "$EXTERN_DIR/lmdb/libraries/liblmdb"
    
    if [[ ! -f "$AUX_PREFIX/lib/liblmdb.a" ]]; then
        echo "Building LMDB for WebAssembly..."
        
        emmake make liblmdb.a lmdb.pc CC=emcc AR=emar prefix="$AUX_PREFIX"
        
        cp liblmdb.a "$AUX_PREFIX/lib/"
        cp lmdb.h "$AUX_PREFIX/include/"
        mkdir -p "$AUX_PREFIX/lib/pkgconfig"
        cp emscripten/lmdb.pc "$AUX_PREFIX/lib/pkgconfig/"
    fi
)

# --- liblzma (xz utils) ---
(
    mkdir -p "$AUX_BUILD/xz"
    cd "$AUX_BUILD/xz"
    
    if [[ ! -d "$EXTERN_DIR/xz" ]]; then
        echo "Cloning xz (liblzma)..."
        git clone https://github.com/tukaani-project/xz.git "$EXTERN_DIR/xz"
    fi
    
    cd "$EXTERN_DIR/xz"
    if [[ ! -f configure ]]; then
        ./autogen.sh --no-po4a
    fi
    cd "$AUX_BUILD/xz"
    
    if [[ ! -f Makefile ]]; then
        echo "Configuring liblzma for WebAssembly..."
        emconfigure "$EXTERN_DIR/xz/configure" \
            --build=i686-pc-linux-gnu \
            --host=wasm32-unknown-emscripten \
            --disable-shared \
            --prefix="$AUX_PREFIX" \
            CFLAGS="${CFLAGS:-}" \
            CXXFLAGS="${CXXFLAGS:-}" \
            LDFLAGS="${LDFLAGS:-}"
    fi
    
    emmake make -j8
    emmake make install
)

# --- Graphviz ---

# --- Python 3 ---



# ==============================================================================
# REGINA CONFIGURATION & BUILD
# ==============================================================================
echo "Configuring Regina for WebAssembly..."

if ! grep -q "censusdata_DATA_DISABLED" engine/data/census/CMakeLists.txt; then
    sed -i 's/SET(censusdata_DATA/SET(censusdata_DATA_DISABLED/g' engine/data/census/CMakeLists.txt
fi

if ! grep -q "#add_subdirectory(testsuite)" engine/CMakeLists.txt; then
    sed -i 's/add_subdirectory(testsuite)/#add_subdirectory(testsuite)/Ig' engine/CMakeLists.txt
fi

if ! grep -q "Q_OS_WASM" qtui/src/shortrunner.h; then
    sed -i 's/QProcess proc;/#ifndef Q_OS_WASM\n        QProcess proc;\n#endif/g' qtui/src/shortrunner.h
fi

if ! grep -q "Q_OS_WASM" qtui/src/shortrunner.cpp; then
    sed -i 's/QString ShortRunner::run(bool mergeStderr) {/QString ShortRunner::run(bool mergeStderr) {\n#ifndef Q_OS_WASM/g' qtui/src/shortrunner.cpp
    sed -i 's/void ShortRunner::processStarted() {/#else\n    Q_UNUSED(mergeStderr);\n    return QString();\n}\n#endif\n\nvoid ShortRunner::processStarted() {/g' qtui/src/shortrunner.cpp
fi

if ! grep -q "dummy_process.h" qtui/src/packets/gaprunner.h; then
    sed -i '/#include <QProcess>/a #include "../../../emscripten/dummy_process.h"' qtui/src/packets/gaprunner.h
fi

if ! grep -q "// python = 0;" qtui/src/packets/spatiallinkui.cpp; then
    sed -i 's/python = 0;/\/\/ python = 0;/g' qtui/src/packets/spatiallinkui.cpp
fi

if ! grep -q "std::shared_ptr<regina::Packet>, std::shared_ptr<regina::Packet>" qtui/src/pythonmanager.cpp; then
    sed -i 's/regina::Packet\*, regina::Packet\*/std::shared_ptr<regina::Packet>, std::shared_ptr<regina::Packet>/g' qtui/src/pythonmanager.cpp
fi

mkdir -p build-wasm
cd build-wasm

export PKG_CONFIG_PATH="$AUX_PREFIX/lib/pkgconfig:$AUX_PREFIX/share/pkgconfig"

# Define WebAssembly flags (Enabling Pthreads, Exceptions, and Emscripten ports)
WASM_CXXFLAGS="-O2 -fexceptions -pthread"
# -s USE_ZLIB=1 and -s USE_FREETYPE=1 instruct Emscripten to automatically inject its own compiled versions of these common libraries.
WASM_LDFLAGS="-O2 -fexceptions -pthread -s WASM=1 -s TOTAL_STACK=64mb -s INITIAL_MEMORY=2048mb -s ALLOW_MEMORY_GROWTH=1 -s USE_ZLIB=1 -s USE_FREETYPE=1"

# Configure Regina using Emscripten's CMake wrapper
if [[ ! -f Makefile ]]; then
    rm -f CMakeCache.txt
    emcmake cmake .. \
        -DCMAKE_INSTALL_PREFIX="$AUX_PREFIX" \
        -DCMAKE_PREFIX_PATH="$AUX_PREFIX;$QT_WASM_DIR" \
        -DCMAKE_FIND_ROOT_PATH="$AUX_PREFIX;$QT_WASM_DIR" \
        -DQt6_DIR="$QT_WASM_DIR/lib/cmake/Qt6" \
        -DQT_HOST_PATH="$QT_HOST_DIR" \
        -DGMP_INCLUDE_DIR="$AUX_PREFIX/include" \
        -DGMP_LIBRARIES="$AUX_PREFIX/lib/libgmp.a" \
        -DGMPXX_INCLUDE_DIR="$AUX_PREFIX/include" \
        -DGMPXX_LIBRARIES="$AUX_PREFIX/lib/libgmpxx.a" \
        -DLIBXML2_INCLUDE_DIR="$AUX_PREFIX/include/libxml2" \
        -DLIBXML2_LIBRARY="$AUX_PREFIX/lib/libxml2.a" \
        -DCMAKE_CXX_FLAGS="$WASM_CXXFLAGS -I$AUX_PREFIX/include" \
        -DCMAKE_C_FLAGS="$WASM_CXXFLAGS -I$AUX_PREFIX/include" \
        -DCMAKE_EXE_LINKER_FLAGS="$WASM_LDFLAGS" \
        -DDISABLE_GUI=OFF \
        -DDISABLE_PYTHON=ON \
        -DDISABLE_GRAPHVIZ=ON \
        -DBUILD_DOCS=ON \
        -DBUILD_MAC_APP=OFF
fi

echo "Building Regina..."
emmake make -j8 regina-gui

echo "Build complete. Regina WebAssembly files are located in $(pwd)"
cd ..