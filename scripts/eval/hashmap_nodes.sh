#!/usr/bin/env bash
NODES=($(seq 8))
THREADS_PER_NODE="${THREADS_PER_NODE:-4}"
cd "$(dirname "$0")/../.."
PROJECT_ROOT="$(pwd)"
LOG_ROOT=${PROJECT_ROOT}/logs/hashmap

NUMA_MEM=$(grep -E '^#define[[:space:]]+NUMA_MEM' src/common/constants.h | awk '{print $3}')
# we want execute all threads on one NUMA node
if [[ "$EXEC_ON_MEM" -eq 1 ]]; then
    NUMA_NODES=1
else
    NUMA_NODES=2
fi

if [ -d "${LOG_ROOT}/megalon_nodes" ]; then
  rm -r "${LOG_ROOT}/megalon_nodes"
fi
mkdir -p "${LOG_ROOT}/megalon_nodes"
  
for n in ${NODES[@]}; do
    threads=$(( n * THREADS_PER_NODE ))
    ./scripts/setup_logical_node.sh ${NUMA_MEM} ${n} 24 ${NUMA_NODES}
    THREAD_COUNTS="$threads" TRIALS=1 ./scripts/eval/hashmap.sh
    for d in ${LOG_ROOT}/megalon/output_*; do
        target=${LOG_ROOT}/megalon_nodes/time_${d##*output_}
        if (( n == NODES[0] )); then
            echo "Node Count,Average,Standard Deviation" > ${target}
        fi
        time=$(python3 benchmarks/script/hashmap_time.py "$d")
        echo "${n},${time}" >> ${target}
    done
done
 
