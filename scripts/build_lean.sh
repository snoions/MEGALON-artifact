#!/usr/bin/env bash
#
# build_lean.sh - space-conscious replacement for scripts/build.sh
#
# Differences from build.sh:
#   * builds only the targets you need (default: megalon + the two hashmap benchmarks)
#     instead of every benchmark and every abseil/TBB target;
#   * builds only the NR rust variant the current CMake flags actually link, instead of
#     all three, and deletes the intermediate cargo target tree afterwards (keeping the
#     .a files CMake needs);
#   * skips the NR rebuild entirely when the .a files are already present;
#   * incremental by default - does not `rm -rf build` on every invocation;
#   * can put the build tree on another filesystem (BUILD_DIR=/mydata/... ) and symlink
#     ./build to it, so the eval scripts' hard-coded ./build/benchmarks paths still work;
#   * can use a clang that is not installed system-wide (CLANG_BIN_DIR=/mydata/llvm17/bin);
#   * can suppress the `fmt` target's clang-format pass without editing CMakeLists.txt;
#   * optional post-build prune of object files;
#   * reports disk usage before and after.
#
# Usage:
#   ./scripts/build_lean.sh [options]
#
# Options (all also settable as environment variables):
#   --targets "a b c"     targets to build          (TARGETS,  default: megalon hashmap-ro hashmap-rw)
#   --build-dir DIR       build tree location       (BUILD_DIR, default: <repo>/build)
#   --jobs N              parallel jobs             (JOBS, default: nproc)
#   --nr scr|noco|orig|all|skip
#                         which NR rust lib to build (NR_VARIANT, default: auto from CMakeLists.txt)
#   --clean               wipe the build tree first (CLEAN=1)
#   --no-fmt              skip the clang-format pass (NO_FMT=1)
#   --prune               delete object files after a successful build (PRUNE=1)
#   --keep-cargo          keep the intermediate cargo target trees (KEEP_CARGO=1)
#   --init-submodules     init only the submodules that are actually compiled
#   --toolchain FILE      CMake toolchain file      (TOOLCHAIN_FILE)
#   --clang-bin-dir DIR   directory holding clang/clang++ (CLANG_BIN_DIR); generates a
#                         toolchain file pointing at it, for a relocated LLVM tarball
#   -h | --help
#
# Examples:
#   ./scripts/build_lean.sh                                  # lean incremental build
#   ./scripts/build_lean.sh --clean --prune                  # smallest footprint, one shot
#   BUILD_DIR=/mydata/$USER/megalon-build ./scripts/build_lean.sh
#   CLANG_BIN_DIR=/mydata/llvm17/bin ./scripts/build_lean.sh

set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

TARGETS="${TARGETS:-megalon hashmap-ro hashmap-rw}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_ROOT}/build}"
JOBS="${JOBS:-$(nproc)}"
NR_VARIANT="${NR_VARIANT:-auto}"
CLEAN="${CLEAN:-0}"
NO_FMT="${NO_FMT:-0}"
PRUNE="${PRUNE:-0}"
KEEP_CARGO="${KEEP_CARGO:-0}"
INIT_SUBMODULES="${INIT_SUBMODULES:-0}"
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-cmake-variant/toolchains/clang17-gcc.cmake}"
CLANG_BIN_DIR="${CLANG_BIN_DIR:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)          TARGETS="$2"; shift 2 ;;
        --build-dir)        BUILD_DIR="$2"; shift 2 ;;
        --jobs|-j)          JOBS="$2"; shift 2 ;;
        --nr)               NR_VARIANT="$2"; shift 2 ;;
        --toolchain)        TOOLCHAIN_FILE="$2"; shift 2 ;;
        --clang-bin-dir)    CLANG_BIN_DIR="$2"; shift 2 ;;
        --clean)            CLEAN=1; shift ;;
        --no-fmt)           NO_FMT=1; shift ;;
        --prune)            PRUNE=1; shift ;;
        --keep-cargo)       KEEP_CARGO=1; shift ;;
        --init-submodules)  INIT_SUBMODULES=1; shift ;;
        -h|--help)          sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

log()  { echo -e "\033[1;34m[lean]\033[0m $*"; }
warn() { echo -e "\033[1;33m[lean]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[lean]\033[0m $*" >&2; exit 1; }

space_of() { df -Ph "$1" 2>/dev/null | awk 'NR==2 {print $4 " free on " $6}'; }

NR_DIR="${PROJECT_ROOT}/third-party/nr_rust"
NR_FFI="${NR_DIR}/ffi"
NR_REL="${NR_FFI}/target/release"

log "repo:      ${PROJECT_ROOT}"
log "build dir: ${BUILD_DIR}  [$(space_of "$(dirname "${BUILD_DIR}")")]"
log "targets:   ${TARGETS}"

# ---------------------------------------------------------------------------------------
# 0. Optional: init only the submodules that are actually compiled.
#    yaml-cpp, abseil-cpp and oneTBB are add_subdirectory'd; gtl and unordered_dense are
#    header-only includes. machnet, capnproto and hostrpc are never built by this project -
#    `git submodule update --init --recursive` clones them for nothing.
# ---------------------------------------------------------------------------------------
if [[ "${INIT_SUBMODULES}" == "1" ]]; then
    # .gitmodules points yaml-cpp at git@github.com:, which needs an SSH key. Force https.
    git config submodule.third-party/yaml-cpp.url https://github.com/jbeder/yaml-cpp.git
    for m in third-party/yaml-cpp third-party/abseil-cpp third-party/oneTBB \
             third-party/gtl third-party/unordered_dense third-party/robin-map; do
        log "submodule: ${m}"
        git submodule update --init --depth 1 "${m}"
    done
    warn "skipped machnet / capnproto / hostrpc (not compiled by this project)."
    warn "if you need setup.sh's 'git apply third-party/hostrpc.diff', init hostrpc too."
fi

# ---------------------------------------------------------------------------------------
# 1. NR rust libraries.
#    third-party/nr_rust/cpp 'make libs' builds all three variants (scr / no-coherence /
#    original) into three separate cargo target trees, and its `clean` prerequisite wipes
#    target/ first, so every build.sh run recompiles all of it. CMake only links one of
#    them, decided by LIMITED_SCR / NO_COHERENCE in the active CMakeLists.txt.
# ---------------------------------------------------------------------------------------
detect_nr_variant() {
    local cml="${PROJECT_ROOT}/CMakeLists.txt"
    # match the forced settings near the top of CMakeLists.txt, e.g.
    #   set(LIMITED_SCR ON CACHE BOOL "limited SCR" FORCE)
    if grep -qE '^[[:space:]]*set\([[:space:]]*LIMITED_SCR[[:space:]]+ON' "${cml}" 2>/dev/null; then
        echo scr
    elif grep -qE '^[[:space:]]*set\([[:space:]]*NO_COHERENCE[[:space:]]+ON' "${cml}" 2>/dev/null; then
        echo noco
    else
        echo orig
    fi
}

if [[ "${NR_VARIANT}" == "auto" ]]; then
    NR_VARIANT="$(detect_nr_variant)"
    log "NR variant (auto-detected from CMakeLists.txt): ${NR_VARIANT}"
fi

# A copy of the .a kept outside target/, with a stamp of the constants it was built from.
# third-party/nr_rust/cpp's `make libs` has `clean` as a prerequisite and wipes
# ffi/target entirely, so anything left only in target/release is one build.sh away from
# being gone - and if rustup has been uninstalled, it cannot be regenerated.
NR_PREBUILT="${NR_DIR}/prebuilt"

nr_constants_stamp() {
    awk '/^pub const (LOGICAL_NODE_NUM|NUMA_MEM|NUM_EXEC|KEY_SIZE)/ {gsub(/[ ;]/,""); print}' \
        "${NR_FFI}/constants.rs" 2>/dev/null | sort | tr '\n' ' '
}

nr_stash() {  # nr_stash <variant>
    local out; out="$(basename "$(nr_lib_for "$1")")"
    mkdir -p "${NR_PREBUILT}"
    cp -f "${NR_REL}/${out}" "${NR_PREBUILT}/${out}"
    nr_constants_stamp > "${NR_PREBUILT}/${out}.stamp"
    log "stashed ${out} in ${NR_PREBUILT} (survives 'make libs' / build.sh)"
}

nr_restore() {  # nr_restore <variant>; 0 if a matching stash was put back
    local out; out="$(basename "$(nr_lib_for "$1")")"
    [[ -f "${NR_PREBUILT}/${out}" ]] || return 1
    local want have
    want="$(nr_constants_stamp)"
    have="$(cat "${NR_PREBUILT}/${out}.stamp" 2>/dev/null)"
    if [[ "${want}" != "${have}" ]]; then
        warn "stashed ${out} was built for different constants - not reusing"
        warn "  stash:  ${have}"
        warn "  now:    ${want}"
        return 1
    fi
    mkdir -p "${NR_REL}"
    cp -f "${NR_PREBUILT}/${out}" "${NR_REL}/${out}"
    touch "${NR_REL}/${out}"
    log "restored ${out} from ${NR_PREBUILT} (constants match; no cargo needed)"
    return 0
}

nr_lib_for() {
    case "$1" in
        scr)  echo "${NR_REL}/libnr_hashmap.a" ;;
        noco) echo "${NR_REL}/libnr_hashmap_noco.a" ;;
        orig) echo "${NR_REL}/libnr_hashmap_orig.a" ;;
    esac
}

build_nr_variant() {
    local v="$1" feats target_dir out
    case "$v" in
        scr)  feats="scr";               target_dir="with_scr"; out="libnr_hashmap.a" ;;
        noco) feats="scr no-coherence";  target_dir="no_co";    out="libnr_hashmap_noco.a" ;;
        orig) feats="";                  target_dir="no_scr";   out="libnr_hashmap_orig.a" ;;
        *) die "unknown NR variant: $v" ;;
    esac

    log "building NR rust lib '${v}' -> ${out}"
    pushd "${NR_FFI}" > /dev/null
    if [[ -n "${feats}" ]]; then
        RUSTFLAGS="-C target-feature=+clflushopt" \
            cargo build --release --features "${feats}" --target-dir "target/${target_dir}"
    else
        cargo build --release --target-dir "target/${target_dir}"
    fi
    popd > /dev/null

    mkdir -p "${NR_REL}"
    cp "${NR_FFI}/target/${target_dir}/release/libnr_hashmap.a" "${NR_REL}/${out}"

    nr_stash "$v"

    if [[ "${KEEP_CARGO}" != "1" ]]; then
        # The .a is copied out; the cargo tree is the space hog and is not needed again
        # unless the rust sources change.
        log "dropping cargo tree target/${target_dir} ($(du -sh "${NR_FFI}/target/${target_dir}" 2>/dev/null | cut -f1))"
        rm -rf "${NR_FFI}/target/${target_dir}"
    fi
}

if [[ "${NR_VARIANT}" == "skip" ]]; then
    log "NR build skipped by request"
elif [[ "${NR_VARIANT}" == "all" ]]; then
    for v in scr noco orig; do build_nr_variant "$v"; done
else
    lib="$(nr_lib_for "${NR_VARIANT}")"
    # A stale .a is worse than a slow build: setup_logical_node.sh rewrites
    # ffi/constants.rs (LOGICAL_NODE_NUM, NUMA_MEM, NUM_EXEC, KEY_SIZE), and those values
    # are compiled into the NR library. Rebuild whenever a rust source is newer than it.
    nr_sources_newer() {
        [[ -n "$(find "${NR_FFI}" -path "${NR_FFI}/target" -prune -o \
                 -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
                 -newer "${lib}" -print -quit 2>/dev/null)" ]]
    }
    [[ -f "${lib}" ]] || nr_restore "${NR_VARIANT}" || true
    if [[ -f "${lib}" ]] && ! nr_sources_newer; then
        log "NR lib up to date, reusing: ${lib}"
    elif [[ -f "${lib}" ]]; then
        warn "rust sources are newer than ${lib##*/} (setup_logical_node.sh?) - rebuilding"
        command -v cargo > /dev/null || die "the NR library must be rebuilt but cargo is not installed.\n        Either restore a matching .a into ${NR_REL}/ (see ${NR_PREBUILT}),\n        or reinstall rust: third-party/nr_rust/install_deps.sh"
        build_nr_variant "${NR_VARIANT}"
    else
        command -v cargo > /dev/null || die "the NR library must be rebuilt but cargo is not installed.\n        Either restore a matching .a into ${NR_REL}/ (see ${NR_PREBUILT}),\n        or reinstall rust: third-party/nr_rust/install_deps.sh"
        build_nr_variant "${NR_VARIANT}"
    fi
fi

# ---------------------------------------------------------------------------------------
# 2. Toolchain.
# ---------------------------------------------------------------------------------------
if [[ -n "${CLANG_BIN_DIR}" ]]; then
    [[ -x "${CLANG_BIN_DIR}/clang++" ]] || die "no clang++ in ${CLANG_BIN_DIR}"
    GEN_TOOLCHAIN="${PROJECT_ROOT}/cmake-variant/toolchains/clang-local.cmake"
    GCC_INSTALL_DIR="${GCC_INSTALL_DIR:-/usr/lib/gcc/x86_64-linux-gnu/11}"
    [[ -d "${GCC_INSTALL_DIR}" ]] || warn "GCC_INSTALL_DIR ${GCC_INSTALL_DIR} does not exist"
    cat > "${GEN_TOOLCHAIN}" <<EOF
# generated by scripts/build_lean.sh - clang from ${CLANG_BIN_DIR}
set(CMAKE_C_COMPILER   "${CLANG_BIN_DIR}/clang")
set(CMAKE_CXX_COMPILER "${CLANG_BIN_DIR}/clang++")
set(GCC_TOOLCHAIN_ROOT "/usr")
set(GCC_INSTALL_DIR "${GCC_INSTALL_DIR}")
set(CMAKE_C_FLAGS_INIT   "--gcc-install-dir=\${GCC_INSTALL_DIR}")
set(CMAKE_CXX_FLAGS_INIT "--gcc-install-dir=\${GCC_INSTALL_DIR}")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "--gcc-toolchain=\${GCC_TOOLCHAIN_ROOT} --gcc-install-dir=\${GCC_INSTALL_DIR}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--gcc-toolchain=\${GCC_TOOLCHAIN_ROOT} --gcc-install-dir=\${GCC_INSTALL_DIR}")
set(CMAKE_BUILD_RPATH "\${GCC_INSTALL_DIR}")
set(CMAKE_INSTALL_RPATH "\${GCC_INSTALL_DIR}")
set(CMAKE_SKIP_BUILD_RPATH FALSE)
set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
EOF
    TOOLCHAIN_FILE="cmake-variant/toolchains/clang-local.cmake"
    log "generated toolchain ${TOOLCHAIN_FILE}"
fi

# CMakeLists.txt does add_dependencies(megalon fmt), which runs clang-format -i over
# lib/, src/ and benchmarks/ on every build. A no-op shim on PATH disables it without
# touching the checked-in CMakeLists.txt.
if [[ "${NO_FMT}" == "1" ]]; then
    SHIM_DIR="$(mktemp -d)"
    printf '#!/bin/sh\nexit 0\n' > "${SHIM_DIR}/clang-format"
    chmod +x "${SHIM_DIR}/clang-format"
    export PATH="${SHIM_DIR}:${PATH}"
    trap 'rm -rf "${SHIM_DIR}"' EXIT
    log "clang-format pass disabled (shim in ${SHIM_DIR})"
fi

# ---------------------------------------------------------------------------------------
# 3. Configure + build.
# ---------------------------------------------------------------------------------------
if [[ "${CLEAN}" == "1" ]]; then
    log "removing ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"

# The eval scripts call ./build/benchmarks/<bin>; keep that path valid when the real tree
# lives elsewhere.
if [[ "${BUILD_DIR}" != "${PROJECT_ROOT}/build" ]]; then
    if [[ -e "${PROJECT_ROOT}/build" && ! -L "${PROJECT_ROOT}/build" ]]; then
        warn "${PROJECT_ROOT}/build exists and is not a symlink; leaving it alone"
    else
        ln -sfn "${BUILD_DIR}" "${PROJECT_ROOT}/build"
        log "symlinked ./build -> ${BUILD_DIR}"
    fi
fi

# Fail early and clearly rather than deep inside a submodule's configure step.
CMAKE_MIN=3.24
cmake_have="$(cmake --version 2>/dev/null | head -1 | awk '{print $3}')"
if [[ -z "${cmake_have}" ]]; then
    die "cmake not found on PATH"
elif [[ "$(printf '%s\n%s\n' "${cmake_have}" "${CMAKE_MIN}" | sort -V | head -1)" != "${CMAKE_MIN}" ]]; then
    die "cmake ${cmake_have} is too old; CMakeLists.txt requires >= ${CMAKE_MIN}.
        Ubuntu 22.04 ships 3.22.1. Install a newer one:
            sudo pip install -U cmake      # what upstream setup.sh does; lands in /usr/local/bin
            which -a cmake                 # make sure /usr/local/bin comes before /usr/bin
        or use the Kitware apt repo: https://apt.kitware.com"
fi

log "configuring with cmake ${cmake_have}"
cmake -B "${BUILD_DIR}" -S . \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=OFF \
    -DBUILD_TESTING=OFF \
    -DYAML_CPP_BUILD_TESTS=OFF \
    -DYAML_CPP_BUILD_TOOLS=OFF \
    -DYAML_CPP_FORMAT_SOURCE=OFF \
    -DABSL_BUILD_TESTING=OFF \
    -DABSL_BUILD_TEST_HELPERS=OFF \
    -DTBB_TEST=OFF \
    -DTBB_EXAMPLES=OFF \
    -DTBB_STRICT=OFF \
    -DTBBMALLOC_PROXY_BUILD=OFF

log "building: ${TARGETS} (-j${JOBS})"
# shellcheck disable=SC2086
cmake --build "${BUILD_DIR}" -j "${JOBS}" --target ${TARGETS}

# ---------------------------------------------------------------------------------------
# 4. Post-build.
# ---------------------------------------------------------------------------------------
log "stripping binaries"
find "${BUILD_DIR}" -maxdepth 2 -type f \( -name '*.so' -o -perm -u+x \) \
    -exec sh -c 'file "$1" | grep -q ELF && strip --strip-unneeded "$1" 2>/dev/null' _ {} \; || true

if [[ "${PRUNE}" == "1" ]]; then
    before="$(du -sh "${BUILD_DIR}" | cut -f1)"
    warn "pruning object files - the next build will be a full rebuild, not incremental"
    find "${BUILD_DIR}" -name '*.o' -delete
    find "${BUILD_DIR}" -name '*.o.d' -delete
    log "build tree: ${before} -> $(du -sh "${BUILD_DIR}" | cut -f1)"
fi

log "done."
log "  libmegalon: $(ls -1 "${BUILD_DIR}"/libmegalon.so 2>/dev/null || echo '(not found - check target list)')"
for t in ${TARGETS}; do
    [[ "$t" == "megalon" ]] && continue
    bin="${BUILD_DIR}/benchmarks/${t}"
    [[ -f "${bin}" ]] && log "  ${t}: ${bin} ($(du -h "${bin}" | cut -f1))"
done
log "build tree: $(du -sh "${BUILD_DIR}" | cut -f1), $(space_of "${BUILD_DIR}")"
