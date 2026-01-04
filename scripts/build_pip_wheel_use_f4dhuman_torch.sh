#!/usr/bin/env bash

# Build Momentum wheel using PyTorch from the existing f4dhuman env.
# Build deps are installed into a separate build env to avoid altering f4dhuman.

set -eo pipefail

if ! command -v conda >/dev/null 2>&1; then
  echo "conda is required. Please install Miniconda/Anaconda and re-run." >&2
  exit 1
fi

# Parameters
TORCH_ENV_NAME="${MOMENTUM_TORCH_ENV:-f4dhuman}"
BUILD_ENV_NAME="${MOMENTUM_BUILD_ENV:-f4dhuman}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"
TORCH_MIN_PY312="${MOMENTUM_TORCH_MIN_PY312:-2.5.1}"
TORCH_MAX_PY312="${MOMENTUM_TORCH_MAX_PY312:-2.6}"
CUDA_VERSION="${MOMENTUM_CUDA_VERSION:-12.1}"

eval "$(conda shell.bash hook)"

TORCH_PREFIX="$(conda env list | awk -v env="${TORCH_ENV_NAME}" '($1==env){print $2} ($1=="*" && $2==env){print $3}' | head -n 1)"
if [[ -z "${TORCH_PREFIX}" ]] || [[ ! -d "${TORCH_PREFIX}" ]]; then
  echo "Unable to locate torch env '${TORCH_ENV_NAME}'. Set MOMENTUM_TORCH_ENV." >&2
  exit 1
fi

TORCH_PY="${TORCH_PREFIX}/bin/python"
if [[ ! -x "${TORCH_PY}" ]]; then
  echo "Torch env python not found at ${TORCH_PY}" >&2
  exit 1
fi

TORCH_VERSION="$("${TORCH_PY}" -c "import torch; print(torch.__version__)")"
TORCH_CUDA_VERSION="$("${TORCH_PY}" -c "import torch; print(torch.version.cuda or 'None')")"
TORCH_CUDA_AVAILABLE="$("${TORCH_PY}" -c "import torch; print(torch.cuda.is_available())")"
echo "Using torch from '${TORCH_ENV_NAME}': ${TORCH_VERSION} (CUDA ${TORCH_CUDA_VERSION}, available=${TORCH_CUDA_AVAILABLE})"
if [[ "${TORCH_CUDA_VERSION}" == "None" ]] || [[ "${TORCH_CUDA_AVAILABLE}" != "True" ]]; then
  echo "ERROR: f4dhuman PyTorch is CPU-only. Install CUDA PyTorch in that env first." >&2
  exit 1
fi

PY_VER="$("${TORCH_PY}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")"

# Create/Update build env
if [[ "$FORCE_RECREATE" == "1" ]] || ! conda env list | awk '{print $1}' | grep -qx "${BUILD_ENV_NAME}"; then
  echo "Creating conda env '${BUILD_ENV_NAME}' with python=${PY_VER}..."
  conda create -y -n "${BUILD_ENV_NAME}" "python=${PY_VER}"
fi

echo "Activating build env '${BUILD_ENV_NAME}'..."
conda activate "${BUILD_ENV_NAME}"

# Install CUDA dev tools from nvidia channel (match pytorch-cuda=12.1)
echo "Installing CUDA ${CUDA_VERSION} development tools from nvidia channel..."
conda install -y -c nvidia -c conda-forge \
  "cuda-cudart-dev=${CUDA_VERSION}.*" \
  "cuda-cudart-static=${CUDA_VERSION}.*" \
  "cuda-nvcc=${CUDA_VERSION}.*" \
  "cuda-nvrtc-dev=${CUDA_VERSION}.*" \
  "libcublas-dev=${CUDA_VERSION}.*" \
  "cuda-cccl=${CUDA_VERSION}.*"

echo "Installing build tools into '${BUILD_ENV_NAME}'..."
conda install -y -c conda-forge \
  cmake \
  ninja \
  pybind11 \
  scikit-build-core \
  "gxx_linux-64=12.*" \
  "gcc_linux-64=12.*"

echo "Installing C++ dependencies into '${BUILD_ENV_NAME}'..."
conda install -y -c conda-forge \
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
  libnvjitlink

echo "Installing Python packaging tools via pip..."
pip install jinja2 patchelf auditwheel setuptools-scm setuptools

# Remove any pip-installed NVIDIA CUDA wheels that can conflict with conda CUDA libs.
python - <<'PY'
import importlib.metadata as md
import subprocess
import sys

pkgs = [d.metadata["Name"] for d in md.distributions() if d.metadata["Name"].lower().startswith("nvidia-")]
if pkgs:
    subprocess.check_call([sys.executable, "-m", "pip", "uninstall", "-y", *pkgs])
PY

# nvcc expects NVVM under targets/x86_64-linux; conda places it at $CONDA_PREFIX/nvvm.
if [[ ! -e "${CONDA_PREFIX}/targets/x86_64-linux/nvvm" ]] && [[ -d "${CONDA_PREFIX}/nvvm" ]]; then
  ln -s "${CONDA_PREFIX}/nvvm" "${CONDA_PREFIX}/targets/x86_64-linux/nvvm"
fi

# Setup build environment variables
export CMAKE_PREFIX_PATH="${CONDA_PREFIX}"
export CUDA_HOME="${CONDA_PREFIX}"
export CUDA_TOOLKIT_ROOT_DIR="${CONDA_PREFIX}"
export CUDACXX="${CONDA_PREFIX}/bin/nvcc"
export PATH="${CONDA_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${TORCH_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

# Point CMake to torch from f4dhuman
TORCH_CMAKE_PATH="$("${TORCH_PY}" -c 'import torch; print(torch.utils.cmake_prefix_path)')"
export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}:${TORCH_CMAKE_PATH}"
export Torch_DIR="${TORCH_PREFIX}/share/cmake/Torch"
if [[ ! -f "${Torch_DIR}/TorchConfig.cmake" ]] && [[ -d "${TORCH_CMAKE_PATH}/Torch" ]]; then
  export Torch_DIR="${TORCH_CMAKE_PATH}/Torch"
fi

# Generate pyproject.toml variants
echo "Generating pyproject.toml variants..."
python scripts/generate_pyproject.py \
  --torch-min-py312 "${TORCH_MIN_PY312}" \
  --torch-max-py312 "${TORCH_MAX_PY312}"

# Determine variant (CPU or GPU)
VARIANT="gpu"
PY_SUFFIX=$(python -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')")

echo "Building ${VARIANT} wheel for Python ${PY_VER} using torch from '${TORCH_ENV_NAME}'..."

cp pyproject.toml pyproject.toml.bak
cp "pyproject-pypi-${VARIANT}.toml" pyproject.toml 2>/dev/null || cp "pyproject-pypi-${VARIANT}-py${PY_SUFFIX}.toml" pyproject.toml

rm -rf dist build
mkdir -p dist

export CMAKE_ARGS="-DMOMENTUM_ENABLE_FBX_SAVING=OFF -DMOMENTUM_ENABLE_SIMD=OFF -DMOMENTUM_USE_SYSTEM_GOOGLETEST=ON -DMOMENTUM_USE_SYSTEM_PYBIND11=OFF -DMOMENTUM_USE_SYSTEM_RERUN_CPP_SDK=ON -DBUILD_SHARED_LIBS=OFF -DMOMENTUM_BUILD_RENDERER=OFF -Ddrjit_DIR=${CONDA_PREFIX}/share/cmake/drjit"

echo "Running pip wheel..."
pip wheel . --no-deps --no-build-isolation --wheel-dir=dist

mv pyproject.toml.bak pyproject.toml

echo "Repairing wheel with auditwheel..."
auditwheel repair \
    --exclude 'libtorch*.so' --exclude 'libc10*.so' \
    --exclude 'libcu*.so*' --exclude 'libnv*.so*' --exclude 'libmkl*.so' \
    dist/pymomentum_*.whl -w dist/repaired

echo "Done. Wheel is in dist/repaired/"

WHEEL_FILE=$(find dist -maxdepth 1 -name "*.whl" | head -n 1)
echo "Generated wheel: ${WHEEL_FILE}"
