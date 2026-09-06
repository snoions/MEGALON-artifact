#!/usr/bin/env bash
# Runs the two ported RACoherence hashmap benchmarks (read-only and 90/10 read-write).
# Modelled on scripts/eval/sample.sh.

sudo -v
while true; do sleep 60; sudo -n true; kill -0 "$$" || exit; done > /dev/null 2>&1 &

PREHEAT_TIME=10
EXEC_TIME=30

cd "$(dirname "$0")/../.."
PROJECT_ROOT="$(pwd)"

VARIANTS=("megalon")
ZIPFS=(0.99)
THREAD_COUNTS=(32)
# Object count. One MEGALON object per hash bucket at SLOT_SIZE=1024, so this also sets the
# shared-memory footprint: NUM_OBJS * 1KiB of object data. 1048576 objects = 1.00 GiB,
# matching the original's 128M x 8B GlobalEntry table exactly (see notes section 15).
NUM_OBJS=(1048576)
W_RATIOS=(0.1)          # for hashmap-rw; hashmap-ro is read-only by construction
SCR_SIZES=(200)
# Entries of the 8KB pointer-chase array PER LOGICAL NODE, in node-local DRAM (never on
# NUMA_MEM/CXL - the benchmark checks this). Total DRAM = LOGICAL_NODE_NUM x entries x 8KB,
# so it scales with LOGICAL_NODE_NUM: 65536 is 512 MB per node, i.e. 4 GB at
# LOGICAL_NODE_NUM=8, on top of local_size per exec node. 0 disables the traversal.
GRAPH_ENTRIES="${GRAPH_ENTRIES:-8192}"
# Key traces. KEY_TRACE is a directory holding a separate trace per benchmark, so the
# read-only and read-write runs can be driven by different key streams (files named ro
# and rw, text or raw int32 - the loader sniffs). Paths are relative
# to PROJECT_ROOT, which is where this script cds to.
#   KEY_TRACE=builtin        use MEGALON's own zipfian generator for both
#   RO_TRACE / RW_TRACE      override either path individually (or set one to "builtin")
KEY_TRACE="${KEY_TRACE:-./keytrace}"
if [ "$KEY_TRACE" = "builtin" ]; then
    RO_TRACE="${RO_TRACE:-builtin}"
    RW_TRACE="${RW_TRACE:-builtin}"
else
    RO_TRACE="${RO_TRACE:-$KEY_TRACE/ro}"
    RW_TRACE="${RW_TRACE:-$KEY_TRACE/rw}"
fi
# Config. The stock eval scripts all sed -i config/a.yaml in place, which permanently
# edits a checked-in file that eval1..eval8 share. Generate our own instead, so a hashmap
# run never leaves a.yaml modified.
#   MOUNT_DIR  redirect target for any open() captured by libmegalon's glibc interposer
#              (lib/glibc/open.cc defines a C-linkage open(), so it interposes
#              process-wide). Must be a real path. The extra excluded_directories entries
#              below keep the traces, the results and the repo out of that path: in a KV
#              build rackobj_open() starts with CHECK(SLOT_SIZE == 4096) and aborts.
#   NCR_SIZE   non-coherent region on NUMA_MEM: must hold slots * SLOT_SIZE (1KB for the
#              KV build) plus per-slot metadata. Shrink NUM_OBJS if your CXL device is
#              smaller than NCR_SIZE + SCR_SIZE.
#   LOCAL_SIZE allocated on EVERY exec NUMA node (NUM_NUMA-1 of them), so the DRAM cost is
#              LOCAL_SIZE * (NUM_NUMA-1), plus GRAPH_ENTRIES*8KB per logical node.
MOUNT_DIR="${MOUNT_DIR:-${RACKOBJ_RESULT_DIR:-/tmp/}}"
NCR_SIZE="${NCR_SIZE:-2GB}"
SCR_SIZE="${SCR_SIZE:-2GB}"
LOCAL_SIZE="${LOCAL_SIZE:-8GB}"
CONFIG_FILE="${CONFIG_FILE:-config/hashmap.generated.yaml}"
LOG_ROOT=${PROJECT_ROOT}/logs/hashmap
RESULT_ROOT=${RACKOBJ_RESULT_DIR}hashmap

# Uncore frequency control.
#   slow (default) - emulate CXL by dropping the NUMA_MEM package to $SLOW_FREQ_KHZ, as
#                    the artifact's own eval scripts do. Use on a DRAM-only machine.
#   pin            - no slowdown, but pin every package to $FAST_FREQ_KHZ so exec-side
#                    turbo does not add run-to-run variance. Use when NUMA_MEM is real
#                    CXL memory: the latency is already there, no emulation needed.
#   off            - touch nothing.
# Latency sampling. Each thread writes one line per measured operation; at 32 threads over
# a 30 s window that is gigabytes of text. Record 1 sample in N instead - percentiles are
# unaffected by uniform subsampling, and throughput comes from the op count, not the sample
# count. Set to 1 for every sample.
LATENCY_SAMPLE_EVERY="${LATENCY_SAMPLE_EVERY:-100}"

UNCORE_MODE="${UNCORE_MODE:-slow}"
SLOW_FREQ_KHZ="${SLOW_FREQ_KHZ:-800000}"
FAST_FREQ_KHZ="${FAST_FREQ_KHZ:-2400000}"

uncore_bench() {   # frequency setting for the measured run
    case "$UNCORE_MODE" in
        slow) ./scripts/set_uncore_frequency.sh "$SLOW_FREQ_KHZ" > /dev/null 2>&1 ;;
        pin)  ./scripts/set_uncore_frequency.sh "$FAST_FREQ_KHZ" > /dev/null 2>&1 ;;
        off)  : ;;
        *)    echo "unknown UNCORE_MODE=$UNCORE_MODE (slow|pin|off)"; exit 1 ;;
    esac
}
uncore_reset() {   # back to the firmware defaults
    [ "$UNCORE_MODE" = "off" ] || ./scripts/set_uncore_frequency.sh > /dev/null 2>&1
}

if [ "$UNCORE_MODE" != "off" ] && ! lsmod | grep -q intel_uncore_frequency; then
    echo "Uncore frequency driver not loaded (sudo modprobe intel_uncore_frequency),"
    echo "or set UNCORE_MODE=off if this machine has real CXL memory and you do not"
    echo "want the frequency pinned."
    exit 1
fi
# A readable directory says nothing about the files inside it, so check each trace that
# will actually be passed to a benchmark. Done before the build, so a missing trace costs
# a second rather than a build plus an 18M-object load phase.
for t in "$RO_TRACE" "$RW_TRACE"; do
    [ "$t" = "builtin" ] && continue
    if [ -d "$t" ]; then
        echo "Key trace is a directory, not a file: $t"
        echo "KEY_TRACE should name a directory containing the files ro and rw."
        exit 1
    fi
    if [ ! -r "$t" ]; then
        echo "Key trace not readable: $t"
        echo "Expected \$KEY_TRACE/ro and \$KEY_TRACE/rw under $(pwd)/${KEY_TRACE#./},"
        echo "or set RO_TRACE / RW_TRACE explicitly, or KEY_TRACE=builtin to use MEGALON's"
        echo "zipfian generator instead."
        exit 1
    fi
    [ -s "$t" ] || { echo "Key trace is empty: $t"; exit 1; }
done

# With a single exec node (NUM_NUMA=2), every worker thread pins to that one node. Running
# more threads than it has CPUs oversubscribes and inflates latency, which looks like a
# result rather than a configuration mistake.
check_thread_capacity() {
    local numa_mem num_numa cand exec_cpus=0 n cpus
    numa_mem=$(grep -E '^#define[[:space:]]+NUMA_MEM' src/common/constants.h | awk '{print $3}')
    num_numa=$(grep -E '^#define[[:space:]]+NUM_NUMA' src/common/constants.h | awk '{print $3}')
    cand=0
    local listed=0
    while [ "$listed" -lt "$((num_numa - 1))" ] && [ "$cand" -lt 64 ]; do
        if [ "$cand" != "$numa_mem" ]; then
            cpus=$(cat "/sys/devices/system/node/node${cand}/cpulist" 2>/dev/null)
            n=$(echo "$cpus" | awk -F, '{t=0; for(i=1;i<=NF;i++){split($i,r,"-"); t += (r[2]=="")?1:(r[2]-r[1]+1)} print t}')
            exec_cpus=$((exec_cpus + n))
            listed=$((listed + 1))
        fi
        cand=$((cand + 1))
    done
    echo "  exec CPUs available: ${exec_cpus}"
    for t in "${THREAD_COUNTS[@]}"; do
        if [ "$t" -gt "$exec_cpus" ] 2>/dev/null; then
            echo "  WARNING: THREAD_COUNTS includes ${t}, above the ${exec_cpus} exec CPUs."
            echo "           Threads will time-share; latency numbers will reflect that."
        fi
    done
}

report_result_budget() {
    local avail_kb per_thread_est
    avail_kb=$(df -Pk "$RACKOBJ_RESULT_DIR" | awk 'NR==2 {print $4}')
    echo "  latency sampling: 1 in ${LATENCY_SAMPLE_EVERY}"
    echo "  free on result volume: $((avail_kb / 1024)) MiB"
    if [ "$avail_kb" -lt 2097152 ]; then
        echo "  WARNING: under 2 GiB free. Raise LATENCY_SAMPLE_EVERY or free space first."
    fi
}

if [ -z "$RACKOBJ_RESULT_DIR" ]; then
    echo "Error: RACKOBJ_RESULT_DIR is not set or is empty."
    echo "Run ./scripts/setup_lean.sh, then open a new shell (or export it by hand)."
    exit 1
fi
# Being set is not enough: scripts/setup.sh hardcodes /mydata/\$USER/..., so a stale export
# in ~/.bashrc points here at a directory that may not exist or may not be writable.
# Fail now with the path in hand, rather than several mkdir errors deep.
case "$RACKOBJ_RESULT_DIR" in
    */) ;;
    *)  echo "Error: RACKOBJ_RESULT_DIR must end with '/' (scripts concatenate:"
        echo "       \${RACKOBJ_RESULT_DIR}hashmap). Currently: $RACKOBJ_RESULT_DIR"
        exit 1 ;;
esac
if ! mkdir -p "$RACKOBJ_RESULT_DIR" 2>/dev/null; then
    echo "Error: cannot create RACKOBJ_RESULT_DIR=$RACKOBJ_RESULT_DIR"
    echo "  This is usually a stale export from the original scripts/setup.sh, which"
    echo "  hardcodes /mydata/\$USER/... Check with:  grep RACKOBJ_RESULT_DIR ~/.bashrc"
    echo "  Fix by re-running ./scripts/setup_lean.sh (it rewrites the export), or:"
    echo "      export RACKOBJ_RESULT_DIR=\$HOME/rackobj-benchmarks/benchmarks/results/"
    exit 1
fi
if [ ! -w "$RACKOBJ_RESULT_DIR" ]; then
    echo "Error: RACKOBJ_RESULT_DIR=$RACKOBJ_RESULT_DIR exists but is not writable."
    exit 1
fi

write_config() {   # write_config <key_space> <slots> <logical_scr_size>
    cat > "${CONFIG_FILE}" <<YAML
mount_directory: ${MOUNT_DIR}
key_space: $1
slots: $2
scr_size: ${SCR_SIZE}
logical_scr_size: $3
ncr_size: ${NCR_SIZE}
local_size: ${LOCAL_SIZE}
replicate: false
flush: false
evict: false
excluded_files:
partition_ratio: 0.0
excluded_directories:
  - /usr
  - /proc
  - /etc
  - /dev
  - /sys
  - /tmp
  - /home
  - ${PROJECT_ROOT}
  - ${RACKOBJ_RESULT_DIR}
YAML
}

to_bytes() {   # "36GB" -> bytes
    case "$1" in
        *GB|*gb) echo $(( ${1%%[Gg]*} * 1024 * 1024 * 1024 )) ;;
        *MB|*mb) echo $(( ${1%%[Mm]*} * 1024 * 1024 )) ;;
        *) echo "$1" ;;
    esac
}

# Everything below lives on NUMA_MEM, i.e. on the CXL device:
#   object data     slots * SLOT_SIZE          (1024 B, the KV build)
#   CacheNode meta  slots * 64                 (48 B rounded to a cache line, in the NCR)
#   GCD directory   slots * 112 per replica    (GCDEntry with LOGICAL_NODE_NUM=3),
#                                              node-replicated across NUM_NUMA
#   SCR             SCR_SIZE
# CXL_CAPACITY is only used to warn; set it to your device size.
CXL_CAPACITY="${CXL_CAPACITY:-16GB}"
NUM_NUMA_HINT="${NUM_NUMA_HINT:-4}"

check_capacity() {   # check_capacity <slots>
    local slots="$1" data meta gcd ncr_have total cap
    data=$(( slots * 1024 ))
    meta=$(( slots * 64 ))
    gcd=$(( slots * 112 * NUM_NUMA_HINT ))
    ncr_have=$(to_bytes "${NCR_SIZE}")
    cap=$(to_bytes "${CXL_CAPACITY}")
    total=$(( ncr_have + $(to_bytes "${SCR_SIZE}") + gcd ))

    if [ $(( data + meta )) -gt "$ncr_have" ]; then
        echo "NCR_SIZE=${NCR_SIZE} cannot hold ${slots} slots:"
        echo "  object data $(( data / 1024 / 1024 )) MiB + CacheNode metadata $(( meta / 1024 / 1024 )) MiB"
        echo "Raise NCR_SIZE or lower NUM_OBJS."
        exit 1
    fi
    echo "footprint on NUMA_MEM (the CXL device):"
    echo "  object data      $(( data / 1024 / 1024 )) MiB   <- comparable to the original's 1024 MiB table"
    echo "  CacheNode meta   $(( meta / 1024 / 1024 )) MiB"
    echo "  GCD (x${NUM_NUMA_HINT} replicas) $(( gcd / 1024 / 1024 )) MiB"
    echo "  NCR reserved     ${NCR_SIZE}, SCR reserved ${SCR_SIZE}"
    echo "  total reserved   $(( total / 1024 / 1024 )) MiB of ${CXL_CAPACITY}"
    if [ "$total" -gt "$cap" ]; then
        echo "WARNING: reserved regions exceed CXL_CAPACITY=${CXL_CAPACITY}; expect allocation failure."
    fi
    echo "  ${LOCAL_SIZE} local DRAM per exec NUMA node, mount_directory=${MOUNT_DIR}"
    check_thread_capacity
    report_result_budget
    if [ "${GRAPH_ENTRIES}" -gt 0 ] 2>/dev/null; then
        ln_num=$(grep -E '^#define[[:space:]]+LOGICAL_NODE_NUM' src/common/constants.h | awk '{print $3}')
        echo "  graph arrays: ${GRAPH_ENTRIES} entries x 8KB x ${ln_num} logical nodes ="
        echo "                $(( GRAPH_ENTRIES * 8 * ln_num / 1024 )) MiB of DRAM, spread over the exec nodes"
    else
        echo "  graph traversal disabled (GRAPH_ENTRIES=0)"
    fi
}

for variant in "${VARIANTS[@]}"; do
    rm -rf "${LOG_ROOT}/${variant}"; mkdir -p "${LOG_ROOT}/${variant}"
    rm -rf "${RESULT_ROOT}/${variant}"; mkdir -p "${RESULT_ROOT}/${variant}"
    cp "cmake-variant/CMakeLists_${variant}.txt" CMakeLists.txt

    # Lean build: only megalon + the two hashmap binaries, and only the NR variant that
    # is actually linked. Use ./scripts/build.sh instead if you want the full tree.
    BUILD_SCRIPT="${BUILD_SCRIPT:-./scripts/build_lean.sh}"
    $BUILD_SCRIPT > "${LOG_ROOT}/${variant}/build_errors.log" 2>&1 || { echo "build failed, see ${LOG_ROOT}/${variant}/build_errors.log"; exit 1; }

    for scr_size in "${SCR_SIZES[@]}"; do
        for num_obj in "${NUM_OBJS[@]}"; do
            check_capacity $((num_obj + 1000))
            write_config "${num_obj}" "$((num_obj + 1000))" "${scr_size}MB"

            for zipf in "${ZIPFS[@]}"; do
                # ---------------- read-only ----------------
                src_dir="${RACKOBJ_RESULT_DIR}hashmap-ro/${zipf}"
                dst_dir="${RESULT_ROOT}/${variant}/ro-${num_obj}-${zipf}-${scr_size}MB"
                sudo rm -rf "$src_dir"; mkdir -p "$src_dir"

                uncore_bench
                for num_threads in "${THREAD_COUNTS[@]}"; do
                    sudo RACKOBJ_CONFIG=${CONFIG_FILE} LATENCY_SAMPLE_EVERY=${LATENCY_SAMPLE_EVERY} \
                        ./build/benchmarks/hashmap-ro \
                        "$RACKOBJ_RESULT_DIR" "$num_threads" "$zipf" $PREHEAT_TIME $EXEC_TIME 0 $GRAPH_ENTRIES "$RO_TRACE" \
                        >> "${LOG_ROOT}/${variant}/output_ro_${zipf}_${scr_size}MB.log" 2>&1
                done
                uncore_reset
                # src_dir and dst_dir are both under RACKOBJ_RESULT_DIR: copying doubled the space.
                [ -d "$src_dir" ] && { mkdir -p "$(dirname "$dst_dir")"; mv "$src_dir" "$dst_dir"; }

                # ---------------- read-write ----------------
                for w_ratio in "${W_RATIOS[@]}"; do
                    src_dir="${RACKOBJ_RESULT_DIR}hashmap-rw-${w_ratio}/${zipf}"
                    dst_dir="${RESULT_ROOT}/${variant}/rw-${w_ratio}-${num_obj}-${zipf}-${scr_size}MB"
                    sudo rm -rf "$src_dir"; mkdir -p "$src_dir"

                    uncore_bench
                    for num_threads in "${THREAD_COUNTS[@]}"; do
                        sudo RACKOBJ_CONFIG=${CONFIG_FILE} LATENCY_SAMPLE_EVERY=${LATENCY_SAMPLE_EVERY} \
                            ./build/benchmarks/hashmap-rw \
                            "$RACKOBJ_RESULT_DIR" "$num_threads" "$w_ratio" "$zipf" $PREHEAT_TIME $EXEC_TIME 0 $GRAPH_ENTRIES "$RW_TRACE" \
                            >> "${LOG_ROOT}/${variant}/output_rw_${w_ratio}_${zipf}_${scr_size}MB.log" 2>&1
                    done
                    uncore_reset
                    # src_dir and dst_dir are both under RACKOBJ_RESULT_DIR: copying doubled the space.
                [ -d "$src_dir" ] && { mkdir -p "$(dirname "$dst_dir")"; mv "$src_dir" "$dst_dir"; }
                done
            done
        done
    done
done

echo "Analyzing..."
cd benchmarks/script
for variant in "${VARIANTS[@]}"; do
    for d in "${RESULT_ROOT}/${variant}"/*; do
        echo "=== $(basename "$d") ===" >> "${LOG_ROOT}/${variant}/stat.log"
        python3 avg_lat.py "$d" rwtf >> "${LOG_ROOT}/${variant}/stat.log"
    done
done
cd "${PROJECT_ROOT}"

cp cmake-variant/CMakeLists_megalon.txt CMakeLists.txt
echo "Config used: ${CONFIG_FILE} (config/a.yaml left untouched)"
echo "Done. Throughput in ${LOG_ROOT}, latency stats in ${LOG_ROOT}/*/stat.log"
