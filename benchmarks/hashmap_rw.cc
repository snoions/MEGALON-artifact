// hashmap_rw.cc
//
// MEGALON port of the RACoherence benchmark `hashmap_rw.cpp`.
//
// Same workload as hashmap_ro.cc, except that a fraction of the operations (10% in the
// original: `dist(gen) % 10 == 9`) are writes, and writes are aimed at a different key
// than reads (`target_key + ENTRIES_PER_LOCK`) because, per TAOBench, read and write
// hotspots usually do not coincide.
//
// The interesting part of the port is the locking:
//
//   The original guarded the table with an array of 128K `CXLSharedMutex`, one per 1024
//   buckets: readers took `lock_shared()`, writers took `lock()`.  Those locks existed
//   only to keep a reader from observing a torn 8-byte entry while a writer overwrote it -
//   `map_put` is a blind overwrite, not a read-modify-write, so no mutual exclusion
//   between writers is actually required by the workload.
//
//   MEGALON gives exactly that guarantee at object granularity: a `rackobj::Put` of a
//   whole object is atomic with respect to concurrent `rackobj::Get`s (that is what the
//   seqlock-based coherence records are for).  With one bucket per object, the lock array
//   therefore disappears entirely, and with it the false sharing between the 1024 buckets
//   that used to share a lock.
//
//   Caveat: if you extend this port to pack several buckets into one object, a write turns
//   into a read-modify-write of the object and updates to different buckets in the same
//   object can be lost.  That would need an application-level lock, which MEGALON's public
//   API does not provide.  Keep one bucket per object.
//
// Usage:
//   hashmap-rw <result dir> <thread cnt> <write ratio> <zipfian theta> <preheat s> <exec s>
//              [ops per thread] [graph entries per node] [zipf trace file]
//
// The key trace defaults to ./zipf.txt, as in the original benchmark. Pass "builtin" as
// the last argument to use MEGALON's own zipfian generator.

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
constexpr int kTraversalPeriod = 32;

struct Options {
    string result_dir;
    size_t thread_cnt = 0;
    double write_ratio = 0.1;  // original: 1 in 10 operations
    double theta = 0.99;
    uint32_t preheat_s = 0;
    uint32_t exec_s = 0;
    uint64_t ops_per_thread = 0;
    uint32_t graph_entries_per_node = 0;
    string zipf_trace;
};

struct WorkerResult {
    uint64_t reads = 0;
    uint64_t writes = 0;
    double elapsed_s = 0.0;
    CoherenceStats coherence;  // delta over the measured window
};

void Worker(size_t thread_idx, const Options& opt, size_t num_buckets, const GraphArrays& graphs,
            const vector<int32_t>* trace, TimingControl* control, PaddedCounter* counter, WorkerResult* result,
            ThreadBarrier* barrier) {
    rackobj::Register(static_cast<int>(thread_idx));
    const int rid = static_cast<int>(rackobj::GetConfigSize_t("logical_nid"));

    auto buf = std::make_unique<uint8_t[]>(kAccessSize);
    std::memset(buf.get(), 0, kAccessSize);
    auto visited = std::make_unique<uint8_t[]>(kGraphNodesPerEntry);

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint32_t> dist(0, UINT32_MAX);
    std::uniform_real_distribution<double> rw_dist(0.0, 1.0);

    const size_t trace_slice = (trace != nullptr && !trace->empty()) ? trace->size() / opt.thread_cnt : 0;
    KeySource keys(trace, num_buckets, opt.theta, trace_slice * thread_idx);

    const bool traverse = opt.graph_entries_per_node > 0;
    const ArrayEntry* graph = traverse ? graphs.Node(rid) : nullptr;

    const uint64_t sample_every = LatencySampleEvery();
    vector<int64_t> read_samples, write_samples;
    read_samples.reserve(5'000'000 / sample_every);
    write_samples.reserve(1'000'000 / sample_every);

    barrier->Wait();

    const bool timed = (opt.exec_s > 0);
    uint64_t local_ops = 0;
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
        const bool is_write = rw_dist(gen) < opt.write_ratio;

        uint32_t tsc_aux;
        const uint64_t t1 = __rdtscp(&tsc_aux);
        if (is_write) {
            // Read and write hotspots are deliberately offset, as in the original.
            MapPut(buf.get(), key + kWriteKeyShift, 1, num_buckets);
        } else {
            const int32_t val = MapGet(buf.get(), key, num_buckets);
            __asm__ __volatile__("" : : "r"(val) : "memory");
        }
        const uint64_t t2 = __rdtscp(&tsc_aux);

        if (is_write)
            result->writes++;
        else
            result->reads++;

        local_ops++;
        if (local_ops >= kFlushThreshold) {
            counter->ops.fetch_add(local_ops, std::memory_order_relaxed);
            local_ops = 0;
        }

        if (traverse && (i % kTraversalPeriod == 0)) {
            GraphTraversal(graph, graphs.EntriesPerNode(), dist(gen), visited.get());
        }

        const int64_t ns = cycles_to_nanoseconds(t2 - t1, CPU_FREQ_GHZ);
        const uint64_t done = result->reads + result->writes;
        const bool keep_sample = (sample_every == 1) || (done % sample_every == 0);
        if (timed) {
            if (!warmup_done_local) continue;
            if (measure_local && !cooldown_local && keep_sample) {
                if (is_write)
                    write_samples.push_back(ns);
                else
                    read_samples.push_back(ns);
            }
        } else if (keep_sample) {
            if (is_write)
                write_samples.push_back(ns);
            else
                read_samples.push_back(ns);
        }
    }

    const auto end = std::chrono::high_resolution_clock::now();
    counter->ops.fetch_add(local_ops, std::memory_order_relaxed);
    if (!timed) result->coherence = CoherenceStats::Sample() - coherence_base;
    result->elapsed_s = std::chrono::duration<double>(end - start).count();

    if (!opt.result_dir.empty()) {
        const string dir = opt.result_dir + "/" + to_string(opt.thread_cnt);
        WriteSamples(read_samples, dir + "/latencies-" + to_string(thread_idx));
        WriteSamples(write_samples, dir + "/write-latencies-" + to_string(thread_idx));

        double duration_s = result->elapsed_s;
        if (timed) {
            const int64_t s = control->measure_start_ns.load(std::memory_order_acquire);
            const int64_t e = control->measure_end_ns.load(std::memory_order_acquire);
            duration_s = (s != -1 && e > s) ? static_cast<double>(e - s) / 1e9 : 0.0;
        }
        std::ofstream f(dir + "/throughput-" + to_string(thread_idx));
        // Operations, not samples: with LATENCY_SAMPLE_EVERY > 1 those differ, and the
        // throughput file must report ops for avg_lat.py to compute the right rate.
        if (f.is_open()) f << (result->reads + result->writes) << "\n" << duration_s << "\n";
    }

    barrier->Wait();
    rackobj::UnRegister();
}

}  // namespace

int main(int argc, char** argv) {
    absl::SetStderrThreshold(absl::LogSeverity::kInfo);
    absl::InitializeLog();

    if (argc < 7 || argc > 10) {
        std::cerr << "Usage: " << argv[0]
                  << " <result dir> <thread cnt> <write ratio> <zipfian theta> <preheat time> <exec time>"
                     " [ops per thread] [graph entries per node] [zipf trace file]\n";
        return 1;
    }

    numa_set_strict(1);

    Options opt;
    opt.result_dir = argv[1];
    opt.thread_cnt = std::stoull(argv[2]);
    opt.write_ratio = std::stod(argv[3]);
    opt.theta = std::stod(argv[4]);
    opt.preheat_s = static_cast<uint32_t>(std::stoul(argv[5]));
    opt.exec_s = static_cast<uint32_t>(std::stoul(argv[6]));
    opt.ops_per_thread = (argc > 7) ? std::stoull(argv[7]) : 10'000'000ull;
    opt.graph_entries_per_node =
        (argc > 8) ? static_cast<uint32_t>(std::stoul(argv[8])) : kNumArrayEntriesTotal / LOGICAL_NODE_NUM;
    opt.zipf_trace = (argc > 9) ? argv[9] : kDefaultZipfTrace;

    const size_t num_buckets = rackobj::GetConfigSize_t("key_space");

    LOG(INFO) << "hashmap-rw: threads=" << opt.thread_cnt << " buckets=" << num_buckets << " obj_size=" << kAccessSize
              << "B write_ratio=" << opt.write_ratio << " theta=" << opt.theta
              << " graph_entries_per_node=" << opt.graph_entries_per_node
              << " keys=" << (IsBuiltinKeySource(opt.zipf_trace) ? "builtin-zipfian" : opt.zipf_trace)
              << (opt.exec_s > 0 ? " mode=timed" : " mode=fixed-ops");

    if (!opt.result_dir.empty()) {
        opt.result_dir += "hashmap-rw-" + double_to_string(opt.write_ratio) + "/" + double_to_string(opt.theta);
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
    LOG(INFO) << "Total ops: " << (reads + writes) << " (reads=" << reads << ", writes=" << writes << ")";
    if (avg_elapsed > 0.0)
        LOG(INFO) << "Aggregate throughput: " << static_cast<uint64_t>((reads + writes) / avg_elapsed) << " ops/s";

    graphs.Free();
    return 0;
}
