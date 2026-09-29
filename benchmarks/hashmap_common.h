// hashmap_common.h
//
// Shared scaffolding for the two ported hashmap benchmarks:
//   - hashmap_ro.cc  (port of the RACoherence `hashmap.cpp`, read-only)
//   - hashmap_rw.cc  (port of the RACoherence `hashmap_rw.cpp`, 90/10 read/write)
//
// Porting notes (see PORTING_NOTES.md for the full mapping):
//   * RACoherence exposes raw coherent CXL memory (`cxlnhc_cl_aligned_malloc`) plus explicit
//     `CXLSharedMutex` locks.  MEGALON instead exposes an *object* interface
//     (`rackobj::Get` / `rackobj::Put`), and provides per-object atomicity itself.
//     Consequently the bucket array becomes an array of MEGALON objects, one bucket per
//     object, and the 128K-entry lock array disappears entirely.
//   * The original ran one process per node (`RAC_SERVER_IDX`, `rac_thread_create`,
//     `CXLBarrier`).  MEGALON emulates logical nodes inside a single process: a thread is
//     bound to a logical node by `rackobj::Register(tid)` (tid % LOGICAL_NODE_NUM).
//     So `server_size * THREADS_PER_PROCESS` collapses to a single `thread_cnt` argument.
//   * The graph-traversal array stays in node-local DRAM, as in the original, but is now
//     allocated per *logical node* with `numa_alloc_onnode` instead of per process.

#pragma once

#include <numa.h>
#include <rackobj.h>
#include <sched.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "access_pattern.h"
#include "common.h"  // pulls in ../src/common/constants.h (SLOT_SIZE, LOGICAL_NODE_NUM, ...)

namespace hashmap_bench {

// --------------------------------------------------------------------------------------
// Constants carried over from the original benchmarks
// --------------------------------------------------------------------------------------

// Original: kArrayEntrySize = 8192, one graph node per 64B cache line.
inline constexpr uint32_t kArrayEntrySize = 8192;
inline constexpr uint32_t kGraphNodeSize = 64;
inline constexpr uint32_t kGraphNodesPerEntry = kArrayEntrySize / kGraphNodeSize;  // 128

// Original: kNumArrayEntries = 2 << 20, divided by `server_size` (one process per node).
// Here it is divided by the number of logical nodes, since all nodes live in one process.
inline constexpr uint32_t kNumArrayEntriesTotal = 2u << 20;

// Original: writes were offset by ENTRIES_PER_LOCK so that the read hotspot and the write
// hotspot do not coincide (per the TAOBench observation).  ENTRIES_PER_LOCK was
// VECTOR_ENTRY_NUM / LOCK_NUM = 1024.
inline constexpr int32_t kWriteKeyShift = 1024;

// Sentinel written by the loader, so that a lookup of a key that was never inserted
// misses, exactly like the `entry.key != key` miss path in the original `map_get`.
inline constexpr int32_t kEmptyKey = INT32_MIN;

// --------------------------------------------------------------------------------------
// Bucket layout
// --------------------------------------------------------------------------------------
// One MEGALON object == one hash bucket.  The original bucket was an 8-byte
// {int key; int value;}, and that is all each object holds: the header sits at the front of
// the object's SLOT_SIZE slot and the rest of the slot is unused.  Because the entry is
// written in a single `rackobj::Put`, the blind-overwrite semantics of the original
// `map_put` are preserved without any explicit lock: MEGALON serializes concurrent access
// to an object.
struct BucketHeader {
    int32_t key;
    int32_t value;
};
static_assert(sizeof(BucketHeader) == 8, "bucket header must stay 8 bytes");

// Bytes moved per Get / Put: just the 8-byte entry, as the originals read and wrote a
// GlobalEntry directly.  MEGALON's CXL read path copies min(count, SLOT_SIZE) - the stored
// object length is not consulted (CopyToUserBufferCXL) - so the request size alone decides
// the data moved per operation.  It is not the footprint: each object still occupies a full
// SLOT_SIZE slot (1024 B in the KV build), so the table is key_space * SLOT_SIZE bytes.
inline constexpr uint64_t kAccessSize = sizeof(BucketHeader);
static_assert(kAccessSize <= SLOT_SIZE, "access size must fit in one slot");

// Same hash the original used (std::hash<int> is the identity on libstdc++, so the key
// distribution seen by the map is unchanged).
inline size_t BucketOf(int32_t key, size_t num_buckets) { return std::hash<int32_t>{}(key) % num_buckets; }

// Port of `map_get`.  Returns the value, or -1 on a key mismatch (a miss).
// `buf` must be at least kAccessSize bytes and is owned by the caller (thread-local).
inline int32_t MapGet(uint8_t* buf, int32_t key, size_t num_buckets) {
    const off_t bucket = static_cast<off_t>(BucketOf(key, num_buckets));
    const ssize_t rc = rackobj::Get(buf, kAccessSize, bucket);
    PCHECK(rc != -1) << "rackobj::Get failed for bucket " << bucket;

    BucketHeader hdr;
    std::memcpy(&hdr, buf, sizeof(hdr));
    if (hdr.key != key) return -1;
    return hdr.value;
}

// Port of `map_put`.  The original's write is a blind overwrite (no read-modify-write),
// so it needs no protection against lost updates; its writer lock prevented torn access
// to the 8-byte entry - readers seeing a half-written pair, or two writers interleaving.
// MEGALON provides both per object: Put serialises writers on the object's write
// seqlock, and a concurrent Get detects the overlap and retries.
inline void MapPut(uint8_t* buf, int32_t key, int32_t value, size_t num_buckets) {
    const off_t bucket = static_cast<off_t>(BucketOf(key, num_buckets));
    BucketHeader hdr{key, value};
    std::memcpy(buf, &hdr, sizeof(hdr));
    const ssize_t rc = rackobj::Put(buf, kAccessSize, bucket);
    PCHECK(rc != -1) << "rackobj::Put failed for bucket " << bucket;
}

// --------------------------------------------------------------------------------------
// Graph traversal array (node-local DRAM, one array per logical node)
// --------------------------------------------------------------------------------------

struct ArrayEntry {
    uint8_t data[kArrayEntrySize];
};

class GraphArrays {
public:
    // Called once per logical node, by a thread already pinned to that node's exec NUMA
    // node (i.e. after rackobj::Register).
    void InitForNode(int logical_nid, uint32_t entries_per_node) {
        CHECK(logical_nid >= 0 && logical_nid < LOGICAL_NODE_NUM) << "bad logical node " << logical_nid;

        // The graph array is the node-LOCAL DRAM half of this workload - the original
        // malloc'd it per process on the exec node. It must never land on NUMA_MEM: that
        // is the CXL device, and putting the pointer chase there measures CXL latency
        // instead of the local-vs-remote contrast the benchmark exists to show.
        uint32_t numa_node = UINT32_MAX;
        PCHECK(getcpu(nullptr, &numa_node) != -1) << "getcpu() failed";
        CHECK(static_cast<int>(numa_node) != NUMA_MEM)
            << "graph array would be allocated on NUMA_MEM (" << NUMA_MEM << "), the CXL node. "
            << "rackobj::Register(" << logical_nid << ") should have pinned this thread to an exec node; "
            << "check RidToNumaNode()/NUM_NUMA in src/common/constants.h.";

        const size_t bytes = static_cast<size_t>(entries_per_node) * sizeof(ArrayEntry);

        // numa_alloc_onnode succeeds lazily: with numa_set_strict(1) an over-commit shows
        // up as the process being killed during first touch, not as a null return. Check
        // the node actually has the memory first, so the failure is a message.
        long long node_free = 0;
        const long long node_size = numa_node_size64(static_cast<int>(numa_node), &node_free);
        if (node_size > 0 && node_free < static_cast<long long>(bytes)) {
            LOG(FATAL) << "node " << numa_node << " has " << (node_free >> 20) << " MB free but the graph array "
                       << "needs " << (bytes >> 20) << " MB. Lower GRAPH_ENTRIES (total is "
                       << "LOGICAL_NODE_NUM x entries x 8KB = "
                       << ((static_cast<size_t>(LOGICAL_NODE_NUM) * bytes) >> 20) << " MB across " << LOGICAL_NODE_NUM
                       << " logical nodes), or lower local_size in the config.";
        }

        void* mem = numa_alloc_onnode(bytes, static_cast<int>(numa_node));
        CHECK(mem != nullptr) << "numa_alloc_onnode(" << bytes << ", " << numa_node << ") failed";

        auto* entries = static_cast<ArrayEntry*>(mem);

        // Build one random Hamiltonian cycle over the 128 nodes of an entry, then replicate
        // it to every entry - identical to the original data_init().
        std::vector<uint8_t> indices(kGraphNodesPerEntry);
        for (size_t i = 0; i < kGraphNodesPerEntry; i++) indices[i] = static_cast<uint8_t>(i);
        std::mt19937 gen(12345 + logical_nid);
        for (size_t i = kGraphNodesPerEntry - 1; i > 0; i--) {
            std::uniform_int_distribution<size_t> d(0, i);
            std::swap(indices[i], indices[d(gen)]);
        }

        ArrayEntry sample{};
        for (size_t i = 0; i < kGraphNodesPerEntry; i++) {
            sample.data[kGraphNodeSize * indices[i]] = indices[(i + 1) % kGraphNodesPerEntry];
        }
        for (uint32_t i = 0; i < entries_per_node; i++) {
            std::memcpy(entries[i].data, sample.data, kArrayEntrySize);
        }

        arrays_[logical_nid] = entries;
        bytes_[logical_nid] = bytes;
        entries_per_node_ = entries_per_node;
        LOG(INFO) << "logical node " << logical_nid << ": graph array of " << entries_per_node << " entries ("
                  << (bytes >> 20) << " MB) on numa node " << numa_node << " (DRAM; NUMA_MEM=" << NUMA_MEM
                  << " is the CXL node and is excluded)";
    }

    void Free() {
        for (int i = 0; i < LOGICAL_NODE_NUM; i++) {
            if (arrays_[i] != nullptr) numa_free(arrays_[i], bytes_[i]);
            arrays_[i] = nullptr;
        }
    }

    const ArrayEntry* Node(int logical_nid) const { return arrays_[logical_nid]; }
    uint32_t EntriesPerNode() const { return entries_per_node_; }

private:
    ArrayEntry* arrays_[LOGICAL_NODE_NUM] = {};
    size_t bytes_[LOGICAL_NODE_NUM] = {};
    uint32_t entries_per_node_ = 0;
};

// One pointer-chase over a randomly chosen entry, as in the original GRAPH_TRAVERSAL block.
// `visited` is a caller-owned scratch buffer of kGraphNodesPerEntry bytes.
inline void GraphTraversal(const ArrayEntry* entries, uint32_t entry_count, uint32_t rnd, uint8_t* visited) {
    const ArrayEntry& entry = entries[rnd % entry_count];
    uint32_t current = 0;
    std::memset(visited, 0, kGraphNodesPerEntry);
    for (size_t i = 0; i < kGraphNodesPerEntry; i++) {
        visited[current] = 1;
        current = entry.data[current * kGraphNodeSize];
    }
    // Keep the chase from being optimized away (the original used ACCESS_ONCE).
    __asm__ __volatile__("" : : "r"(current) : "memory");
}

// --------------------------------------------------------------------------------------
// Key source: either the zipf.txt trace used by the original, or MEGALON's built-in
// zipfian generator.
// --------------------------------------------------------------------------------------

// The originals split the trace evenly: thread `id` reads zipf[per_thread * id + i] for
// i in [0, per_thread), and NUM_ITERATIONS repeats that same slice. So a thread wraps to the
// start of *its own slice*, never into another thread's keys.
class KeySource {
public:
    // trace == nullptr (or empty) -> MEGALON's ScrambledZipfianGenerator over `key_space`.
    KeySource(const std::vector<int32_t>* trace, size_t key_space, double theta, size_t slice_begin, size_t slice_len)
        : trace_((trace != nullptr && !trace->empty()) ? trace : nullptr),
          begin_(slice_begin),
          end_(slice_begin + slice_len),
          pos_(slice_begin) {
        if (trace_ == nullptr) {
            pattern_ = std::make_unique<rackobj::benchmark::ZipfianAccessPattern>(key_space, theta, 0.0f);
        } else {
            CHECK(slice_len > 0 && end_ <= trace_->size()) << "bad trace slice [" << begin_ << ", " << end_ << ")";
        }
    }

    int32_t Next() {
        if (trace_ != nullptr) {
            if (pos_ >= end_) pos_ = begin_;  // next iteration over the same slice
            return (*trace_)[pos_++];
        }
        return static_cast<int32_t>(pattern_->GenerateNextOffset());
    }

private:
    const std::vector<int32_t>* trace_;
    size_t begin_;
    size_t end_;
    size_t pos_;
    std::unique_ptr<rackobj::benchmark::ZipfianAccessPattern> pattern_;
};

// The key trace the original benchmarks used. Default path, matching their `./zipf.txt`.
inline constexpr const char* kDefaultZipfTrace = "./zipf.txt";
// Passing either of these instead of a path selects MEGALON's built-in generator.
inline bool IsBuiltinKeySource(const std::string& s) { return s == "builtin" || s == "none"; }

// The original wrote raw int32 and read it back with read(2), but a file called
// "zipf.txt" is just as likely to hold whitespace-separated decimal keys, so sniff the
// first bytes and parse accordingly rather than silently producing garbage keys.
inline bool LooksLikeTextTrace(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) return false;
    char probe[64] = {};
    f.read(probe, sizeof(probe));
    const std::streamsize n = f.gcount();
    if (n == 0) return false;
    for (std::streamsize i = 0; i < n; i++) {
        const unsigned char c = static_cast<unsigned char>(probe[i]);
        const bool ok = (c >= '0' && c <= '9') || c == '-' || c == '+' || c == ' ' || c == '\t' || c == '\n' ||
                        c == '\r' || c == ',';
        if (!ok) return false;
    }
    return true;
}

// max_keys == 0 means "load the whole file".
inline std::vector<int32_t> LoadZipfTrace(const std::string& path, size_t max_keys) {
    std::vector<int32_t> keys;

    if (LooksLikeTextTrace(path)) {
        std::ifstream f(path);
        CHECK(f.is_open()) << "failed to open zipf trace " << path;
        int64_t v;
        while (f >> v) {
            keys.push_back(static_cast<int32_t>(v));
            if (max_keys != 0 && keys.size() >= max_keys) break;
        }
        LOG(INFO) << "loaded " << keys.size() << " keys from " << path << " (text)";
        CHECK(!keys.empty()) << path << " parsed as text but contained no keys";
        return keys;
    }

    std::ifstream f(path, std::ios::binary);
    CHECK(f.is_open()) << "failed to open zipf trace " << path;
    f.seekg(0, std::ios::end);
    const size_t available = static_cast<size_t>(f.tellg()) / sizeof(int32_t);
    f.seekg(0, std::ios::beg);
    const size_t count = (max_keys == 0) ? available : std::min(available, max_keys);
    CHECK(count > 0) << path << " holds no int32 keys";
    keys.resize(count);
    f.read(reinterpret_cast<char*>(keys.data()), static_cast<std::streamsize>(count * sizeof(int32_t)));
    CHECK(f.gcount() == static_cast<std::streamsize>(count * sizeof(int32_t))) << "short read on " << path;
    LOG(INFO) << "loaded " << count << " keys from " << path << " (binary int32, " << (count * sizeof(int32_t) >> 20)
              << " MB)";
    return keys;
}

// Resolves the trace argument into the keys to use, or an empty vector for the built-in
// generator. Missing files are fatal rather than a silent fallback: quietly swapping the
// key distribution would invalidate a comparison against the RACoherence numbers.
inline std::vector<int32_t> ResolveKeyTrace(const std::string& trace_arg, size_t num_buckets, size_t max_keys) {
    if (IsBuiltinKeySource(trace_arg)) {
        LOG(INFO) << "key source: built-in zipfian generator";
        return {};
    }
    if (access(trace_arg.c_str(), R_OK) != 0) {
        LOG(FATAL) << "zipf trace not readable: " << trace_arg
                   << "\n  the original benchmarks read ./zipf.txt from the working directory;"
                   << "\n  point the last argument at your trace, or pass 'builtin' to use"
                   << "\n  MEGALON's own zipfian generator instead.";
    }
    std::vector<int32_t> trace = LoadZipfTrace(trace_arg, max_keys);
    // Trace keys were generated for the original's 128M-bucket table; fold them into the
    // configured bucket count so the skew shape is preserved.
    for (auto& k : trace) k = static_cast<int32_t>(static_cast<uint32_t>(k) % num_buckets);
    return trace;
}

// --------------------------------------------------------------------------------------
// Measurement helpers
// --------------------------------------------------------------------------------------

// Per-thread coherence counters. These are thread-local inside libmegalon
// (lib/globals.cc reads lib::thread_local_meta.pt_stat), so they MUST be sampled from
// inside the worker thread, not from main.
//
// Note: rackobj.h also declares GetPageCacheMissCount() and GetPageCacheOperationCount(),
// but nothing in lib/ or src/ defines them - referencing either fails at link time.
struct CoherenceStats {
    uint64_t reads = 0;         // GetReadCount
    uint64_t read_retries = 0;  // GetReadRetryCount: seqlock retries, i.e. a writer raced us
    uint64_t retry_invocs = 0;  // GetReadRetryInvoc: reads that had to retry at least once
    uint64_t admits = 0;        // GetAdmitCount: objects pulled into this node's cache

    static CoherenceStats Sample() {
        return {rackobj::GetReadCount(), rackobj::GetReadRetryCount(), rackobj::GetReadRetryInvoc(),
                rackobj::GetAdmitCount()};
    }
    CoherenceStats operator-(const CoherenceStats& o) const {
        return {reads - o.reads, read_retries - o.read_retries, retry_invocs - o.retry_invocs, admits - o.admits};
    }
    CoherenceStats& operator+=(const CoherenceStats& o) {
        reads += o.reads;
        read_retries += o.read_retries;
        retry_invocs += o.retry_invocs;
        admits += o.admits;
        return *this;
    }
};

// Admits and retries are the two observable proxies for invalidation traffic: an admit
// means the object was not resident locally (first touch, or evicted/invalidated since),
// and a retry means a writer changed the object while it was being read.
inline void LogCoherenceStats(const CoherenceStats& s, uint64_t total_ops) {
    const double per_op = (total_ops > 0) ? 1.0 / static_cast<double>(total_ops) : 0.0;
    LOG(INFO) << "coherence: reads=" << s.reads << " admits=" << s.admits << " ("
              << static_cast<double>(s.admits) * per_op << "/op)"
              << " read_retries=" << s.read_retries << " (" << static_cast<double>(s.read_retries) * per_op << "/op)"
              << " reads_that_retried=" << s.retry_invocs;
}

// Creates `dir` and any missing parents.
inline void MakeDirs(const std::string& dir) {
    std::string path = dir;
    size_t pos = 0;
    while ((pos = path.find('/', pos + 1)) != std::string::npos) {
        std::string subdir = path.substr(0, pos);
        if (mkdir(subdir.c_str(), 0755) < 0 && errno != EEXIST) {
            LOG(FATAL) << "Failed to create directory: " << subdir << " " << strerror(errno);
        }
    }
    if (mkdir(path.c_str(), 0755) < 0 && errno != EEXIST) {
        LOG(FATAL) << "Failed to create directory: " << path << " " << strerror(errno);
    }
}

// --------------------------------------------------------------------------------------
// Load phase: every bucket must exist as an object before it can be read.
// Replaces `memset(root->global_entries, 1, ...)` in the originals.
// --------------------------------------------------------------------------------------
// read_only: load every object in MEGALON's read-only state.
//
// A Put with a real buffer admits the object with write metadata (a wmeta slot), and from
// then on every Get of it takes the writable path: read_seq_start / read_seq_end load the
// wmeta seqlock in the SCR on the memory node before and after the copy and check the
// per-node local seqcount. A read-only workload never needs that - nothing will write.
//
// CreateEntry() special-cases a null source buffer: "if write_data nullptr, then initialize
// entry in RO mode" - no wmeta reserved, no copy - and read_seq_start/end then skip all
// sequence checking. That is how MEGALON's own kv_store.cc warms up when write_ratio == 0,
// and it matches the original hashmap.cpp, whose reads take no synchronisation at all.
//
// The object data is then left as the region was initialised (zeroed), so every bucket
// header reads {key 0, value 0}: lookups miss, as they did against the original's
// memset(7) table. With writes in the mix, objects are loaded writable so that the first
// write to each does not have to allocate write metadata - again as kv_store.cc does.
inline void LoadBuckets(size_t num_buckets, size_t loader_threads, bool read_only) {
    LOG(INFO) << "loading " << num_buckets << " buckets (" << (num_buckets * SLOT_SIZE >> 20) << " MB of slots, "
              << (read_only ? "read-only" : "writable") << ")";

    std::vector<std::jthread> loaders(loader_threads);
    ThreadBarrier barrier(loader_threads);

    for (size_t t = 0; t < loader_threads; ++t) {
        loaders[t] = std::jthread([t, loader_threads, num_buckets, read_only, &barrier] {
            rackobj::Register(static_cast<int>(t));
            barrier.Wait();

            std::unique_ptr<uint8_t[]> holder;
            const uint8_t* buf = nullptr;
            if (!read_only) {
                holder = std::make_unique<uint8_t[]>(kAccessSize);
                std::memset(holder.get(), 0, kAccessSize);
                BucketHeader hdr{kEmptyKey, 0};
                std::memcpy(holder.get(), &hdr, sizeof(hdr));
                buf = holder.get();
            }

            for (size_t b = t; b < num_buckets; b += loader_threads) {
                const ssize_t rc = rackobj::Put(buf, kAccessSize, static_cast<off_t>(b));
                PCHECK(rc != -1) << "load put failed for bucket " << b;
            }

            barrier.Wait();
            rackobj::UnRegister();
        });
    }
    for (auto& t : loaders)
        if (t.joinable()) t.join();

    LOG(INFO) << "done loading";
}

// Allocates and initializes one graph array per logical node.
inline void InitGraphArrays(GraphArrays* arrays, uint32_t entries_per_node) {
    std::vector<std::jthread> init_threads(LOGICAL_NODE_NUM);
    for (int rid = 0; rid < LOGICAL_NODE_NUM; ++rid) {
        init_threads[rid] = std::jthread([rid, entries_per_node, arrays] {
            // TidToRid() is tid % LOGICAL_NODE_NUM, so tid == rid lands on logical node rid.
            rackobj::Register(rid);
            arrays->InitForNode(rid, entries_per_node);
            rackobj::UnRegister();
        });
    }
    for (auto& t : init_threads)
        if (t.joinable()) t.join();
}

}  // namespace hashmap_bench
