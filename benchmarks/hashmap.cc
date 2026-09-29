// hashmap.cc
//
// MEGALON port of the two RACoherence hashmap benchmarks, `hashmap.cpp` (read-only) and
// `hashmap_rw.cpp` (90/10 read/write), as one binary selected by <write ratio>:
//
//   write ratio 0.0  ->  hashmap.cpp:    lookups only, no RNG draw per op, no write path
//   write ratio 0.1  ->  hashmap_rw.cpp: 1 in 10 ops is a write (`dist(gen) % 10 == 9`)
//
// The two originals differed only in that fraction; everything else - table, key trace,
// graph traversal, measurement - was shared, and so is it here.
//
// Writes are aimed at a different key than reads (`target_key + ENTRIES_PER_LOCK` in the
// original) because, per TAOBench, read and write hotspots usually do not coincide.
//
// Locking. The original guarded the table with an array of 131,072 `CXLSharedMutex`, one
// per 1024-bucket stripe: readers took `lock_shared()`, writers `lock()`. Those locks only
// kept a reader from observing a torn 8-byte entry - `map_put` is a blind overwrite, not a
// read-modify-write, so writers need no mutual exclusion from each other. MEGALON gives
// exactly that guarantee at object granularity: a `rackobj::Put` of a whole object is atomic
// with respect to concurrent `rackobj::Get`s. With one bucket per object the lock array
// disappears, and with it the contention between the 1023 unrelated buckets that shared
// each stripe's lock.
//
// Caveat: packing several buckets into one object would turn a write into a
// read-modify-write of the object, and updates to different buckets in the same object
// could be lost. That needs an application-level lock, which MEGALON's public API does not
// provide. Keep one bucket per object.
//
// Usage:
//   hashmap <result dir> <thread cnt> <write ratio> <zipfian theta>
//           [keys per thread] [graph entries per node] [key trace file]
//
// Measurement, as in the originals: each thread makes `iterations` passes over its own
// slice of the trace - keys_per_thread = trace size / threads, iterations = 10 at write
// ratio 0 (hashmap.cpp) and 1 otherwise (hashmap_rw.cpp) - and the program reports
// "Thread Average time" and "Elapsed time". HASHMAP_ITERATIONS overrides the pass count.
//
// The key trace defaults to ./zipf.txt, as in the originals. Pass "builtin" as the last
// argument to use MEGALON's own zipfian generator instead.

#include <numa.h>
#include <rackobj.h>

#include <chrono>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "absl/log/check.h"
#include "absl/log/globals.h"
#include "absl/log/initialize.h"
#include "absl/log/log.h"
#include "common.h"
#include "hashmap_common.h"

using namespace hashmap_bench;
using std::string;
using std::to_string;
using std::vector;

namespace {

constexpr size_t kLoaderThreads = 18;
constexpr int kTraversalPeriod = 32;

// Work definition, from the originals. Both read a 200M-key trace split evenly across
// threads (ELEMENT_NUM_TOTAL / POPULATE_PER_THREAD); they differ only in how many passes
// each thread makes over its slice (NUM_ITERATIONS): 10 in hashmap.cpp, 1 in hashmap_rw.cpp.
constexpr uint64_t kOriginalTotalKeys = 200'000'000ull;
constexpr uint32_t kIterationsReadOnly = 10;  // hashmap.cpp
constexpr uint32_t kIterationsReadWrite = 1;  // hashmap_rw.cpp

struct Options {
    string result_dir;
    size_t thread_cnt = 0;
    double write_ratio = 0.0;  // 0.0 = hashmap.cpp, 0.1 = hashmap_rw.cpp
    double theta = 0.99;
    uint64_t keys_per_thread = 0;  // 0 = trace size / threads, as the originals
    uint32_t iterations = 0;       // 10 at write ratio 0, else 1, as the originals
    uint32_t graph_entries_per_node = 0;
    string zipf_trace;
};

struct WorkerResult {
    uint64_t reads = 0;
    uint64_t writes = 0;
    double elapsed_s = 0.0;
    CoherenceStats coherence;
};

void Worker(size_t thread_idx, const Options& opt, size_t num_buckets, const GraphArrays& graphs,
            const vector<int32_t>* trace, WorkerResult* result, ThreadBarrier* barrier) {
    rackobj::Register(static_cast<int>(thread_idx));
    const int rid = static_cast<int>(rackobj::GetConfigSize_t("logical_nid"));

    auto buf = std::make_unique<uint8_t[]>(kAccessSize);
    std::memset(buf.get(), 0, kAccessSize);
    auto visited = std::make_unique<uint8_t[]>(kGraphNodesPerEntry);

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint32_t> dist(0, UINT32_MAX);
    std::uniform_real_distribution<double> rw_dist(0.0, 1.0);
    const bool all_writes = opt.write_ratio >= 1.0;
    const bool mixed_workload = opt.write_ratio > 0.0 && !all_writes;

    // This thread's slice, as zipf[keys_per_thread * id + i] in the originals.
    KeySource keys(trace, num_buckets, opt.theta, opt.keys_per_thread * thread_idx, opt.keys_per_thread);
    const uint64_t total_work = opt.keys_per_thread * opt.iterations;

    const bool traverse = opt.graph_entries_per_node > 0;
    const ArrayEntry* graph = traverse ? graphs.Node(rid) : nullptr;

    // As hashmap_rw.cpp: all threads start together, then each times its own work.
    barrier->Wait();

    const auto start = std::chrono::high_resolution_clock::now();
    const CoherenceStats coherence_base = CoherenceStats::Sample();

    for (uint64_t i = 0; i < total_work; i++) {
        const int32_t key = keys.Next();
        // Only draw when the mix is genuinely mixed: at 0.0 this is then exactly the
        // read-only benchmark (no per-op RNG on the hot loop), and at 1.0 all-writes.
        const bool is_write = mixed_workload ? (rw_dist(gen) < opt.write_ratio) : all_writes;

        if (is_write) {
            // Read and write hotspots are deliberately offset, as in the original.
            MapPut(buf.get(), key + kWriteKeyShift, 1, num_buckets);
        } else {
            const int32_t val = MapGet(buf.get(), key, num_buckets);
            __asm__ __volatile__("" : : "r"(val) : "memory");
        }

        if (is_write)
            result->writes++;
        else
            result->reads++;

        if (traverse && (i % kTraversalPeriod == 0)) {
            GraphTraversal(graph, graphs.EntriesPerNode(), dist(gen), visited.get());
        }
    }

    const auto end = std::chrono::high_resolution_clock::now();
    result->coherence = CoherenceStats::Sample() - coherence_base;
    result->elapsed_s = std::chrono::duration<double>(end - start).count();

    if (!opt.result_dir.empty()) {
        const string dir = opt.result_dir + "/" + to_string(opt.thread_cnt);
        // Operation count and elapsed time, the per-thread figures avg_lat.py's "t" mode sums
        // into throughput. The originals record no per-operation latency, and neither does
        // this port.
        std::ofstream f(dir + "/throughput-" + to_string(thread_idx));
        if (f.is_open()) f << (result->reads + result->writes) << "\n" << result->elapsed_s << "\n";
    }

    barrier->Wait();
    rackobj::UnRegister();
}

}  // namespace

int main(int argc, char** argv) {
    absl::SetStderrThreshold(absl::LogSeverity::kInfo);
    absl::InitializeLog();

    if (argc < 5 || argc > 8) {
        std::cerr << "Usage: " << argv[0]
                  << " <result dir> <thread cnt> <write ratio> <zipfian theta>"
                     " [keys per thread] [graph entries per node] [key trace file]\n";
        return 1;
    }

    numa_set_strict(1);

    Options opt;
    opt.result_dir = argv[1];
    opt.thread_cnt = std::stoull(argv[2]);
    opt.write_ratio = std::stod(argv[3]);
    if (opt.write_ratio < 0.0 || opt.write_ratio > 1.0) {
        std::cerr << "write ratio must be in [0, 1], got " << opt.write_ratio << "\n";
        return 1;
    }
    opt.theta = std::stod(argv[4]);
    // Keys per thread: 0 (the default) derives it as the originals do, trace size / threads.
    opt.keys_per_thread = (argc > 5) ? std::stoull(argv[5]) : 0;
    // Passes over each thread's slice: 10 for the read-only original, 1 for the read-write
    // one. HASHMAP_ITERATIONS overrides.
    opt.iterations = (opt.write_ratio == 0.0) ? kIterationsReadOnly : kIterationsReadWrite;
    if (const char* env = getenv("HASHMAP_ITERATIONS")) opt.iterations = static_cast<uint32_t>(std::stoul(env));
    opt.graph_entries_per_node =
        (argc > 6) ? static_cast<uint32_t>(std::stoul(argv[6])) : kNumArrayEntriesTotal / LOGICAL_NODE_NUM;
    opt.zipf_trace = (argc > 7) ? argv[7] : kDefaultZipfTrace;

    const size_t num_buckets = rackobj::GetConfigSize_t("key_space");

    LOG(INFO) << "hashmap: threads=" << opt.thread_cnt << " buckets=" << num_buckets << " slot=" << SLOT_SIZE
              << "B access=" << kAccessSize << "B write_ratio=" << opt.write_ratio << " theta=" << opt.theta
              << " graph_entries_per_node=" << opt.graph_entries_per_node
              << " keys=" << (IsBuiltinKeySource(opt.zipf_trace) ? "builtin-zipfian" : opt.zipf_trace);

    if (!opt.result_dir.empty()) {
        opt.result_dir += "hashmap-" + double_to_string(opt.write_ratio) + "/" + double_to_string(opt.theta);
        MakeDirs(opt.result_dir + "/" + to_string(opt.thread_cnt));
        LOG(INFO) << "RESULT DIR " << opt.result_dir;
    }

    // ZIPF_MAX_KEYS caps how much of the trace is read into memory (0 = all). The
    // original allocated 200M int32 = 800 MB up front; a cap keeps that in check.
    size_t max_trace_keys = 0;
    if (const char* env = getenv("ZIPF_MAX_KEYS")) max_trace_keys = std::stoull(env);
    vector<int32_t> trace = ResolveKeyTrace(opt.zipf_trace, num_buckets, max_trace_keys);

    // elements_per_thread / keys_per_thread in the originals: the trace split evenly. With
    // the built-in generator there is no trace, so use the originals' 200M total.
    const uint64_t available = trace.empty() ? kOriginalTotalKeys : trace.size();
    if (opt.keys_per_thread == 0) opt.keys_per_thread = available / opt.thread_cnt;
    CHECK(opt.keys_per_thread > 0) << "no keys per thread";
    if (!trace.empty() && opt.keys_per_thread * opt.thread_cnt > trace.size()) {
        LOG(FATAL) << opt.keys_per_thread << " keys x " << opt.thread_cnt << " threads exceeds the trace ("
                   << trace.size() << " keys); slices would overlap";
    }
    LOG(INFO) << "keys_per_thread: " << opt.keys_per_thread << ", iterations: " << opt.iterations;

    GraphArrays graphs;
    if (opt.graph_entries_per_node > 0) InitGraphArrays(&graphs, opt.graph_entries_per_node);

    // Read-only runs load objects without write metadata, so reads skip the seqlock checks;
    // see LoadBuckets.
    LoadBuckets(num_buckets, kLoaderThreads, /*read_only=*/opt.write_ratio == 0.0);

    vector<WorkerResult> results(opt.thread_cnt);
    ThreadBarrier barrier(opt.thread_cnt);

    // "Elapsed time" in the originals: from before spawning the threads to after joining them.
    const auto run_start = std::chrono::steady_clock::now();
    vector<std::jthread> workers(opt.thread_cnt);
    for (size_t i = 0; i < opt.thread_cnt; ++i) {
        workers[i] = std::jthread(
            [&, i] { Worker(i, opt, num_buckets, graphs, trace.empty() ? nullptr : &trace, &results[i], &barrier); });
    }
    for (auto& t : workers)
        if (t.joinable()) t.join();
    const double elapsed_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - run_start).count();

    double avg_elapsed = 0.0;
    uint64_t reads = 0, writes = 0;
    for (const auto& r : results) {
        avg_elapsed += r.elapsed_s;
        reads += r.reads;
        writes += r.writes;
    }
    avg_elapsed /= static_cast<double>(opt.thread_cnt);
    CoherenceStats coherence;
    for (const auto& r : results) coherence += r.coherence;
    LogCoherenceStats(coherence, reads + writes);
    LOG(INFO) << "Thread Average time: " << avg_elapsed << " seconds";
    LOG(INFO) << "Elapsed time: " << elapsed_s << " seconds";
    LOG(INFO) << "Total ops: " << (reads + writes) << " (reads=" << reads << ", writes=" << writes << ")";
    if (avg_elapsed > 0.0)
        LOG(INFO) << "Aggregate throughput: " << static_cast<uint64_t>((reads + writes) / avg_elapsed) << " ops/s";

    graphs.Free();
    return 0;
}
