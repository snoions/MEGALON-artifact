#!/usr/bin/env bash

if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
    echo "Usage: $0 <NUMA_MEM> <LOGICAL_NODE_NUM> <KEY_SIZE> [NUMA_NODES]"
    echo "  <NUMA_MEM>: The NUMA memory node id (e.g. 0)"
    echo "  <LOGICAL_NODE_NUM>: Number of logical nodes/replicas (e.g. 9)"
    echo "  <KEY_SIZE>: Key size in bytes (e.g. 12 or 24)"
    echo "  [NUMA_NODES]: Number of NUMA nodes to use, excluding headless memory nodes. (e.g. 3)"
    echo "  EXEC_ON_MEM=1 (environment): NUMA_MEM may also be an execution node, with no CXL"
    echo "      emulation; [NUMA_NODES] is then the number of execution nodes (default 1),"
    echo "      nodes 0 .. NUMA_NODES-1. See EXEC_ON_MEM in src/common/constants.h."
    exit 1
fi

# jump to the current directory
CUR_DIR="$(dirname "$0")"
cd $CUR_DIR
CUR_DIR="$(pwd)"

NUMA_MEM=$1
LOGICAL_NODE_NUM=$2
KEY_SIZE=$3
NUMA_NODES=$4
constants_file="../src/common/constants.h"
rust_constants_file="../third-party/nr_rust/ffi/constants.rs"
common_file="../benchmarks/common.h"

get_numa_nodes() {
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | awk -F: '/NUMA node\(s\)/ {gsub(/ /,"",$2); print $2}'
    elif [ -d /sys/devices/system/node ]; then
        ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l
    else
        echo 1  # fallback if NUMA info not available
    fi
}

EXEC_ON_MEM="${EXEC_ON_MEM:-0}"
case "$EXEC_ON_MEM" in 0|1) ;; *) echo "EXEC_ON_MEM must be 0 or 1, got '$EXEC_ON_MEM'"; exit 1 ;; esac
if [ "$EXEC_ON_MEM" = 1 ]; then
    numa_nodes=${NUMA_NODES:-1}
    [ "$numa_nodes" -le "$(get_numa_nodes)" ] || { echo "only $(get_numa_nodes) NUMA node(s), asked for $numa_nodes"; exit 1; }
else
    numa_nodes=${NUMA_NODES:-$(get_numa_nodes)}
fi
# Sanity check: require at least 2 NUMA nodes
if [ "$EXEC_ON_MEM" = 0 ] && [ "$numa_nodes" -lt 2 ]; then
    echo "Warning: Detected only $numa_nodes NUMA node(s). At least 2 NUMA nodes are required for proper logical node setup."
    echo "(Or set EXEC_ON_MEM=1 to run on the memory node itself, without CXL emulation.)"
    echo "Aborting setup."
    exit 1
fi

echo "Hardware numa nodes to use: $numa_nodes, set NUMA_MEM=$NUMA_MEM, LOGICAL_NODE_NUM=$LOGICAL_NODE_NUM, KEY_SIZE=$KEY_SIZE"

# Update LOGICAL_NODE_NUM to value of $LOGICAL_NODE_NUM
sed -i "s/^\(#define[ \t]*LOGICAL_NODE_NUM[ \t]*\).*\$/\1$LOGICAL_NODE_NUM  \/\/ this should match the rust library/" "$constants_file"

# Update NUM_NUMA to value of $numa_nodes
sed -i "s/^\(#define[ \t]*NUM_NUMA[ \t]*\).*\$/\1$numa_nodes  \/\/ number of NUMA nodes on the machine (including mem. node)/" "$constants_file"
sed -i "s/^\(#define[ \t]*EXEC_ON_MEM[ \t]*\).*\$/\1$EXEC_ON_MEM/" "$constants_file"

# Update NUMA_MEM to value of $NUMA_MEM
sed -i "s/^\(#define[ \t]*NUMA_MEM[ \t]*\).*\$/\1$NUMA_MEM/" "$constants_file"

# Update LOGICAL_NODE_NUM
sed -i "s/^\(pub const LOGICAL_NODE_NUM: usize = \).*\$/\1$LOGICAL_NODE_NUM;/" "$rust_constants_file"

# Update NUMA_MEM
sed -i "s/^\(pub const NUMA_MEM: u64 = \).*\$/\1$NUMA_MEM;/" "$rust_constants_file"

# NUM_NUMA counts NUMA_MEM too, unless it is itself an execution node (EXEC_ON_MEM)
if [ "$EXEC_ON_MEM" = 1 ]; then num_exec=$numa_nodes; rust_exec_on_mem=true; else num_exec=$((numa_nodes - 1)); rust_exec_on_mem=false; fi
sed -i "s/^\(pub const EXEC_ON_MEM: bool = \).*\$/\1$rust_exec_on_mem;/" "$rust_constants_file"
sed -i "s/^\(pub const NUM_EXEC: usize = \).*\$/\1$num_exec;/" "$rust_constants_file"

# Update KEY_SIZE in C++ constants.h
sed -i "s/^\(#define[ \t]*KEY_SIZE[ \t]*\).*\$/\1$KEY_SIZE/" "$constants_file"

# Update KEY_SIZE in Rust constants.rs
sed -i "s/^\(pub const KEY_SIZE: usize = \).*\$/\1$KEY_SIZE;/" "$rust_constants_file"

CPU_GHZ=$(awk -F: '/cpu MHz/ { sum += $2; count++ } END { if(count>0) print int((sum/count + 50)/100)*100 / 1000 }' /proc/cpuinfo)

sed -i "s/^#define CPU_FREQ_GHZ .*/#define CPU_FREQ_GHZ $CPU_GHZ/" "$common_file"
echo "CPU frequency detected: $CPU_GHZ GHz, updated in $common_file"
