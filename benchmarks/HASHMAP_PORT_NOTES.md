# Hashmap port notes

This branch adds a MEGALON port of RACoherence's two hashmap benchmarks, scripts to set up,
build and run it, and the MEGALON fixes needed to run it on a real CXL device (a CPU-less
NUMA node). This file describes those changes as they stand; `git diff 3be2fa7` shows them.

## 1. The benchmark

`benchmarks/hashmap.cc` (driver) and `benchmarks/hashmap_common.h` (shared code), built as
the `hashmap` target in `benchmarks/CMakeLists.txt`.

```
hashmap <result dir> <thread cnt> <write ratio> <zipfian theta>
        [keys per thread] [graph entries per logical node] [key trace file]
```

One binary covers both originals: write ratio 0.0 is `hashmap.cpp` (lookups only), any
other ratio is `hashmap_rw.cpp` (0.1 in the original). Writes go to `key + 1024`, as in
the original, so read and write hotspots differ.

How the original maps onto MEGALON:

| original (RACoherence) | port |
|---|---|
| 128M × 8 B `GlobalEntry` table in CXL memory | one MEGALON object per bucket, holding the 8-byte entry; `NUM_OBJS` buckets |
| 131,072 `CXLSharedMutex` stripe locks | none: a `rackobj::Put` is atomic with respect to concurrent `Get`s, and `map_put` is a blind overwrite |
| one process per node (`RAC_SERVER_IDX`) | MEGALON logical nodes in one process; thread `tid` belongs to node `tid % LOGICAL_NODE_NUM` |
| graph array `malloc`'d per process | `numa_alloc_onnode` per logical node, on its execution node, never on `NUMA_MEM` |
| `./zipf.txt` key trace | same default; keys folded into the configured bucket count; `builtin` selects MEGALON's zipfian generator |

Keep one bucket per object: packing several into an object would make a write a
read-modify-write, and MEGALON's API has no lock to protect it.

Each thread makes `iterations` passes over its own slice of the trace (10 for read-only,
1 otherwise, as in the originals; `HASHMAP_ITERATIONS` overrides). Output: `Thread Average
time`, `Elapsed time`, `Total ops`, `Aggregate throughput`, and a `coherence:` line with
MEGALON's read, admit and retry counts.

Footprint: each object occupies a full `SLOT_SIZE` slot (1 KiB in the KV build), so
`NUM_OBJS = 1048576` gives 1 GiB of object data, the same as the original's table.

## 2. Scripts

**`scripts/setup_lean.sh [NUMA_MEM] [LOGICAL_NODE_NUM] [KEY_SIZE] [NUM_NUMA]`** replaces
`setup.sh`: it initialises only the submodules that are built, rewriting `yaml-cpp`'s SSH
URL to HTTPS; installs fewer packages; is safe to re-run; and fixes `setup.sh`'s
`mkdir -p RESULT_DIR`. `NUM_NUMA` must
exclude a CPU-less CXL node. Environment: `RESULT_DIR` (must end in `/`), `RUSTUP_HOME`,
`CARGO_HOME`, `LLVM_PKGS`, `WITH_HOSTRPC=1`.

**`scripts/build_lean.sh [options]`** replaces `build.sh`: it builds only the requested
targets (default `megalon hashmap`) and only the NR Rust variant CMake links, and it is
incremental. Options include `--clean`, `--build-dir`, `--jobs`, `--prune`,
`--clang-bin-dir` and `--no-fmt`. Use `--no-fmt`: upstream's `fmt` target runs
`clang-format -i` on the source tree during every build, which rewrites some files under
newer clang-format versions.

**`scripts/eval/hashmap.sh`** runs the sweep. Settings, all overridable from the
environment unless marked:

| setting | default | meaning |
|---|---|---|
| `VARIANTS`, `ZIPFS`, `THREAD_COUNTS`, `NUM_OBJS`, `W_RATIOS`, `SCR_SIZES` (arrays, edit in the script) | `megalon`, 0.99, 32, 1048576, 0.0 0.1, 200 | the sweep |
| `TRIALS` | 1 | runs per configuration; with more than 1, results go to `<dir>-t<k>` and `stat.log` adds mean/min/max per thread count |
| `KEYS_PER_THREAD` | 0 (whole trace slice) | keys per thread |
| `GRAPH_ENTRIES` | (2 << 20) / `LOGICAL_NODE_NUM` | graph entries per logical node: 16 GB total, as in the originals |
| `KEY_TRACE`, `RO_TRACE`, `RW_TRACE` | `./keytrace/{ro,rw}` | key traces for the read-only and read-write mixes; `builtin` uses MEGALON's zipfian generator; a missing file is an error |
| `NCR_SIZE`, `SCR_SIZE`, `LOCAL_SIZE` | 2GB, 2GB, 8GB | MEGALON regions; the script checks the slots fit in `NCR_SIZE` |
| `SLOT_HEADROOM_PCT` | 25 | spare slots beyond `NUM_OBJS` |
| `CXL_CAPACITY` | 16GB | device size, used only for a warning |
| `UNCORE_MODE` | off | `pin` fixes every package's uncore frequency; `slow` emulates CXL by slowing `NUMA_MEM` (emulation only) |

It generates its own `config/hashmap.generated.yaml` rather than editing the checked-in
`config/a.yaml`. Results go to `${RACKOBJ_RESULT_DIR}hashmap/<variant>/`, and logs and
`stat.log` to `logs/hashmap/<variant>/`.

## 3. Changes to MEGALON

### 3.1 The CXL copy's index in the directory

A directory entry's `cn_array_` holds the CXL copy at index 0 and logical nodes' copies at
1..`LOGICAL_NODE_NUM`. Upstream addressed the CXL copy as index `NUMA_MEM`, which is only
correct when `NUMA_MEM` is 0, as under NUMA emulation. On a real CXL device (`NUMA_MEM = 2`
here) the CXL copy shared logical node 1's index, and in the Rust directory objects were
created without their write-metadata slot recorded, leaking one slot per object.

- C++: `C3POHandle::kCxlArrayIdx = 0` in `src/core/c3.h`, used by `ExistOnCxl`,
  `CacheNodeIndexOnCxl` and `FindRemoteCacheNodeIndex` (`c3.{h,cc}`), and by the six
  `CheckAndInsert` calls in `lib/shm_obj_handle.cc`.
- Rust: `CXL_ARRAY_IDX = 0` in `third-party/nr_rust/ffi/ffi_nr_hashmap.rs`, used by
  `CheckPutArrayWmeta`.

### 3.2 CPU-less NUMA nodes in the NR affinity code

`ffi_nr_hashmap.rs` places replica memory by moving the thread onto the target node's CPUs.
A CXL device is a memory-only node, so that called `sched_setaffinity` with an empty mask and
panicked. For a CPU-less node it now binds the allocation policy instead
(`set_mempolicy(MPOL_BIND)`), and resets it afterwards.

### 3.3 Write-metadata reclamation

- `SampleVictim` (`src/core/write_meta.cc`) locks its candidate with a try-lock,
  `TryWLockOnly()`, built on `try_write_seqlock_only()` in `src/core/seqcount.{h,cc}`.
  Upstream used the blocking `WLockOnly()`, although its contract is to return nothing when
  locking fails. The blocking lock could deadlock reclaimers on each other's slots, and
  could lock a slot that was freed while it waited.
- `WriteMetadataManager::SampleReclaim` (`src/manager/wmeta_manager.cc`) gives up after
  `8 * count + 64` attempts and tries again on its next pass, since with a try-lock
  `SampleVictim` can return nothing.
- `CheckReserveWmeta` (`write_meta.cc`) logs a warning, at most every 10,000 occurrences,
  when the 95% occupancy gate rejects a reservation or a full scan finds no free slot.

The reclamation sites themselves are upstream's code.

### 3.4 Other

- `third-party/nr_rust/rust-toolchain` no longer requests the `rustc-dev` component.
- `benchmarks/common.h`: `CPU_FREQ_GHZ` is 0.8 (was 2.1). Only `ycsb_benchmark.cc` uses it,
  to convert latencies from cycles.

## 4. Checking a run

At teardown MEGALON prints:

```
WriteMetadataManager for node N on node M joined, total reclaim count: R
seqlock alloc ratio: (allocated|pool) = X%, reclaim count: R, allocate count: A
```

`N` is `NUMA_MEM`: 0 means the data was in DRAM (emulation), not on the CXL device. In a
healthy run with writes, `allocated` equals `NUM_OBJS`, `allocate count` equals `NUM_OBJS`
(the load) and `reclaim count` is 0. More allocated slots than objects means slots are
leaking, and `CheckReserveWmeta` warnings mean the pool hit its 95% gate.

## 5. Known limitations

- `IterativeReclaim`, compiled only without `SAMPLING`, still uses a blocking lock. The KV
  build defines `SAMPLING`.
- `DeleteIfArray` and `CheckCoherenceSlot` in `ffi_nr_hashmap.rs` still treat index
  `NUMA_MEM` as the CXL copy. Nothing calls them (`DeleteIfReadOnly` and
  `C3POHandle::CheckCoherence` are unused).
- Upstream's `src/core/write_meta.cc` has asserts naming `wmeta_slot_len_` outside its
  scope, so it only compiles with `NDEBUG` (release builds).
