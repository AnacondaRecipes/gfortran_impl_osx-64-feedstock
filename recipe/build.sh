#!/bin/bash

set -e

function start_spinner {
    if [ -n "$SPINNER_PID" ]; then
        return
    fi

    >&2 echo "Building libraries..."
    # Start a process that runs as a keep-alive
    # to avoid travis quitting if there is no output
    (while true; do
        sleep 60
        >&2 echo "Still building..."
    done) &
    SPINNER_PID=$!
    disown
}

function stop_spinner {
    if [ ! -n "$SPINNER_PID" ]; then
        return
    fi

    kill $SPINNER_PID
    unset SPINNER_PID

    >&2 echo "Building libraries finished."
}

function quiet_run {
    rm -f logs.txt
    if [[ -z "$CI" ]] || [[ "$target_platform" != osx*  ]]; then
        $@
    else
        {
            $@ >& logs.txt
        } || {
            tail -n 5000 logs.txt
            exit 1
        }
    fi
}

start_spinner

set -x

# Undo conda-build madness
export host_platform=$target_platform
export target_platform=$cross_Target_platform
export TARGET=${macos_machine}
export NO_WARN_CFLAGS="-Wno-array-bounds -Wno-unknown-warning-option -Wno-deprecated -Wno-mismatched-tags -Wunused-command-line-argument"

if [[ "$host_platform" != "$build_platform" ]]; then
    # If the compiler is a cross-native/canadian-cross compiler
    mkdir -p build_host
    pushd build_host
    languages="c"
    if [[ "$host_platform" == "$target_platform" ]]; then
        # Need a fortran compiler to build libgfortran
        languages="$languages,fortran"
    fi
    CC=$CC_FOR_BUILD CXX=$CXX_FOR_BUILD AR="$($CC_FOR_BUILD -print-prog-name=ar)" LD="$($CC_FOR_BUILD -print-prog-name=ld)" \
         RANLIB="$($CC_FOR_BUILD -print-prog-name=ranlib)" NM="$($CC_FOR_BUILD -print-prog-name=nm)"  \
         CFLAGS="$NO_WARN_CFLAGS" CXXFLAGS="$NO_WARN_CFLAGS" CPPFLAGS="" LDFLAGS="-L$BUILD_PREFIX/lib -Wl,-rpath,$BUILD_PREFIX/lib" ../configure \
       --prefix=${BUILD_PREFIX} \
       --build=${BUILD} \
       --host=${BUILD} \
       --target=${TARGET} \
       --with-libiconv-prefix=${BUILD_PREFIX} \
       --enable-languages=$languages \
       --disable-multilib \
       --enable-checking=release \
       --disable-bootstrap \
       --disable-libssp \
       --with-gmp=${BUILD_PREFIX} \
       --with-mpfr=${BUILD_PREFIX} \
       --with-mpc=${BUILD_PREFIX} \
       --with-isl=${BUILD_PREFIX}
    echo "Building a compiler that runs on ${BUILD} and targets ${TARGET}"
    quiet_run make all-gcc -j${CPU_COUNT}
    quiet_run make install-gcc -j${CPU_COUNT}
    popd
    ln -sf ${BUILD_PREFIX}/bin/${TARGET}-ar       ${BUILD_PREFIX}/lib/gcc/${TARGET}/${gfortran_version}/ar
    ln -sf ${BUILD_PREFIX}/bin/${TARGET}-as       ${BUILD_PREFIX}/lib/gcc/${TARGET}/${gfortran_version}/as
    ln -sf ${BUILD_PREFIX}/bin/${TARGET}-nm       ${BUILD_PREFIX}/lib/gcc/${TARGET}/${gfortran_version}/nm
    ln -sf ${BUILD_PREFIX}/bin/${TARGET}-ranlib   ${BUILD_PREFIX}/lib/gcc/${TARGET}/${gfortran_version}/ranlib
    ln -sf ${BUILD_PREFIX}/bin/${TARGET}-strip    ${BUILD_PREFIX}/lib/gcc/${TARGET}/${gfortran_version}/strip
    ln -sf ${BUILD_PREFIX}/bin/${TARGET}-ld       ${BUILD_PREFIX}/lib/gcc/${TARGET}/${gfortran_version}/ld
fi

mkdir build_conda
cd build_conda

if [[ "$host_platform" == osx* ]]; then
    export LIBRARY_PATH="$CONDA_BUILD_SYSROOT/usr/lib"
    export CFLAGS="$CFLAGS -isysroot $CONDA_BUILD_SYSROOT $NO_WARN_CFLAGS"
    export CXXFLAGS="$CXXFLAGS -isysroot $CONDA_BUILD_SYSROOT $NO_WARN_CFLAGS"
fi

if [[ "$target_platform" == osx* ]]; then
    export LDFLAGS_FOR_TARGET="$LDFLAGS_FOR_TARGET -L$PWD/$target/libgcc -L$CONDA_BUILD_SYSROOT/usr/lib"
    export CFLAGS_FOR_TARGET="$CFLAGS_FOR_TARGET -isystem $CONDA_BUILD_SYSROOT/usr/include $LDFLAGS_FOR_TARGET $NO_WARN_CFLAGS"
    export CXXFLAGS_FOR_TARGET="$CXXFLAGS_FOR_TARGET -isystem $CONDA_BUILD_SYSROOT/usr/include $LDFLAGS_FOR_TARGET $NO_WARN_CFLAGS"
fi

../configure \
    --prefix=${PREFIX} \
    --build=${BUILD} \
    --host=${HOST} \
    --target=${TARGET} \
    --with-libiconv-prefix=${PREFIX} \
    --enable-languages=fortran \
    --disable-multilib \
    --enable-checking=release \
    --disable-bootstrap \
    --disable-libssp \
    --with-gmp=${PREFIX} \
    --with-mpfr=${PREFIX} \
    --with-mpc=${PREFIX} \
    --with-isl=${PREFIX}

echo "Building a compiler that runs on ${HOST} and targets ${TARGET}"
if [[ "$host_platform" == "$target_platform" ]]; then
  # If the compiler is a cross-native/native compiler
  make -j"${CPU_COUNT}" || (cat $TARGET/libquadmath/config.log && ls gcc && find . -name "libemutls_w.a" && file gcc/libemutls_w.a && false)
  quiet_run make install-strip
  rm $PREFIX/lib/libgomp.dylib
  rm $PREFIX/lib/libgomp.1.dylib
  ln -s $PREFIX/lib/libomp.dylib $PREFIX/lib/libgomp.dylib
  ln -s $PREFIX/lib/libomp.dylib $PREFIX/lib/libgomp.1.dylib

  pushd ${PREFIX}/lib
    sed -i.bak "s@^\*lib.*@& -rpath $PREFIX/lib@" libgfortran.spec
    rm libgfortran.spec.bak
  popd
else
  # The compiler is a cross compiler
  quiet_run make all-gcc -j${CPU_COUNT}
  quiet_run make install-gcc -j${CPU_COUNT}
  cp $RECIPE_DIR/libgomp.spec $PREFIX/lib/gcc/${TARGET}/${gfortran_version}/libgomp.spec
  sed "s#@CONDA_PREFIX@#$PREFIX#g" $RECIPE_DIR/libgfortran.spec > $PREFIX/lib/gcc/${TARGET}/${gfortran_version}/libgfortran.spec
fi

stop_spinner

ls -al $PREFIX/lib
