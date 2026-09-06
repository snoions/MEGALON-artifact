#!/usr/bin/env bash
#
# setup_lean.sh - disk-conscious replacement for scripts/setup.sh
#
# Same end state as setup.sh, minus the parts that are never compiled and the parts that
# only exist for interactive development. Safe to re-run: every step checks before acting,
# and no step aborts the script just because it was already done.
#
# Differences from setup.sh:
#   * submodules: inits only the six that are actually used (yaml-cpp, abseil-cpp, oneTBB,
#     gtl, unordered_dense, robin-map) at depth 1, instead of --recursive over machnet,
#     capnproto and hostrpc, none of which this project add_subdirectory's;
#   * rewrites the yaml-cpp submodule URL from git@github.com: to https, which otherwise
#     fails on any machine without a GitHub SSH key;
#   * apt: drops valgrind, cloc, libc++-dev; keeps libmemkind-dev and libhwloc-dev, which
#     are linked into libmegalon.so and are easy to miss;
#   * LLVM: installs clang-17 only, not clang+lldb+lld+clangd (LLVM_PKGS to override);
#   * rustup can be redirected off the root filesystem via RUSTUP_HOME/CARGO_HOME;
#   * skips the hostrpc patch (nothing built here uses it) unless WITH_HOSTRPC=1 - in
#     setup.sh, `git apply` on a second run fails and, under `set -e`, kills the script
#     before setup_logical_node.sh ever runs;
#   * fixes `mkdir -p RESULT_DIR` (missing $), which in setup.sh creates a literal
#     directory named RESULT_DIR and never creates the real results path;
#   * drops the .vscode/settings.json block, which calls jq without installing it.
#
# What it does NOT skip, because the build or the eval scripts need it:
#   g++-11 (the toolchain hard-codes /usr/lib/gcc/x86_64-linux-gnu/11), clang-format
#   (the fmt target), libnuma/libhwloc/libmemkind, rust nightly, the ~/.bashrc exports,
#   the intel_uncore_frequency module, and scripts/setup_logical_node.sh.
#
# Usage:
#   ./scripts/setup_lean.sh [NUMA_MEM] [LOGICAL_NODE_NUM] [KEY_SIZE] [NUM_NUMA]
#     defaults: 0 3 24   (same as setup.sh)
#     NUM_NUMA: optional override. Needed when the machine has a CPU-less NUMA node (a real
#     CXL device): exclude it, or a thread will be asked to run on a node with no CPUs.
#
# Environment:
#   RESULT_DIR=/path       where benchmark results go. Default: the first writable
#                          candidate among /mydata, /data, /scratch, /mnt/data, then
#                          $HOME. Results are large (latency samples from every thread),
#                          so prefer a big volume. Must end in "/": the eval scripts do
#                          ${RACKOBJ_RESULT_DIR}hashmap, not ${...}/hashmap.
#   RUSTUP_HOME=/path      keep the rust toolchain off the root filesystem
#   CARGO_HOME=/path
#   LLVM_PKGS="clang-17 lld-17"   override the LLVM package set
#   WITH_HOSTRPC=1         also init hostrpc and apply third-party/hostrpc.diff
#   SKIP_APT=1             assume the system packages are already there
#   SKIP_RUST=1            assume cargo/rust nightly is already there
#   SKIP_UNCORE=1          do not load intel_uncore_frequency (real CXL memory: the
#                          frequency slowdown emulates CXL and should not be used)

set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

NUMA_MEM="${1:-0}"
LOGICAL_NODE_NUM="${2:-3}"
KEY_SIZE="${3:-24}"
# Optional 4th argument: override NUM_NUMA.
#
# setup_logical_node.sh derives NUM_NUMA from `lscpu`, which counts every NUMA node -
# including a CPU-less CXL node. GetExecNodes() then treats candidates 0,1,2,... (skipping
# NUMA_MEM) as exec nodes, so a CPU-less node becomes an exec node, pinThreadtoNumaNode()
# cannot move a thread there, and helper.cc:43 aborts with
#     Check failed: numa_node == (uint32_t)target_node
# Set NUM_NUMA so that the implied exec nodes all have CPUs. With NUMA_MEM=0 and a CXL node
# at 2, NUM_NUMA=2 gives exec={1} and leaves node 2 out entirely.
NUM_NUMA_OVERRIDE="${4:-${NUM_NUMA_OVERRIDE:-}}"

# Pick a results volume. /mydata is the artifact's CloudLab convention, but it does not
# exist everywhere and / is often the small partition, so probe rather than assume.
pick_result_root() {
    local c
    for c in /mydata /data /scratch /mnt/data; do
        [[ -d "$c" && -w "$c" ]] && { echo "$c/$USER"; return; }
    done
    # A candidate that exists but is not writable is usually a mounted volume we can be
    # given a subdirectory on; try once, quietly.
    for c in /mydata /data /scratch /mnt/data; do
        if [[ -d "$c" ]] && sudo -n mkdir -p "$c/$USER" 2>/dev/null && sudo -n chown "$USER" "$c/$USER" 2>/dev/null; then
            echo "$c/$USER"; return
        fi
    done
    echo "$HOME"
}
if [[ -z "${RESULT_DIR:-}" ]]; then
    RESULT_DIR="$(pick_result_root)/rackobj-benchmarks/benchmarks/results/"
fi
# The eval scripts concatenate without a separator, so the trailing slash is required.
[[ "${RESULT_DIR}" == */ ]] || RESULT_DIR="${RESULT_DIR}/"
LLVM_VERSION=17
LLVM_PKGS="${LLVM_PKGS:-clang-${LLVM_VERSION}}"
WITH_HOSTRPC="${WITH_HOSTRPC:-0}"
SKIP_APT="${SKIP_APT:-0}"
SKIP_RUST="${SKIP_RUST:-0}"

log()  { echo -e "\033[1;34m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[setup]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[setup]\033[0m $*" >&2; exit 1; }

log "repo:        ${PROJECT_ROOT}"
log "logical node config: NUMA_MEM=${NUMA_MEM} LOGICAL_NODE_NUM=${LOGICAL_NODE_NUM} KEY_SIZE=${KEY_SIZE}"
log "result dir:  ${RESULT_DIR}"
df -Ph "${PROJECT_ROOT}" | awk 'NR==2 {print "[setup] free on " $6 ": " $4}'

# ---------------------------------------------------------------------------------------
# 1. Submodules - only the ones that are compiled or included.
#    add_subdirectory: yaml-cpp, abseil-cpp, oneTBB.  Header-only includes: gtl
#    (gtl/phmap.hpp), unordered_dense (ankerl/unordered_dense.h).  robin-map is on an
#    include path but nothing includes it; it is cheap, so keep it to avoid surprises.
# ---------------------------------------------------------------------------------------
log "initializing submodules"
git config submodule.third-party/yaml-cpp.url https://github.com/jbeder/yaml-cpp.git
SUBMODULES=(
    third-party/yaml-cpp
    third-party/abseil-cpp
    third-party/oneTBB
    third-party/gtl
    third-party/unordered_dense
    third-party/robin-map
)
if [[ "${WITH_HOSTRPC}" == "1" ]]; then
    SUBMODULES+=(third-party/hostrpc)
fi
for m in "${SUBMODULES[@]}"; do
    if [[ -n "$(ls -A "${PROJECT_ROOT}/${m}" 2>/dev/null)" ]]; then
        log "  ${m} (already present)"
    else
        log "  ${m}"
        git submodule update --init --depth 1 "${m}"
    fi
done
if [[ "${WITH_HOSTRPC}" == "1" ]]; then
    warn "skipped machnet / capnproto: not built by this project"
else
    warn "skipped machnet / capnproto / hostrpc: not built by this project"
fi

if [[ "${WITH_HOSTRPC}" == "1" ]]; then
    # Idempotent: --check first, so a second run does not abort the script.
    if git apply --check third-party/hostrpc.diff --directory third-party/hostrpc 2>/dev/null; then
        git apply third-party/hostrpc.diff --directory third-party/hostrpc
        log "applied hostrpc.diff"
    else
        log "hostrpc.diff already applied (or does not apply); skipping"
    fi
fi

# ---------------------------------------------------------------------------------------
# 2. System packages.
#    memkind and hwloc are linked into libmegalon.so; liburcu and libclang are needed by
#    the NR rust build. g++-11 must exist because the toolchain file hard-codes
#    /usr/lib/gcc/x86_64-linux-gnu/11.
# ---------------------------------------------------------------------------------------
if [[ "${SKIP_APT}" == "1" ]]; then
    log "skipping apt (SKIP_APT=1)"
else
    log "installing system packages"
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        make pkg-config python3-pip python3-numpy \
        numactl libnuma-dev libhwloc-dev libmemkind-dev zlib1g-dev liburcu-dev \
        libclang-dev clang-format g++-11 \
        wget gnupg lsb-release software-properties-common ca-certificates

    if [[ ! -d /usr/lib/gcc/x86_64-linux-gnu/11 ]]; then
        die "/usr/lib/gcc/x86_64-linux-gnu/11 missing after installing g++-11; the toolchain file hard-codes this path"
    fi

    # cmake: CMakeLists.txt says cmake_minimum_required(VERSION 3.24). Ubuntu 22.04 ships
    # 3.22.1, which is NOT enough - that is why upstream setup.sh installs cmake from pip.
    CMAKE_MIN=3.24
    cmake_version() { command -v cmake > /dev/null && cmake --version | head -1 | awk '{print $3}'; }
    cmake_ok() {
        local have="$1"
        [[ -n "${have}" ]] && [[ "$(printf '%s\n%s\n' "${have}" "${CMAKE_MIN}" | sort -V | head -1)" == "${CMAKE_MIN}" ]]
    }

    have="$(cmake_version || true)"
    if cmake_ok "${have}"; then
        log "cmake ${have} is new enough (need >= ${CMAKE_MIN})"
    else
        [[ -n "${have}" ]] && log "cmake ${have} is too old (need >= ${CMAKE_MIN}); installing a newer one"
        # apt first, in case the distro is new enough; then pip, which is what upstream does.
        sudo apt-get install -y --no-install-recommends cmake || true
        if ! cmake_ok "$(cmake_version || true)"; then
            sudo pip install -U cmake --break-system-packages 2>/dev/null || sudo pip install -U cmake
            hash -r
        fi
        have="$(cmake_version || true)"
        cmake_ok "${have}" || die "cmake ${have:-<none>} still below ${CMAKE_MIN}.
        pip installs to /usr/local/bin; check that it precedes /usr/bin on PATH:
            which -a cmake
        or install from Kitware:  https://apt.kitware.com"
        log "cmake ${have} ready ($(command -v cmake))"
    fi

    # LLVM: prebuilt packages from apt.llvm.org. This does NOT build LLVM from source.
    if command -v "clang-${LLVM_VERSION}" > /dev/null; then
        log "clang-${LLVM_VERSION} already present"
    else
        log "adding apt.llvm.org repo and installing: ${LLVM_PKGS}"
        codename="$(lsb_release -cs)"
        wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
            | sudo tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc > /dev/null
        sudo add-apt-repository -y \
            "deb http://apt.llvm.org/${codename}/ llvm-toolchain-${codename}-${LLVM_VERSION} main"
        sudo apt-get update -y
        # shellcheck disable=SC2086
        sudo apt-get install -y --no-install-recommends ${LLVM_PKGS}
    fi

    sudo apt-get clean
    sudo rm -rf /var/lib/apt/lists/*
fi

# ---------------------------------------------------------------------------------------
# 3. Rust nightly for the NR libraries.
#    rustup installs into $RUSTUP_HOME (default ~/.rustup) - export RUSTUP_HOME and
#    CARGO_HOME to a big volume before running this if / is tight.
# ---------------------------------------------------------------------------------------
if [[ "${SKIP_RUST}" == "1" ]]; then
    log "skipping rust setup (SKIP_RUST=1)"
elif command -v cargo > /dev/null; then
    log "cargo already present: $(cargo --version)"
else
    log "installing rust (RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}, CARGO_HOME=${CARGO_HOME:-$HOME/.cargo})"
    # --profile minimal, and no `rustup toolchain install nightly`: the pinned channel in
    # third-party/nr_rust/rust-toolchain is what the build actually uses, and installing a
    # second unpinned nightly (as install_deps.sh does) just doubles the footprint.
    # rust-toolchain still asks for profile "default" + rustc-dev + rust-src, which is
    # where most of ~/.rustup goes - run scripts/slim_rust.sh --slim to trim that.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain none
    # shellcheck disable=SC1091
    source "${CARGO_HOME:-$HOME/.cargo}/env"
    # cargo installs the pinned toolchain on first use, driven by rust-toolchain.
    log "rust installed; the pinned toolchain downloads on the first cargo build"
    log "tip: ./scripts/slim_rust.sh --report  shows what ~/.rustup costs"
fi

# ---------------------------------------------------------------------------------------
# 4. Shell environment.
# ---------------------------------------------------------------------------------------
BASHRC="$HOME/.bashrc"
# Adds an export, or rewrites it when it exists with a different value. The original
# setup.sh hardcodes RESULT_DIR=/mydata/$USER/..., so a machine where that ran once has a
# stale export in ~/.bashrc; skipping it (the previous behaviour here) left every eval
# script pointed at /mydata and failing with "mkdir: cannot create directory".
add_export() {  # add_export VAR value
    local var="$1" val="$2" existing
    if grep -q "^export ${var}=" "${BASHRC}"; then
        existing="$(grep -m1 "^export ${var}=" "${BASHRC}" | cut -d= -f2-)"
        if [[ "${existing}" == "${val}" ]]; then
            log "  ${var} already set to ${val}"
            return
        fi
        [[ -f "${BASHRC}.megalon.bak" ]] || cp "${BASHRC}" "${BASHRC}.megalon.bak"
        sed -i "s|^export ${var}=.*|export ${var}=${val}|" "${BASHRC}"
        warn "  ${var} was ${existing}, rewrote to ${val} (backup: ${BASHRC}.megalon.bak)"
    else
        echo "export ${var}=${val}" >> "${BASHRC}"
        log "  added ${var}=${val} to ~/.bashrc"
    fi
}

log "updating ~/.bashrc"
grep -q "^# megalon environment" "${BASHRC}" || echo -e "\n# megalon environment" >> "${BASHRC}"
add_export CXX "clang++-${LLVM_VERSION}"
add_export CC  "clang-${LLVM_VERSION}"
add_export LD  "clang++-${LLVM_VERSION}"
add_export RACKOBJ_RESULT_DIR "${RESULT_DIR}"
[[ -n "${RUSTUP_HOME:-}" ]] && add_export RUSTUP_HOME "${RUSTUP_HOME}"
[[ -n "${CARGO_HOME:-}" ]]  && add_export CARGO_HOME  "${CARGO_HOME}"

# setup.sh has `mkdir -p RESULT_DIR` (missing $), so the real directory never gets made
# and the eval scripts fail late, after the build.
if [[ -n "${RACKOBJ_RESULT_DIR:-}" && "${RACKOBJ_RESULT_DIR}" != "${RESULT_DIR}" ]]; then
    warn "RACKOBJ_RESULT_DIR is ${RACKOBJ_RESULT_DIR} in this shell, but ~/.bashrc now says ${RESULT_DIR}"
    warn "  editing ~/.bashrc does not change the running shell - run:"
    warn "      export RACKOBJ_RESULT_DIR=${RESULT_DIR}"
    warn "  or open a new shell before running any eval script."
fi

if mkdir -p "${RESULT_DIR}" 2>/dev/null; then
    log "result dir ready: ${RESULT_DIR}"
    avail="$(df -Ph "${RESULT_DIR}" | awk 'NR==2 {print $4 " free on " $6}')"
    log "  ${avail}"
    # Every thread writes one latency sample per measured operation; at 42 threads that
    # is easily a gigabyte per run. LATENCY_SAMPLE_EVERY=N in the benchmark environment
    # records 1 in N instead.
    case "$(df -P --output=avail "${RESULT_DIR}" | tail -1)" in
        ''|*[!0-9]*) : ;;
        *) [[ "$(df -P --output=avail "${RESULT_DIR}" | tail -1)" -lt 20971520 ]] &&
               warn "under 20 GB free here; consider LATENCY_SAMPLE_EVERY=10 when running the benchmarks" ;;
    esac
else
    warn "could not create ${RESULT_DIR}"
    warn "  set RESULT_DIR to somewhere writable and re-run, e.g."
    warn "  RESULT_DIR=\$HOME/rackobj-benchmarks/benchmarks/results/ ./scripts/setup_lean.sh ${NUMA_MEM} ${LOGICAL_NODE_NUM} ${KEY_SIZE}"
fi

# ---------------------------------------------------------------------------------------
# 5. Uncore frequency module.
#    scripts/set_uncore_frequency.sh drops the NUMA_MEM package to 800 MHz to *emulate*
#    CXL latency on a DRAM-only machine. On a machine with real CXL memory that emulation
#    is wrong - skip it with UNCORE_MODE=off (or UNCORE_MODE=pin, which holds every
#    package at a fixed frequency without slowing anything, to cut run-to-run variance).
#    Set SKIP_UNCORE=1 here if you do not want the module loaded at all.
# ---------------------------------------------------------------------------------------
if [[ "${SKIP_UNCORE:-0}" == "1" ]]; then
    log "skipping intel_uncore_frequency (SKIP_UNCORE=1); run eval scripts with UNCORE_MODE=off"
elif lsmod | grep -q intel_uncore_frequency; then
    log "intel_uncore_frequency already loaded"
else
    log "loading intel_uncore_frequency"
    sudo modprobe intel_uncore_frequency || warn "modprobe failed - eval scripts will refuse to run"
fi
if [[ "${SKIP_UNCORE:-0}" != "1" ]]; then
    echo "intel_uncore_frequency" | sudo tee /etc/modules-load.d/megalon.conf > /dev/null 2>&1 \
        && log "module set to load on boot" || true
fi

# ---------------------------------------------------------------------------------------
# 6. Logical node configuration. Rewrites src/common/constants.h,
#    third-party/nr_rust/ffi/constants.rs and benchmarks/common.h (including CPU_FREQ_GHZ,
#    which the latency numbers depend on). Must run before compiling.
# ---------------------------------------------------------------------------------------
log "configuring logical nodes"
./scripts/setup_logical_node.sh "${NUMA_MEM}" "${LOGICAL_NODE_NUM}" "${KEY_SIZE}"

node_has_cpus() { [[ -s "/sys/devices/system/node/node$1/cpulist" ]] && [[ -n "$(cat "/sys/devices/system/node/node$1/cpulist")" ]]; }

if [[ -n "${NUM_NUMA_OVERRIDE}" ]]; then
    sed -i -E "s|^(#define[[:space:]]+NUM_NUMA[[:space:]]+)[0-9]+|\1${NUM_NUMA_OVERRIDE}|" src/common/constants.h
    sed -i -E "s|^(pub const NUM_EXEC: usize = ).*|\1$((NUM_NUMA_OVERRIDE - 1));|" third-party/nr_rust/ffi/constants.rs
    log "NUM_NUMA overridden to ${NUM_NUMA_OVERRIDE} (NUM_EXEC=$((NUM_NUMA_OVERRIDE - 1)))"
fi

# Validate: every exec node implied by (NUM_NUMA, NUMA_MEM) must have CPUs.
eff_num_numa="$(grep -E '^#define[[:space:]]+NUM_NUMA' src/common/constants.h | awk '{print $3}')"
exec_nodes=(); candidate=0
while [[ "${#exec_nodes[@]}" -lt "$((eff_num_numa - 1))" ]] && [[ "${candidate}" -lt 64 ]]; do
    [[ "${candidate}" == "${NUMA_MEM}" ]] || exec_nodes+=("${candidate}")
    candidate=$((candidate + 1))
done
log "NUM_NUMA=${eff_num_numa}, NUMA_MEM=${NUMA_MEM} -> exec nodes: ${exec_nodes[*]}"
for n in "${exec_nodes[@]}"; do
    if ! node_has_cpus "$n"; then
        warn "exec node ${n} has NO CPUs. Threads cannot be pinned there:"
        warn "  helper.cc:43  Check failed: numa_node == (uint32_t)target_node"
        warn "Re-run with a NUM_NUMA that excludes it, e.g.:"
        warn "  ./scripts/setup_lean.sh ${NUMA_MEM} ${LOGICAL_NODE_NUM} ${KEY_SIZE} ${n}"
    fi
done

# ---------------------------------------------------------------------------------------
# 7. Sanity checks.
# ---------------------------------------------------------------------------------------
if ldconfig -p | grep -q 'libstdc++.*12'; then
    warn "libstdc++ from GCC 12 is installed; it can interfere with the clang/GCC-11 pairing"
    ldconfig -p | grep 'libstdc++.*12' | awk '{print "        " $NF}' | sort -u
fi
numa_nodes="$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)"
[[ "${numa_nodes}" -ge 2 ]] || warn "only ${numa_nodes} NUMA node(s) detected; this artifact needs at least 2"

log "done."
log "next:  source ~/.bashrc  &&  ./scripts/build_lean.sh"
log "note:  re-running setup_logical_node.sh changes constants.rs; build_lean.sh detects"
log "       that and rebuilds the NR library rather than reusing a stale .a"
