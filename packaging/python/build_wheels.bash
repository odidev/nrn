#!/usr/bin/env bash
set -xe
# A script to loop over the available pythons installed
# on Linux/OSX and build wheels
#
# Note: It should be invoked from nrn directory
#
# PREREQUESITES:
#  - cmake (>=3.5)
#  - flex
#  - bison
#  - python >= 3.6
#  - cython
#  - MPI
#  - X11
#  - C/C++ compiler
#  - ncurses

set -e

if [ ! -f setup.py ]; then
    echo "Error: setup.py not found. Please launch $0 from the nrn root dir"
    exit 1
fi

py_ver=""

setup_venv() {
    local py_bin="$1"
    py_ver=$("$py_bin" -c "import sys; print('%d%d' % tuple(sys.version_info)[:2])")
    suffix=$("$py_bin" -c "print(str(hash(\"$py_bin\"))[0:8])")
    local venv_dir="nrn_build_venv${py_ver}_${suffix}"

    echo " - Creating $venv_dir: $py_bin -m venv $venv_dir"

    "$py_bin" -m venv "$venv_dir"

    . "$venv_dir/bin/activate"

    if ! pip install -U pip setuptools wheel; then
        curl https://raw.githubusercontent.com/pypa/get-pip/20.3.4/get-pip.py | python
        pip install -U setuptools wheel
    fi

}


pip_numpy_install() {
    # numpy is special as we want the minimum wheel version
    numpy_ver="numpy"
    case "$py_ver" in
      36) numpy_ver="numpy==1.12.1" ;;
      37) numpy_ver="numpy==1.14.6" ;;
      38) numpy_ver="numpy==1.17.5" ;;
      39) numpy_ver="numpy==1.19.3" ;;
      *) numpy_ver="numpy";;
    esac
    echo " - pip install $numpy_ver"
    pip install $numpy_ver
}

build_wheel_linux() {
    echo "[BUILD WHEEL] Building with interpreter $1"
    local skip=
    setup_venv "$1"
    (( $skip )) && return 0

    echo " - Installing build requirements"
    #auditwheel needs to be installed with python3
    pip install auditwheel
    pip install -r packaging/python/build_requirements.txt
    pip_numpy_install

    echo " - Building..."
    rm -rf dist build

    if [ "$2" == "coreneuron" ]; then
        setup_args="--enable-coreneuron"
    elif [ "$2" == "coreneuron-gpu" ]; then
        setup_args="--enable-coreneuron --enable-gpu"
        # nvhpc is required for GPU support but make sure
        # CC and CXX are unset for building python extensions
        source ~/.bashrc
        module load nvhpc
        unset CC CXX
        # preferred cuda version e.g. 11.0
        export PATH=${CORENRN_CUDA_HOME}/bin:$PATH
    fi

    CMAKE_DEFS="NRN_MPI_DYNAMIC=$3"
    if [ "$USE_STATIC_READLINE" == "1" ]; then
      CMAKE_DEFS="$CMAKE_DEFS,NRN_WHEEL_STATIC_READLINE=ON"
    fi
    python setup.py build_ext --cmake-prefix="/nrnwheel/ncurses;/nrnwheel/readline" --cmake-defs="$CMAKE_DEFS" $setup_args bdist_wheel

    # For CI runs we skip wheelhouse repairs
    if [ "$SKIP_WHEELHOUSE_REPAIR" = true ] ; then
        echo " - Skipping wheelhouse repair ..."
        mkdir wheelhouse && cp dist/*.whl wheelhouse/
    else
        echo " - Auditwheel show"
        auditwheel show dist/*.whl
        echo " - Repairing..."
        auditwheel repair dist/*.whl
    fi

    deactivate
}


build_wheel_osx() {
    echo "[BUILD WHEEL] Building with interpreter $1"
    local skip=
    setup_venv "$1"
    (( $skip )) && return 0

    echo " - Installing build requirements"
    pip install -U delocate -r packaging/python/build_requirements.txt
    pip_numpy_install

    echo " - Building..."
    rm -rf dist build

    if [ "$2" == "coreneuron" ]; then
        setup_args="--enable-coreneuron"
    elif [ "$2" == "coreneuron-gpu" ]; then
        echo "Error: GPU support on MacOS is not available!"
        exit 1
    fi

    CMAKE_DEFS="NRN_MPI_DYNAMIC=$3"
    if [ "$USE_STATIC_READLINE" == "1" ]; then
      CMAKE_DEFS="$CMAKE_DEFS,NRN_WHEEL_STATIC_READLINE=ON"
    fi

    # We need to "fix" the platform tag if the Python installer is universal2
    # See:
    #     * https://github.com/pypa/setuptools/issues/2520
    #     * https://github.com/neuronsimulator/nrn/pull/1562
    py_platform=$(python -c "import sysconfig; print('%s' % sysconfig.get_platform());")

    echo " - Python platform: ${py_platform}"
    if [[ "${py_platform}" == *"-universal2" ]] ; then
      export _PYTHON_HOST_PLATFORM="${py_platform/universal2/x86_64}"
      echo " - Python installation is universal2, setting _PYTHON_HOST_PLATFORM to: ${_PYTHON_HOST_PLATFORM}"
    fi

    python setup.py build_ext --cmake-prefix="/opt/nrnwheel/ncurses;/opt/nrnwheel/readline;/usr/x11" --cmake-defs="$CMAKE_DEFS" $setup_args bdist_wheel

    echo " - Calling delocate-listdeps"
    delocate-listdeps dist/*.whl

    echo " - Repairing..."
    delocate-wheel -w wheelhouse -v dist/*.whl  # we started clean, there's a single wheel

    deactivate
}

# platform for which wheel to be build
platform=$1

# python version for which wheel to be built; 3* (default) means all python 3 versions
python_wheel_version=
if [ ! -z "$2" ]; then
  python_wheel_version=$2
fi

# enable coreneuron support: "coreneuron" or "coreneuron-gpu"
# this should be removed/improved once wheel is stable
coreneuron=$3

# MAIN

case "$1" in

  linux)
    MPI_INCLUDE_HEADERS="/nrnwheel/openmpi/include;/nrnwheel/mpich/include"
    # Check for MPT headers. On Azure, we extract them from a secure file and mount them in the docker image in:
    MPT_INCLUDE_PATH="/nrnwheel/mpt/include"
    if [ -d "$MPT_INCLUDE_PATH" ]; then
        MPI_INCLUDE_HEADERS="${MPI_INCLUDE_HEADERS};${MPT_INCLUDE_PATH}"
    fi
    USE_STATIC_READLINE=1
    python_wheel_version=${python_wheel_version//[-._]/}
    for py_bin in /opt/python/cp${python_wheel_version}*/bin/python; do
        build_wheel_linux "$py_bin" "$coreneuron" "$MPI_INCLUDE_HEADERS"
    done
    ;;

  osx)
    MPI_INCLUDE_HEADERS="/usr/local/opt/openmpi/include;/usr/local/opt/mpich/include"
    USE_STATIC_READLINE=1
    for py_bin in /Library/Frameworks/Python.framework/Versions/${python_wheel_version}*/bin/python3; do
        build_wheel_osx "$py_bin" "$coreneuron" "$MPI_INCLUDE_HEADERS"
    done
    ;;

  CI)
    if [ "$CI_OS_NAME" == "osx" ]; then
        MPI_INCLUDE_HEADERS="/usr/local/opt/openmpi/include;/usr/local/opt/mpich/include"
        build_wheel_osx $(which python3) "$coreneuron" "$MPI_INCLUDE_HEADERS"
    else
        MPI_INCLUDE_HEADERS="/usr/lib/x86_64-linux-gnu/openmpi/include;/usr/include/mpich"
        build_wheel_linux $(which python3) "$coreneuron" "$MPI_INCLUDE_HEADERS"
    fi
    ls wheelhouse/
    ;;

  *)
    echo "Usage: $(basename $0) < linux | osx > [python version 36|37|38|39|3*]  [coreneuron | coreneuron-gpu]"
    exit 1
    ;;

esac
