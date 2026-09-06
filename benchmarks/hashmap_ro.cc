// hashmap_ro.cc
//
// MEGALON port of the RACoherence benchmark `hashmap.cpp`.
//
// Original workload: N processes x THREADS_PER_PROCESS threads issue read-only lookups
// against a 128M-entry hash table living in coherent CXL memory, with a zipfian key
// distribution read from zipf.txt, and a 128-hop pointer chase over a node-local 8KB
// array every 32 lookups.
//
// What changed, and why:
//   rac_init / rac_shutdown / CXLRoot   -> nothing.  MEGALON initializes itself from
//                                         $RACKOBJ_CONFIG when the library loads.
//   cxlnhc_cl_aligned_malloc(table)     -> the table becomes `key_space` MEGALON objects;
//                                         a bucket id is the object key.
//   memset(table, 7, ...)               -> an explicit load phase (LoadBuckets), because a
//                                         MEGALON object must be Put before it is Get.
//   map_get(map, key)                   -> rackobj::Get(buf, kAccessSize, bucket) + key
//                                         compare (see hashmap_common.h).
//   RAC_SERVER_IDX / rac_thread_create  -> a single process; rackobj::Register(tid) binds
//   / CXLBarrier                           thread tid to logical node tid % LOGICAL_NODE_NUM.
//   malloc(array_entries) per process   -> numa_alloc_onnode, one array per logical node.
//
// Usage:
//   hashmap-ro <result_dir> <thread_cnt> <zipf_theta> <preheat_s> <exec_s>
//              [ops_per_thread] [graph_entries_per_node] [zipf_trace_file]
//
// The key trace defaults to ./zipf.txt, as in the original benchmark. Pass "builtin" as
// the last argument to use MEGALON's own zipfian generator (in which case <zipf_theta>
// is what sets the skew; with a trace, the skew is whatever the trace has).
//
// If <exec_s> is 0 the benchmark runs a fixed [ops_per_thread] operations per thread and
// reports elapsed time, mirroring the original.  Otherwise it uses the preheat/measure/
// cooldown window of kv_store.cc, and writes latency/throughput files that
// benchmarks/script/avg_lat.py understands.

#include <numa.h>
#include <rackobj.h>
#include <x86intrin.h>

#include <chrono>
#include <cmath>
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
constexpr int kTraversalPeriod = 32;  // one graph traversal per 32 lookups, as in the original

struct Options {
    string result_dir;
    size_t thread_cnt = 0;
    double theta = 0.99;
    uint32_t preheat_s = 0;
    uint32_t exec_s = 0;
    uint64_t ops_per_thread = 0;
    uint32_t graph_entries_per_node = 0;  // 0 disables the traversal (i.e. #undef GRAPH_TRAVERSAL)
    string zipf_trace;
};

struct WorkerResult {
    uint64_t ops = 0;
    double elapsed_s = 0.0;
    CoherenceStats coherence;  // delta over the measured window
};

void Worker(size_t thread_idx, const Options& opt, size_t num_buckets, const GraphArrays& graphs,
            const vector<int32_t>* trace, TimingControl* control, PaddedCounter* counter, WorkerResult* result,
            ThreadBarrier* barrier) {
    rackobj::Register(static_cast<int>(thread_idx));
    const int rid = static_cast<int>(rackobj::GetConfigSize_t("logical_nid"));

    auto buf = std::make_unique<uint8_t[]>(kAccessSize);
    auto visited = std::make_unique<uint8_t[]>(kGraphNodesPerEntry);

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint32_t> dist(0, UINT32_MAX);

    // Each thread walks a disjoint slice of the trace, as in the original
    // (`zipf[keys_per_thread * id + i]`).
    const size_t trace_slice = (trace != nullptr && !trace->empty()) ? trace->size() / opt.thread_cnt : 0;
    KeySource keys(trace, num_buckets, opt.theta, trace_slice * thread_idx);

    const bool traverse = opt.graph_entries_per_node > 0;
    const ArrayEntry* graph = traverse ? graphs.Node(rid) : nullptr;

    const uint64_t sample_every = LatencySampleEvery();
    vector<int64_t> samples;
    samples.reserve(5'000'000 / sample_every);

    barrier->Wait();

    const bool timed = (opt.exec_s > 0);
    uint64_t local_ops = 0;
    uint64_t total_ops = 0;
    bool warmup_done_local = false;
    bool measure_local = false;
    bool cooldown_local = false;

    const auto start = std::chrono::high_resolution_clock::now();
    CoherenceStats coherence_base = CoherenceStats::Sample();

    for (uint64_t i = 0;; i++) {
        if (timed) {
            if (!warmup_done_local && control->warmup_done.load(std::memory_order_acquire)) warmup_done_local = true;
            if (!measure_local) {
                if (control->measure.load(std::memory_order_acquire)) {
                    measure_local = true;
                    // Counters are cumulative since thread start; rebase so the reported
                    // numbers cover the measured window only, not preheat.
                    coherence_base = CoherenceStats::Sample();
                }
            } else if (!cooldown_local) {
                if (control->cooldown.load(std::memory_order_acquire)) {
                    cooldown_local = true;
                    result->coherence = CoherenceStats::Sample() - coherence_base;
                }
            } else if (control->stop.load(std::memory_order_acquire)) {
                break;
            }
        } else if (i >= opt.ops_per_thread) {
            break;
        }

        const int32_t key = keys.Next();

        uint32_t tsc_aux;
        const uint64_t t1 = __rdtscp(&tsc_aux);
        const int32_t val = MapGet(buf.get(), key, num_buckets);
        const uint64_t t2 = __rdtscp(&tsc_aux);
        __asm__ __volatile__("" : : "r"(val) : "memory");

        total_ops++;
        local_ops++;
        if (local_ops >= kFlushThreshold) {
            counter->ops.fetch_add(local_ops, std::memory_order_relaxed);
            local_ops = 0;
        }

        if (traverse && (i % kTraversalPeriod == 0)) {
            GraphTraversal(graph, graphs.EntriesPerNode(), dist(gen), visited.get());
        }

        const bool keep_sample = (sample_every == 1) || (total_ops % sample_every == 0);
        if (timed) {
            if (!warmup_done_local) continue;
            if (measure_local && !cooldown_local && keep_sample) {
                samples.push_back(cycles_to_nanoseconds(t2 - t1, CPU_FREQ_GHZ));
            }
        } else if (keep_sample) {
            samples.push_back(cycles_to_nanoseconds(t2 - t1, CPU_FREQ_GHZ));
        }
    }

    const auto end = std::chrono::high_resolution_clock::now();
    counter->ops.fetch_add(local_ops, std::memory_order_relaxed);

    result->ops = total_ops;
    if (!timed) result->coherence = CoherenceStats::Sample() - coherence_base;
    result->elapsed_s = std::chrono::duration<double>(end - start).count();

    if (!opt.result_dir.empty()) {
        const string dir = opt.result_dir + "/" + to_string(opt.thread_cnt);
        WriteSamples(samples, dir + "/latencies-" + to_string(thread_idx));

        double duration_s = result->elapsed_s;
        if (timed) {
            const int64_t s = control->measure_start_ns.load(std::memory_order_acquire);
            const int64_t e = control->measure_end_ns.load(std::memory_order_acquire);
            duration_s = (s != -1 && e > s) ? static_cast<double>(e - s) / 1e9 : 0.0;
        }
        std::ofstream f(dir + "/throughput-" + to_string(thread_idx));
        // Operations, not samples: with LATENCY_SAMPLE_EVERY > 1 those differ, and the
        // throughput file must report ops for avg_lat.py to compute the right rate.
        if (f.is_open()) f << result->ops << "\n" << duration_s << "\n";
    }

    barrier->Wait();
    rackobj::UnRegister();
}

}  // namespace

int main(int argc, char** argv) {
    absl::SetStderrThreshold(absl::LogSeverity::kInfo);
    absl::InitializeLog();

    if (argc < 6 || argc > 9) {
        std::cerr << "Usage: " << argv[0]
                  << " <result dir> <thread cnt> <zipfian theta> <preheat time> <exec time>"
                     " [ops per thread] [graph entries per node] [zipf trace file]\n";
        return 1;
    }

    numa_set_strict(1);

    Options opt;
    opt.result_dir = argv[1];
    opt.thread_cnt = std::stoull(argv[2]);
    opt.theta = std::stod(argv[3]);
    opt.preheat_s = static_cast<uint32_t>(std::stoul(argv[4]));
    opt.exec_s = static_cast<uint32_t>(std::stoul(argv[5]));
    opt.ops_per_thread = (argc > 6) ? std::stoull(argv[6]) : 10'000'000ull;
    opt.graph_entries_per_node =
        (argc > 7) ? static_cast<uint32_t>(std::stoul(argv[7])) : kNumArrayEntriesTotal / LOGICAL_NODE_NUM;
    opt.zipf_trace = (argc > 8) ? argv[8] : kDefaultZipfTrace;

    // The table size is driven by the MEGALON config (key_space), not by a compile-time
    // VECTOR_ENTRY_NUM: the object count must match `slots` in the yaml.
    const size_t num_buckets = rackobj::GetConfigSize_t("key_space");

    LOG(INFO) << "hashmap-ro: threads=" << opt.thread_cnt << " buckets=" << num_buckets << " obj_size=" << kAccessSize
              << "B theta=" << opt.theta << " graph_entries_per_node=" << opt.graph_entries_per_node
              << " keys=" << (IsBuiltinKeySource(opt.zipf_trace) ? "builtin-zipfian" : opt.zipf_trace)
              << (opt.exec_s > 0 ? " mode=timed" : " mode=fixed-ops");

    if (!opt.result_dir.empty()) {
        opt.result_dir += "hashmap-ro/" + double_to_string(opt.theta);
        MakeDirs(opt.result_dir + "/" + to_string(opt.thread_cnt));
        LOG(INFO) << "RESULT DIR " << opt.result_dir;
    }

    // ZIPF_MAX_KEYS caps how much of the trace is read into memory (0 = all). The
    // original allocated 200M int32 = 800 MB up front; a cap keeps that in check.
    size_t max_trace_keys = 0;
    if (const char* env = getenv("ZIPF_MAX_KEYS")) max_trace_keys = std::stoull(env);
    vector<int32_t> trace = ResolveKeyTrace(opt.zipf_trace, num_buckets, max_trace_keys);

    GraphArrays graphs;
    if (opt.graph_entries_per_node > 0) InitGraphArrays(&graphs, opt.graph_entries_per_node);

    LoadBuckets(num_buckets, kLoaderThreads);
    sleep(5);

    TimingControl control;
    vector<PaddedCounter> counters(opt.thread_cnt);
    vector<WorkerResult> results(opt.thread_cnt);
    ThreadBarrier barrier(opt.thread_cnt);

    std::jthread controller;
    std::jthread reporter;
    if (opt.exec_s > 0) {
        controller = std::jthread([&] {
            using namespace std::chrono;
            std::this_thread::sleep_for(seconds(opt.preheat_s));
            control.warmup_done.store(true, std::memory_order_release);
            control.measure_start_ns.store(NowNs(), std::memory_order_release);
            control.measure.store(true, std::memory_order_release);
            rackobj::ClearMovementCounter();
            std::this_thread::sleep_for(seconds(opt.exec_s));
            control.measure.store(false);
            control.measure_end_ns.store(NowNs(), std::memory_order_release);
            control.cooldown.store(true, std::memory_order_release);
            std::this_thread::sleep_for(seconds(kCooldownTime));
            control.stop.store(true, std::memory_order_release);
        });

        reporter = std::jthread([&] {
            using namespace std::chrono;
            uint64_t last = 0;
            vector<uint64_t> tputs;
            while (!control.stop.load(std::memory_order_acquire)) {
                std::this_thread::sleep_for(seconds(kReportInterval));
                uint64_t total = 0;
                for (auto& c : counters) total += c.ops.load(std::memory_order_relaxed);
                const uint64_t tput = (total - last) / kReportInterval;
                last = total;
                LOG(INFO) << "GLOBAL THROUGHPUT: " << tput << " ops/s";
                if (control.measure.load(std::memory_order_acquire) &&
                    !control.cooldown.load(std::memory_order_acquire))
                    tputs.push_back(tput);
            }
            if (!tputs.empty()) {
                double sum = 0.0;
                for (auto v : tputs) sum += v;
                const double avg = sum / tputs.size();
                double sq = 0.0;
                for (auto v : tputs) sq += (v - avg) * (v - avg);
                LOG(INFO) << "GLOBAL THROUGHPUT: avg=" << static_cast<uint64_t>(avg)
                          << " ops/s, stddev=" << static_cast<uint64_t>(std::sqrt(sq / tputs.size()))
                          << " ops/s, out of " << tputs.size() << " data points";
            }
        });
    }

    vector<std::jthread> workers(opt.thread_cnt);
    for (size_t i = 0; i < opt.thread_cnt; ++i) {
        workers[i] = std::jthread([&, i] {
            Worker(i, opt, num_buckets, graphs, trace.empty() ? nullptr : &trace, &control, &counters[i], &results[i],
                   &barrier);
        });
    }
    for (auto& t : workers)
        if (t.joinable()) t.join();
    if (controller.joinable()) controller.join();
    if (reporter.joinable()) reporter.join();

    // Original-style summary.
    double avg_elapsed = 0.0;
    uint64_t total_ops = 0;
    for (const auto& r : results) {
        avg_elapsed += r.elapsed_s;
        total_ops += r.ops;
    }
    avg_elapsed /= static_cast<double>(opt.thread_cnt);
    CoherenceStats coherence;
    for (const auto& r : results) coherence += r.coherence;
    LogCoherenceStats(coherence, total_ops);
    LOG(INFO) << "Thread Average time: " << avg_elapsed << " seconds";
    LOG(INFO) << "Total ops: " << total_ops;
    if (avg_elapsed > 0.0)
        LOG(INFO) << "Aggregate throughput: " << static_cast<uint64_t>(total_ops / avg_elapsed) << " ops/s";

    graphs.Free();
    return 0;
}
