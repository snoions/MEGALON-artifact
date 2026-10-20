#!/usr/bin/env bash
NODES=($(seq 8))
THREADS_PER_NODE="${THREADS_PER_NODE:-4}"
cd "$(dirname "$0")/../.."
PROJECT_ROOT="$(pwd)"
LOG_ROOT=${PROJECT_ROOT}/logs/hashmap

if [ -d "${LOG_ROOT}/megalon_nodes" ]; then
  rm -r "${LOG_ROOT}/megalon_nodes"
fi
mkdir -p "${LOG_ROOT}/megalon_nodes"
  
for n in ${NODES[@]}; do
    threads=$(( n * THREADS_PER_NODE ))
    # NUM_NUMA is 2 because we want to emulate all logical on the same NUMA node
    ./scripts/setup_logical_node.sh 2 ${n} 24 2
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
 
