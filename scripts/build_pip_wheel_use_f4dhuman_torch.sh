#!/usr/bin/env bash

# Helper to build Momentum pip wheel directly using the f4dhuman conda environment.
# Avoids creating a new environment and re-installing heavy packages (torch, cuda runtime).
# Installs only necessary build dependencies.

set -eo pipefail

if ! command -v conda >/dev/null 2>&1;
then
  echo "conda is required. Please install Miniconda/Anaconda and re-run." >&2
  exit 1
fi

# Parameters
ENV_NAME="${MOMENTUM_CONDA_ENV:-f4dhuman}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"

# Activate conda
eval "$(conda shell.bash hook)"

if ! conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}";
then
  echo "Error: Conda environment '${ENV_NAME}' does not exist." >&2
  echo "Please ensure the f4dhuman environment is set up before running this script." >&2
  exit 1
fi

echo "Activating conda env '${ENV_NAME}'..."
conda activate "${ENV_NAME}"

# Determine install command (prefer mamba if available)
if command -v mamba &> /dev/null; then
    INSTALL_CMD="mamba"
else
    echo "mamba not found, falling back to conda (this might be slower)..."
    INSTALL_CMD="conda"
fi

# Install only the REQUIRED build dependencies.
# We skip PyTorch and CUDA runtime packages as we assume they are already in f4dhuman.
# We DO install cmake, ninja, compilers, and the C++ libraries Momentum depends on.
# We also include cuda-nvcc and dev tools needed for compilation.

echo "Installing build dependencies into '${ENV_NAME}' (skipping torch/cuda runtime)..."
"$INSTALL_CMD" install -y -c conda-forge \
  libnvjitlink \
  cuda-cudart-dev \
  libcublas-dev \
  cuda-nvcc \
  cuda-nvrtc-dev \
  cmake \
  ninja \
  pybind11 \
  scikit-build-core \
  "gxx_linux-64=12.*" \
  "gcc_linux-64=12.*" \
  ceres-solver \
  cli11 \
  dispenso \
  drjit-cpp \
  fx-gltf \
  openfbx \
  ezc3d \
  eigen \
  fmt \
  nlohmann_json \
  indicators \
  re2 \
  "librerun-sdk=0.23.3" \
  spdlog \
  urdfdom \
  kokkos \
  "rerun-sdk=0.23.3" \
  ms-gsl \
  gflags \
  glog \
  boost-cpp \
  zlib \
  openssl \
  jinja2 \
  patchelf \
  auditwheel \
  setuptools-scm \
  setuptools

# Setup build environment variables based on the CURRENT conda env
export CMAKE_PREFIX_PATH="${CONDA_PREFIX}"
export CUDA_HOME="${CONDA_PREFIX}"
export CUDA_TOOLKIT_ROOT_DIR="${CONDA_PREFIX}"
export CUDACXX="${CONDA_PREFIX}/bin/nvcc"
export PATH="${CONDA_PREFIX}/bin:${PATH}"
# Ensure we prefer the conda libs
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

# Add Torch CMake path (using the torch installed in f4dhuman)
TORCH_CMAKE_PATH=$(python -c 'import torch; print(torch.utils.cmake_prefix_path)')
export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}:${TORCH_CMAKE_PATH}"

echo "Using Torch at: ${TORCH_CMAKE_PATH}"

# Generate pyproject.toml variants
echo "Generating pyproject.toml variants..."
# We assume PyTorch 2.5.1+ compatibility as in the reference script.
python scripts/generate_pyproject.py --torch-min-py312 2.5.1 --torch-max-py312 2.6

# Determine variant (CPU or GPU)
VARIANT="gpu"
PY_SUFFIX=$(python -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')")

echo "Building ${VARIANT} wheel for Python $(python --version) (using env ${ENV_NAME})..."

# Backup original pyproject.toml
cp pyproject.toml pyproject.toml.bak

# Copy variant to pyproject.toml
cp "pyproject-pypi-${VARIANT}.toml" pyproject.toml 2>/dev/null || cp "pyproject-pypi-${VARIANT}-py${PY_SUFFIX}.toml" pyproject.toml

# Clean dist
rm -rf dist/*

# Build wheel
# We pass CMAKE_ARGS to control the build
# MOMENTUM_USE_SYSTEM_PYBIND11=OFF to avoid issues
# MOMENTUM_BUILD_RENDERER=OFF as per reference
export CMAKE_ARGS="-DMOMENTUM_ENABLE_FBX_SAVING=OFF -DMOMENTUM_ENABLE_SIMD=OFF -DMOMENTUM_USE_SYSTEM_GOOGLETEST=ON -DMOMENTUM_USE_SYSTEM_PYBIND11=OFF -DMOMENTUM_USE_SYSTEM_RERUN_CPP_SDK=ON -DBUILD_SHARED_LIBS=OFF -DMOMENTUM_BUILD_RENDERER=OFF -Ddrjit_DIR=${CONDA_PREFIX}/share/cmake/drjit"

echo "Running pip wheel..."
pip wheel . --no-deps --no-build-isolation --wheel-dir=dist

# Restore pyproject.toml
mv pyproject.toml.bak pyproject.toml

# Repair wheel
echo "Repairing wheel with auditwheel..."
# Exclude libraries provided by the environment
auditwheel repair \
    --exclude 'libtorch*.so' --exclude 'libc10*.so' \
    --exclude 'libcu*.so*' --exclude 'libnv*.so*' --exclude 'libmkl*.so' \
    dist/pymomentum_*.whl -w dist/repaired

echo "Done. Wheel is in dist/repaired/"

# Optional: Test the wheel (unrepaired) if requested, or just list it
WHEEL_FILE=$(find dist -maxdepth 1 -name "*.whl" | head -n 1)
echo "Generated wheel: ${WHEEL_FILE}"
