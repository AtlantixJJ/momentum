#!/usr/bin/env bash

# Build Momentum pip wheel in a NEW conda environment with PyTorch 2.5.1 + CUDA 12.1.
# This script ensures CUDA-enabled PyTorch is NOT replaced by CPU version during installation.

set -eo pipefail

if ! command -v conda >/dev/null 2>&1; then
  echo "conda is required. Please install Miniconda/Anaconda and re-run." >&2
  exit 1
fi

# Parameters
ENV_NAME="${MOMENTUM_CONDA_ENV:-momentum_build}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"  # Must be >=3.12 for pymomentum
FORCE_RECREATE="${FORCE_RECREATE:-0}"

# Activate conda
eval "$(conda shell.bash hook)"

# Check if environment exists
if conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
  if [[ "${FORCE_RECREATE}" == "1" ]]; then
    echo "Removing existing environment '${ENV_NAME}'..."
    conda env remove -n "${ENV_NAME}" -y
  else
    echo "Environment '${ENV_NAME}' already exists."
    echo "Set FORCE_RECREATE=1 to recreate, or use a different MOMENTUM_CONDA_ENV name."
    echo "Proceeding with existing environment..."
  fi
fi

# Create new environment if it doesn't exist
if ! conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
  echo "Creating new conda environment '${ENV_NAME}' with Python ${PYTHON_VERSION}..."
  conda create -n "${ENV_NAME}" python="${PYTHON_VERSION}" -y
fi

echo "Activating conda env '${ENV_NAME}'..."
conda activate "${ENV_NAME}"

# CRITICAL: Prevent Python from using packages from ~/.local/lib/pythonX.Y/site-packages
# This ensures we use ONLY the conda environment's packages
export PYTHONNOUSERSITE=1
echo "Set PYTHONNOUSERSITE=1 to isolate conda environment from user site-packages"

# Determine install command (prefer mamba if available)
if command -v mamba &> /dev/null; then
    INSTALL_CMD="mamba"
else
    echo "mamba not found, falling back to conda (this might be slower)..."
    INSTALL_CMD="conda"
fi

# ============================================================================
# STEP 1: Install PyTorch with CUDA FIRST (before any other packages)
# ============================================================================
echo "Installing PyTorch 2.5.1 with CUDA 12.1 support..."
conda install -y -c pytorch -c nvidia \
  "pytorch==2.5.1" \
  "torchvision==0.20.1" \
  "torchaudio==2.5.1" \
  "pytorch-cuda=12.1"

# Verify CUDA PyTorch installation
echo "Verifying PyTorch CUDA installation..."
CUDA_AVAILABLE=$(python -c "import torch; print(torch.cuda.is_available())")
if [[ "${CUDA_AVAILABLE}" != "True" ]]; then
  echo "ERROR: PyTorch CUDA is not available after installation!" >&2
  echo "torch.cuda.is_available() = ${CUDA_AVAILABLE}" >&2
  exit 1
fi
echo "PyTorch CUDA verification passed: torch.cuda.is_available() = ${CUDA_AVAILABLE}"

# ============================================================================
# STEP 2: Install build dependencies WITHOUT touching PyTorch
# Key strategy:
#   - Use nvidia channel for CUDA 12.1 dev tools (compatible with pytorch-cuda=12.1)
#   - Explicitly pin pytorch packages to prevent replacement
# ============================================================================
echo "Installing build dependencies..."

# Install CUDA development tools from nvidia channel (matching 12.1)
# These are compatible with the pytorch-cuda=12.1 we installed
# Include static libraries needed for linking
echo "Installing CUDA 12.1 development tools from nvidia channel..."
"$INSTALL_CMD" install -y -c nvidia -c conda-forge \
  "cuda-cudart-dev=12.1.*" \
  "cuda-cudart-static=12.1.*" \
  "cuda-nvcc=12.1.*" \
  "cuda-nvrtc-dev=12.1.*" \
  "libcublas-dev=12.1.*" \
  "cuda-cccl=12.1.*"

# Install build tools and C++ libraries
# These packages don't have pytorch dependencies
echo "Installing build tools..."
"$INSTALL_CMD" install -y -c conda-forge \
  cmake \
  ninja \
  pybind11 \
  scikit-build-core \
  "gxx_linux-64=12.*" \
  "gcc_linux-64=12.*"

# Install C++ dependencies for Momentum (none of these should require PyTorch)
echo "Installing C++ dependencies for Momentum..."
"$INSTALL_CMD" install -y -c conda-forge \
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
  ms-gsl \
  gflags \
  glog \
  boost-cpp \
  zlib \
  openssl

# Install Python packaging tools via pip to avoid any pytorch conflicts
echo "Installing Python packaging tools via pip..."
pip install jinja2 patchelf auditwheel setuptools-scm setuptools

# Install rerun-sdk via pip (the conda version might have conflicts)
pip install rerun-sdk==0.23.3

# ============================================================================
# STEP 3: Verify PyTorch CUDA is still intact after all installations
# ============================================================================
echo "Final verification of PyTorch CUDA..."
CUDA_AVAILABLE=$(python -c "import torch; print(torch.cuda.is_available())")
TORCH_VERSION=$(python -c "import torch; print(torch.__version__)")
CUDA_VERSION=$(python -c "import torch; print(torch.version.cuda)")

echo "PyTorch version: ${TORCH_VERSION}"
echo "CUDA version: ${CUDA_VERSION}"
echo "CUDA available: ${CUDA_AVAILABLE}"

if [[ "${CUDA_AVAILABLE}" != "True" ]]; then
  echo "ERROR: PyTorch CUDA was replaced/broken during dependency installation!" >&2
  echo "Please investigate the conda dependency resolution." >&2
  exit 1
fi
echo "PyTorch CUDA verification passed!"

# ============================================================================
# STEP 4: Setup build environment variables
# ============================================================================
export CMAKE_PREFIX_PATH="${CONDA_PREFIX}"
export CUDA_HOME="${CONDA_PREFIX}"
export CUDA_TOOLKIT_ROOT_DIR="${CONDA_PREFIX}"
export CUDACXX="${CONDA_PREFIX}/bin/nvcc"
export PATH="${CONDA_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${CONDA_PREFIX}/lib/stubs:${LD_LIBRARY_PATH:-}"
# CRITICAL: Set LIBRARY_PATH for the linker to find CUDA static libraries during compilation
export LIBRARY_PATH="${CONDA_PREFIX}/lib:${CONDA_PREFIX}/lib/stubs:${LIBRARY_PATH:-}"
# Also set CPATH for header files
export CPATH="${CONDA_PREFIX}/include:${CPATH:-}"

# Add Torch CMake path
TORCH_CMAKE_PATH=$(python -c 'import torch; print(torch.utils.cmake_prefix_path)')
export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}:${TORCH_CMAKE_PATH}"

echo "Using Torch at: ${TORCH_CMAKE_PATH}"

# ============================================================================
# STEP 5: Generate pyproject.toml variants and build wheel
# ============================================================================
echo "Generating pyproject.toml variants..."
python scripts/generate_pyproject.py --torch-min-py312 2.5.1 --torch-max-py312 2.6

# Determine variant (GPU since we have CUDA PyTorch)
VARIANT="gpu"
PY_SUFFIX=$(python -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')")

echo "Building ${VARIANT} wheel for Python $(python --version) (using env ${ENV_NAME})..."

# Backup original pyproject.toml
cp pyproject.toml pyproject.toml.bak

# Copy variant to pyproject.toml
cp "pyproject-pypi-${VARIANT}.toml" pyproject.toml 2>/dev/null || cp "pyproject-pypi-${VARIANT}-py${PY_SUFFIX}.toml" pyproject.toml

# Clean build artifacts
rm -rf dist build
mkdir -p dist

# Build wheel with CMAKE_ARGS
export CMAKE_ARGS="-DMOMENTUM_ENABLE_FBX_SAVING=OFF -DMOMENTUM_ENABLE_SIMD=OFF -DMOMENTUM_USE_SYSTEM_GOOGLETEST=ON -DMOMENTUM_USE_SYSTEM_PYBIND11=OFF -DMOMENTUM_USE_SYSTEM_RERUN_CPP_SDK=ON -DBUILD_SHARED_LIBS=OFF -DMOMENTUM_BUILD_RENDERER=OFF -Ddrjit_DIR=${CONDA_PREFIX}/share/cmake/drjit"

echo "Running pip wheel..."
pip wheel . --no-deps --no-build-isolation --wheel-dir=dist

# Restore pyproject.toml
mv pyproject.toml.bak pyproject.toml

# ============================================================================
# STEP 6: Repair wheel
# ============================================================================
echo "Repairing wheel with auditwheel..."
auditwheel repair \
    --exclude 'libtorch*.so' --exclude 'libc10*.so' \
    --exclude 'libcu*.so*' --exclude 'libnv*.so*' --exclude 'libmkl*.so' \
    dist/pymomentum_*.whl -w dist/repaired

echo "Done. Wheel is in dist/repaired/"

# List generated wheel
WHEEL_FILE=$(find dist -maxdepth 1 -name "*.whl" | head -n 1)
echo "Generated wheel: ${WHEEL_FILE}"

# Final summary
echo ""
echo "============================================"
echo "Build Summary:"
echo "  Environment: ${ENV_NAME}"
echo "  PyTorch: ${TORCH_VERSION}"
echo "  CUDA: ${CUDA_VERSION}"
echo "  Wheel: ${WHEEL_FILE}"
echo "============================================"
