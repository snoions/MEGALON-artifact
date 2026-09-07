# Porting `hashmap.cpp` and `hashmap_rw.cpp` to MEGALON

Source: two RACoherence benchmarks — a read-only hash-table lookup workload and a 90/10
read/write version — each combining zipfian KV lookups over shared CXL memory with a
periodic pointer chase over a node-local 8KB array.

Target: `dassl-uiuc/MEGALON-artifact` (`main`), whose public API is `include/rackobj.h`.

Files added:

| File | Purpose |
|---|---|
| `benchmarks/hashmap_common.h` | Bucket layout, `MapGet`/`MapPut`, graph array, key sources, timing control |
| `benchmarks/hashmap_ro.cc` | Port of `hashmap.cpp` → target `hashmap-ro` |
| `benchmarks/hashmap_rw.cc` | Port of `hashmap_rw.cpp` → target `hashmap-rw` |
| `benchmarks/CMakeLists.txt` | Two new `add_executable` blocks (appended) |
| `scripts/eval/hashmap.sh` | Runner modelled on `scripts/eval/sample.sh` |

## 1. API mapping

| RACoherence | MEGALON | Note |
|---|---|---|
| `rac_init(...)`, `rac_shutdown()` | *(nothing)* | The `megalon` shared library self-initializes from `$RACKOBJ_CONFIG` (fallback `/opt/rackobj/config`, see `src/common/config.cc`). |
| `CXLRoot` / `rac_get_user_root()` | *(nothing)* | No shared root object; state that used to live in CXL memory is either an object (the table) or per-process (everything else). |
| `cxlnhc_cl_aligned_malloc(VECTOR_ENTRY_NUM * sizeof(GlobalEntry))` | `key_space` objects, keyed `0 .. key_space-1` | Object count comes from the yaml (`key_space` / `slots`), not from a compile-time constant. |
| `memset(global_entries, 7, ...)` | `LoadBuckets()` | A MEGALON object must be `Put` before it can be `Get`; the same explicit load phase `kv_store.cc` and `ycsb_benchmark.cc` use. |
| `map_get` (direct load) | `rackobj::Get(buf, SLOT_SIZE, bucket)` + key compare | |
| `map_put` (direct store) | `rackobj::Put(buf, SLOT_SIZE, bucket)` | |
| `CXLSharedMutex mtxs[128K]`, `lock_shared`/`lock` | *(removed)* | See §3. |
| `CXLBarrier` | `ThreadBarrier` (`benchmarks/common.h`) | Only intra-process synchronization is needed now. |
| `RAC_SERVER_IDX`, one process per node, `rac_thread_create` | one process, `rackobj::Register(tid)` | `TidToRid()` is `tid % LOGICAL_NODE_NUM`, and `RidToNumaNode()` pins the thread — so `server_size * THREADS_PER_PROCESS` collapses to one `thread_cnt` argument spread round-robin over logical nodes. |
| `malloc(array_entries)` per process | `numa_alloc_onnode`, one array per logical node | Preserves "graph array is node-local DRAM", which is the point of that part of the workload. |
| `zipf.txt` read into `int*` | the same trace, still the default (`./zipf.txt`); `builtin` selects MEGALON's `ZipfianAccessPattern` instead | |

## 2. The bucket is the object

The original bucket was `struct GlobalEntry { int key; int value; }` — 8 bytes — and the
table had 128M of them (1 GB). MEGALON's coherence unit is an object of `SLOT_SIZE`
(1024 B in the KV build), so the two natural choices are:

1. **one bucket per object** (chosen): the 8-byte `{key, value}` header sits at the front
   of the object and the rest is value payload. Table size becomes
   `key_space × 1 KB` (18 GB at the artifact's default `key_space: 18000000`), which is
   the scale the MEGALON experiments are tuned for.
2. packing 128 buckets per object: keeps the 1 GB footprint but makes every write a
   read-modify-write of a shared object → **lost updates**, since the public API has no
   lock. Rejected; noted in the header comment of `hashmap_rw.cc` so nobody re-introduces it.

Consequence to keep in mind when comparing numbers: a lookup now transfers 1 KB rather
than 8 B, so the port is not a like-for-like bytes-moved comparison against the
RACoherence run — it is a like-for-like *operation mix* comparison. If you want the small
payload, reduce `kAccessSize` in `hashmap_common.h` (it only needs to be ≥ 8 and
≤ `SLOT_SIZE`); the object footprint stays `SLOT_SIZE` either way.

## 3. Where the locks went

`hashmap_rw.cpp` sharded the table under 128K reader/writer mutexes, one per 1024 buckets.
Reads took the shared lock, writes the exclusive one. But `map_put` is a *blind overwrite*
(`map[bucket_id] = {key, value}`), not a read-modify-write — so those locks were only
preventing a reader from seeing a torn entry, not serializing writers against each other.

MEGALON provides exactly that: a `Put` of a whole object is atomic with respect to
concurrent `Get`s of that object. With one bucket per object, the lock array is redundant
and is removed. This also removes the false sharing the original had between the 1024
buckets that shared a lock, so the RW port should show *less* contention than a literal
translation would — worth calling out explicitly in any writeup, since it is a semantic
difference, not just a mechanical one.

The write-key offset is kept: writes go to `key + 1024` (the original's `ENTRIES_PER_LOCK`)
so the read and write hotspots stay distinct, per the TAOBench observation the original
cites.

## 4. Measurement

Both binaries support two modes:

* `exec_time > 0` — MEGALON's preheat → measure → cooldown window, identical to
  `kv_store.cc`, emitting `latencies-N`, `write-latencies-N`, `throughput-N` per thread so
  `benchmarks/script/avg_lat.py` works unchanged. Use this to compare against the paper's
  numbers.
* `exec_time == 0` — fixed `ops_per_thread` per thread, reporting `Thread Average time`
  and aggregate throughput, i.e. the original's own reporting. Use this to compare against
  the RACoherence run.

## 5. Not verified

The code compiles as a translation unit (`g++ -std=c++23 -fsyntax-only` against the repo's
own `common.h` / `access_pattern.h`), but it has **not** been built or run against the real
`megalon` library, which needs the artifact's hardware (≥2 NUMA nodes, Intel uncore
frequency driver, GCC 11 + clang17 toolchain). Before trusting any number:

1. `./scripts/setup_logical_node.sh <NUMA_MEM> <LOGICAL_NODE_NUM> <KEY_SIZE>` then
   `./scripts/build.sh`, and check the two new targets link.
2. Sanity-check `thread_cnt` against `NUM_NUMA`/`LOGICAL_NODE_NUM`: `kv_store.cc` asserts
   `numa_node == (i % num_exec_numa) + 1`. The port does not assert this — add the same
   `CHECK` if you want the pinning verified.
3. Watch DRAM: the graph array defaults to `(2<<20)/LOGICAL_NODE_NUM` entries × 8 KB per
   node (~5 GB/node). The eval script overrides it to 65536 entries (512 MB/node). Pass 0
   to disable the traversal entirely, which is the equivalent of `#undef GRAPH_TRAVERSAL`.
4. Trace keys are folded with `% key_space`; the skew shape
   survives but the identity of the hot keys does not, so don't compare per-key hit rates
   across systems.

## 6. Open questions worth deciding before running

* Should the RO port's load phase write a *matching* key per bucket (so lookups hit) rather
  than the `INT32_MIN` sentinel (so lookups miss)? The original memset the table to a
  constant, meaning essentially every lookup missed the key comparison but still paid the
  full memory access — the port reproduces that. If the intent was hits, change `kEmptyKey`
  handling in `LoadBuckets`.
* `NUM_ITERATIONS` and `POPULATE_PER_THREAD` from the originals are gone; the equivalent
  knobs are `ops_per_thread` and `exec_time`. Pick one convention before collecting data.

## 7. Lean build (`scripts/build_lean.sh`)

`scripts/build.sh` rebuilds all three NR rust variants from scratch, deletes `build/`, and
runs `make -j` over every target. On a disk-constrained machine use `scripts/build_lean.sh`
instead:

```bash
./scripts/build_lean.sh                       # incremental, megalon + hashmap-ro + hashmap-rw
./scripts/build_lean.sh --clean --prune --no-fmt
BUILD_DIR=/mydata/$USER/megalon-build ./scripts/build_lean.sh
CLANG_BIN_DIR=/mydata/llvm17/bin ./scripts/build_lean.sh
./scripts/build_lean.sh --init-submodules --targets "megalon kv-store hashmap-ro hashmap-rw"
```

Where the savings come from:

* **One NR rust variant, not three.** `make libs` builds `scr`, `no-coherence` and
  `original` into three cargo target trees; CMake links exactly one, chosen by
  `LIMITED_SCR` / `NO_COHERENCE`. The script detects which from the active
  `CMakeLists.txt` (all three `cmake-variant/CMakeLists_*.txt` on `main` use `scr`),
  builds only that, copies the `.a` out, and deletes the cargo tree. It also skips the
  rust build entirely if the `.a` is already there — pass `--nr scr` to force a rebuild
  after touching the rust sources, or `--keep-cargo` for fast incremental rust builds.
* **Targets, not everything.** `--target megalon hashmap-ro hashmap-rw` instead of
  `make -j`, plus `-DBUILD_TESTING=OFF` and the abseil/TBB/yaml-cpp test and example
  switches, so those trees only build what gets linked.
* **Incremental by default.** No `rm -rf build` unless you pass `--clean`.
* **Fewer submodules.** `--init-submodules` inits only yaml-cpp, abseil-cpp, oneTBB, gtl,
  unordered_dense and robin-map. machnet, capnproto and hostrpc are cloned by
  `git submodule update --init --recursive` but are never `add_subdirectory`'d. It also
  rewrites the yaml-cpp submodule URL from `git@github.com:` to https, which avoids the
  SSH-key failure in `setup.sh` on a fresh machine.
* **`--prune`** deletes `*.o` after linking (binaries survive; the next build is a full
  rebuild), and binaries are stripped either way.
* **`--build-dir`** puts the tree on another filesystem and symlinks `./build` to it, so
  the eval scripts' hard-coded `./build/benchmarks/...` paths keep working.
* **`--clang-bin-dir`** generates a toolchain file pointing at a clang that is not
  installed system-wide — for an LLVM release tarball unpacked on the big volume.
* **`--no-fmt`** puts a no-op `clang-format` shim on `PATH`, which neuters
  `add_dependencies(megalon fmt)` without editing the checked-in `CMakeLists.txt`.

`scripts/eval/hashmap.sh` calls `build_lean.sh` by default; override with
`BUILD_SCRIPT=./scripts/build.sh`.

## 8. Lean setup (`scripts/setup_lean.sh`)

Drop-in replacement for `scripts/setup.sh`, same end state, less disk. Re-runnable.

```bash
RUSTUP_HOME=/mydata/$USER/rustup CARGO_HOME=/mydata/$USER/cargo \
    ./scripts/setup_lean.sh 0 3 24      # NUMA_MEM, LOGICAL_NODE_NUM, KEY_SIZE
source ~/.bashrc
./scripts/build_lean.sh
```

Trimmed: six submodules at depth 1 instead of `--recursive` (machnet, capnproto and
hostrpc are never `add_subdirectory`'d); `clang-17` only instead of
clang+lldb+lld+clangd; no valgrind/cloc/libc++-dev; `apt-get clean` afterwards.
Kept because the build needs them: `g++-11` (the toolchain hard-codes
`/usr/lib/gcc/x86_64-linux-gnu/11`), `clang-format` (the `fmt` target), `libmemkind-dev`
and `libhwloc-dev` (both linked into `libmegalon.so`), rust nightly, the `~/.bashrc`
exports, `intel_uncore_frequency`, and `setup_logical_node.sh`.

Bugs in the original it works around:

* `mkdir -p RESULT_DIR` is missing a `$`, so `$RACKOBJ_RESULT_DIR` never gets created and
  the eval scripts fail after the build instead of before it.
* `.gitmodules` points yaml-cpp at `git@github.com:`, which fails without a GitHub SSH
  key; the URL is rewritten to https.
* `git apply third-party/hostrpc.diff` fails on a second run and, under `set -e`, kills
  the script before `setup_logical_node.sh`. Skipped by default (`WITH_HOSTRPC=1` to keep
  it, guarded with `git apply --check`).
* The `.vscode/settings.json` block calls `jq`, which the script never installs. Dropped.

Also: `RUSTUP_HOME`/`CARGO_HOME` can move the rust toolchain off the root filesystem,
`cmake` comes from apt when the distro version is new enough (avoiding the
externally-managed-environment pip failure on Ubuntu 24.04+), and
`intel_uncore_frequency` is added to `/etc/modules-load.d` so it survives a reboot.

## 9. Uncore frequency: emulation only

`scripts/set_uncore_frequency.sh` reads `NUMA_MEM` from `src/common/constants.h` and drops
that package's uncore to 800 MHz while holding the others at 2.4 GHz. That is the
artifact's way of *emulating* CXL latency on a machine whose "CXL" node is really a second
DRAM NUMA node. On a machine with real CXL memory, applying it slows real CXL memory even
further and the numbers mean nothing.

`scripts/eval/hashmap.sh` takes `UNCORE_MODE`, defaulting to `pin` (the artifact's own
scripts hardcode the equivalent of `slow`):

| mode | effect | when |
|---|---|---|
| `slow` | NUMA_MEM package to `SLOW_FREQ_KHZ` (800 MHz), others to `FAST_FREQ_KHZ` | DRAM-only machine, reproducing the paper |
| `pin` (default) | every package to `FAST_FREQ_KHZ`, nothing slowed | real CXL memory — removes turbo-driven run-to-run variance on the exec side without emulating anything |
| `off` | leaves the uncore alone; also skips the `lsmod` check | real CXL memory, and you would rather not touch frequency at all |

```bash
UNCORE_MODE=pin ./scripts/eval/hashmap.sh
SKIP_UNCORE=1 ./scripts/setup_lean.sh 0 3 24     # do not even load the module
```

`pin` is usually the better of the two on real hardware: the exec-side uncore still
affects throughput, and letting it float adds variance that has nothing to do with the
system under test.

Note that the artifact's own `eval*.sh` scripts hard-code
`./scripts/set_uncore_frequency.sh 800000`, so if you run those for comparison you are
getting emulation on top of your real CXL memory. Apply the same `uncore_bench`/
`uncore_reset` treatment to any of them you plan to use.

The unrelated `rackobj::EnableRemoteMemcpySlowdown()` in `include/rackobj.h` is a second
emulation knob; it defaults to off and neither the ported benchmarks nor `kv_store.cc`
turn it on, so there is nothing to disable there.

## 10. Removing the rust toolchain after the build

`libnr_hashmap.a` is a static archive linked into `libmegalon.so`, so once the build
succeeds nothing needs rust at runtime, and C++-only rebuilds do not need it either.
`~/.rustup` and `~/.cargo` can go:

```bash
./scripts/build_lean.sh          # stashes the .a in third-party/nr_rust/prebuilt/
rustup self uninstall            # ~/.rustup + ~/.cargo
sudo apt-get remove libclang-dev && sudo apt-get autoremove   # bindgen-only dependency
```

Keep `libhwloc-dev` and `libnuma-dev`: `target_link_libraries(megalon nr_hashmap hwloc)`
and the hwloc2 crate mean `libmegalon.so` has a real link-time dependency on hwloc.

Two traps:

* `third-party/nr_rust/cpp`'s `make libs` has `clean` as a prerequisite, and `clean` does
  `rm -rf $(RUSTDIR)/target` - which deletes `target/release/libnr_hashmap.a`. Any
  `./scripts/build.sh`, and therefore any stock `eval*.sh`, will wipe the archive and
  then fail with no cargo to regenerate it. `build_lean.sh` now keeps a copy in
  `third-party/nr_rust/prebuilt/` with a stamp of the `constants.rs` values it was built
  from, and restores it automatically when `target/release` is empty. Back that directory
  up off the machine as well.
* Anything that changes `ffi/constants.rs` needs rust again: `setup_logical_node.sh`
  (LOGICAL_NODE_NUM, NUMA_MEM, NUM_EXEC, KEY_SIZE), the `KEY_SIZE` sweep in `eval5.sh`,
  or switching to a CMake variant / branch that links a different NR variant
  (`nr_hashmap_noco`, `nr_hashmap_orig`). Settle those parameters before uninstalling.
  The restore refuses a stamp mismatch rather than linking a mismatched archive, and
  `build_lean.sh` then fails with an explicit message instead of a confusing link error.

## 11. Trimming ~/.rustup (before the build)

Most of `~/.rustup` is installed by `install_deps.sh` and by
`third-party/nr_rust/rust-toolchain`, before cargo compiles anything:

```
[toolchain]
channel = "nightly-2024-06-03"
components = [ "rustfmt", "rustc-dev", "rust-src", "cargo", "clippy" ]
profile = "default"
```

* `rustc-dev` ships the compiler's own rlibs and `librustc_driver` - only tools that link
  against rustc internals need it. Nothing under `ffi/` (the crate the build compiles)
  references `rustc_private`; the `verification/ivy` tree is the plausible reason it is
  listed, and it is not built here.
* `profile = "default"` pulls `rust-docs`, a local copy of the Rust book and API docs.
* `rust-src` is standard-library source for `-Z build-std` and IDEs.
* `clippy` / `rustfmt` are never invoked by `cargo build --release`.

`install_deps.sh` also runs `rustup toolchain install nightly` and `rustup default
nightly`, which installs a *second*, unpinned toolchain - the build always uses the pinned
one because of the `rust-toolchain` file, so that copy is pure overhead.

```bash
./scripts/slim_rust.sh --report   # what is installed and what each part costs
./scripts/slim_rust.sh --slim     # minimal profile, drop the components, clear caches
./scripts/build_lean.sh --nr scr  # confirm the NR library still builds
./scripts/slim_rust.sh --revert   # if cargo complains about a missing component
```

`--slim` rewrites `rust-toolchain` (backing it up first), because removing components with
`rustup component remove` alone does not stick - rustup re-installs whatever that file
requests on the next cargo invocation. The pinned channel is kept: these crates do use
nightly features. It also reports any extra toolchain it finds rather than removing it
silently.

`scripts/setup_lean.sh` now installs rustup with `--profile minimal --default-toolchain
none` and lets the pinned toolchain arrive on first use, instead of installing a full
nightly up front.


## 12. Key source

Both binaries read `./zipf.txt` by default, matching the originals' `#define ZIPFIAN` path
(`open("./zipf.txt", O_RDONLY)`, relative to the working directory). The last positional
argument overrides the path; pass `builtin` or `none` to use MEGALON's
`ZipfianAccessPattern` instead, in which case `<zipfian theta>` is what sets the skew.

A missing trace is fatal rather than a silent fallback to the generator - quietly swapping
the key distribution would invalidate any comparison against the RACoherence numbers. The
error names both the path it tried and the `builtin` escape hatch.

The loader sniffs the first bytes and handles both encodings: the originals wrote raw
`int32` and read it back with `read(2)`, but a file named `zipf.txt` may well hold
whitespace-separated decimal keys, and parsing one as the other yields garbage keys rather
than an error. Text and binary versions of the same trace load to identical vectors.

`ZIPF_MAX_KEYS` caps how much is read into memory (default: the whole file). The originals
allocated `POPULATE_PER_THREAD * sizeof(int)` = 800 MB up front; cap it if that matters
and the trace wraps, which is what `NUM_ITERATIONS` effectively did.

`scripts/eval/hashmap.sh` drives the two benchmarks from separate traces: `KEY_TRACE` is a
directory (default `./keytrace`, relative to the repo root since the script cds there)
holding `ro` and `rw`. `RO_TRACE` and `RW_TRACE` override either path individually,
and `builtin` works in any of the three - `KEY_TRACE=builtin` for both, or e.g.
`RW_TRACE=builtin` to drive only the read-write run from the generator.

Each trace that will actually be passed to a benchmark is checked for existence,
readability and non-emptiness before the build, so a missing file costs a second rather
than a build plus an 18M-object load phase. Checking the directory alone would not catch
the common case of an empty or half-populated `keytrace/`.

A read-write run driven by `rw` still shifts write keys by `kWriteKeyShift` (1024)
relative to read keys, as the original did. If `rw` was generated to already separate
the read and write hotspots, set `kWriteKeyShift` to 0 in `hashmap_common.h` so the two
mechanisms do not compose into an offset you did not intend.

## 13. Where results go, and how big they get

`RACKOBJ_RESULT_DIR` is set by `setup_lean.sh`. `/mydata` is the artifact's CloudLab
convention and does not exist on every machine, so the default is now probed rather than
assumed: the first writable candidate among `/mydata`, `/data`, `/scratch`, `/mnt/data`,
otherwise `$HOME`. A candidate that exists but is not writable gets one quiet
`sudo mkdir` + `chown` attempt before being skipped. Override with `RESULT_DIR=/path/`.

The trailing slash is not optional: every eval script concatenates
`${RACKOBJ_RESULT_DIR}hashmap`, not `${RACKOBJ_RESULT_DIR}/hashmap`. `setup_lean.sh`
appends one if it is missing.

Result volume sizing: each thread writes one latency line per measured operation, in its
own file. At 42 threads over a 30-second window that is easily a gigabyte per run, and the
script warns when the chosen volume has under 20 GB free. `LATENCY_SAMPLE_EVERY=N` in the
benchmark environment records 1 sample in N:

```bash
LATENCY_SAMPLE_EVERY=10 ./scripts/eval/hashmap.sh
```

Percentiles stay valid under uniform subsampling - only the number of lines changes. The
`throughput-N` files report the operation count, not the sample count, so throughput is
unaffected by the stride.

## 14. Config yaml

`config/a.yaml` and friends need one substantive change and one you should be aware of.

### `mount_directory`

Point it at a path that exists. `config.cc` treats a missing key as fatal, and the value is
the redirect target for any `open()` that libmegalon captures - which is less inert than it
looks:

* `lib/glibc/*.cc` is in the unconditional source GLOB, so the interposers are in
  `libmegalon.so` even in a KV build (no `FILE_INTERFACE` guard).
* `lib/glibc/open.cc` defines `int open(const char*, int, ...)` at file scope *after*
  including `<fcntl.h>`. In C++ that definition inherits the C language linkage of the
  header's declaration, so it exports the plain symbol `open` and interposes
  process-wide. Verify on your build with:
  `nm -D --defined-only build/libmegalon.so | grep -w open` - a `T open` means it does.
* A captured `open()` goes to `rackobj_open()`, whose **first statement is
  `CHECK(SLOT_SIZE == 4096)`**. In the KV build `SLOT_SIZE` is 1024, so a captured open is
  an abort, not a redirect.

What saves the benchmarks is that `std::ifstream`/`std::ofstream` do not route through the
interposed symbol on x86-64 glibc, so the key-trace reads and the latency writes are
unaffected. I verified this directly: with a shim exporting `open`, a direct `::open()`
from a linked binary is captured while iostream file opens are not. That is also why
`kv_store.cc`'s `std::ofstream` latency files work in the stock artifact. The ports use
only iostreams and `access()` - no direct `open()` or `fopen()`.

Belt and braces: the generated config adds `/tmp`, `/home`, the repo root and
`$RACKOBJ_RESULT_DIR` to `excluded_directories`, so if anything in the process does call
`open()` on a path under those, `rackobj_open` hands it to the original syscall before
reaching the `SLOT_SIZE` check. Do not exclude `mount_directory` itself if you later build
with `FILE_INTERFACE` - that is the one path the file interface needs to capture.

**`key_space` and `slots`** are what the ports read as the bucket count -
`rackobj::GetConfigSize_t("key_space")`. `slots` should stay slightly above `key_space`
(the stock configs use `+1000`).

**Capacity is the thing to check on real CXL memory.** `slots * SLOT_SIZE` bytes of object
data plus per-slot metadata are allocated out of the NCR on `NUMA_MEM`
(`object_slot.h`: `byte_allocator.allocate(BlockId::kBlockSize * num_pages)`), and the SCR
is allocated there too. At the artifact's defaults that is `18M * 1KB = 18.4 GB` of NCR
plus `4 GB` of SCR, so the CXL device needs roughly 40 GB. If yours is smaller, lower
`NUM_OBJS` and `NCR_SIZE` together rather than only one.

`local_size` is allocated on **every** exec NUMA node, not once: with `NUM_NUMA 4` that is
`3 * 8 GB = 24 GB` of DRAM, before the ports' own graph arrays
(`GRAPH_ENTRIES * 8 KB` per logical node).

### The script no longer edits a.yaml

Every stock eval script does `sed -i` on `config/a.yaml`, so running one permanently
rewrites a checked-in file that `eval1.sh` through `eval8.sh` all share - and whichever ran
last decides what the next one starts from. `scripts/eval/hashmap.sh` now generates
`config/hashmap.generated.yaml` from environment variables instead and leaves `a.yaml`
alone:

```bash
MOUNT_DIR=/data/$USER NCR_SIZE=16GB NUM_OBJS_OVERRIDE=12000000 ./scripts/eval/hashmap.sh
```

Knobs: `MOUNT_DIR` (defaults to `$RACKOBJ_RESULT_DIR`), `NCR_SIZE`, `SCR_SIZE`,
`LOCAL_SIZE`, and `CONFIG_FILE` if you would rather point at a hand-written file. Before
each run it checks that `NCR_SIZE` can hold the requested slots and fails with the
arithmetic rather than dying inside the allocator.

## 15. Matching the original's memory footprint (16 GB CXL device)

The original table is `VECTOR_ENTRY_NUM * sizeof(GlobalEntry)` = 128M x 8 B = **1.00 GiB**
of shared CXL memory. One MEGALON object per bucket at `SLOT_SIZE = 1024` means the
footprint is `key_space * 1 KiB`, so:

```
key_space = 1048576   ->  1.00 GiB of object data   (exactly the original)
slots     = 1049576   ->  key_space + 1000 spare
```

That is the new default in `scripts/eval/hashmap.sh` (`NUM_OBJS=(1048576)`), replacing the
artifact's 18M, which would have been 17.2 GiB and would not fit a 16 GB device at all.

### The trade-off this forces

Byte footprint and bucket count cannot both match. With one bucket per object:

| | original | port at 1 GiB | port at 128M buckets |
|---|---|---|---|
| buckets | 128M | 1M | 128M |
| bytes per bucket | 8 | 1024 | 1024 |
| shared footprint | 1.00 GiB | 1.00 GiB | 128 GiB |

Matching bytes is the only option on a 16 GB device, so the port has 128x fewer buckets
than the original. Two consequences to state in any writeup:

* The trace keys were generated over a 128M key space and are folded with `% key_space`,
  so 128 original keys now collide per bucket. The zipfian *shape* survives, but the
  effective number of distinct objects shrinks by 128x. **Which direction that biases the
  result depends on the workload, and it is not one-sided:**

  - `hashmap-ro` has no writes, so nothing is ever invalidated. A smaller working set is
    purely favourable: more of it fits in the SCR, hit rate goes up. This is the case where
    the port flatters MEGALON.
  - `hashmap-rw` is the opposite. Folding raises the *per-object write rate* by up to 128x
    for everything outside the zipfian head. Objects that were read-mostly and stayed
    resident in several logical nodes' caches now get written, and each write invalidates
    every cached copy. So the port trades a better hit rate for more invalidation traffic
    and more seqlock read retries. At 10% writes the second effect can easily dominate,
    which would penalise the port rather than flatter it.

  Note the original had its own coarse-sharing artifact pulling the other way: its 128K
  `CXLSharedMutex` array put 1024 buckets under one lock, so a writer excluded readers of
  1023 unrelated buckets. The port has no false sharing at all (one bucket per object) but
  more *true* sharing (128 keys per bucket). These are different mechanisms with opposite
  signs, so the net cannot be predicted from the ratio alone - measure it.
* Per-operation bytes moved is 1 KiB rather than 8 B. `kAccessSize` in `hashmap_common.h`
  can be lowered to 8 (or 64 for cache-line granularity) to match the original's transfer
  size - it only needs to be >= `sizeof(BucketHeader)`. It does **not** change the
  footprint, which is `slots * SLOT_SIZE` regardless, and on a miss the coherence path
  still moves a whole slot (`c3.cc` defaults `src_length` to `SLOT_SIZE`).

### What else sits on the CXL device

Excluded from the 1.00 GiB comparison above, but real:

| region | size at 1048576 slots | source |
|---|---|---|
| object data | 1024 MiB | `page_data_`, NCR: `kBlockSize * num_pages` |
| `CacheNode` metadata | 64 MiB | `cache_slot_`, NCR: 48 B/slot rounded to a cache line |
| GCD directory | 112 B/slot per replica, ~448 MiB across 4 NUMA replicas | `GCDEntry` = `optional<size_t>` + `CNStatus_t[LOGICAL_NODE_NUM+1]` |
| SCR | `SCR_SIZE` | reserved up front |

The `GCDEntry` size scales with `LOGICAL_NODE_NUM`, and the NR hash map is replicated per
NUMA node, so the directory is the term that grows fastest with object count - at 11M
slots it alone is ~4.6 GiB across four replicas.

Defaults for a 16 GB device are now `NCR_SIZE=2GB`, `SCR_SIZE=2GB`. `check_capacity` prints
the full breakdown before each run and warns when the reserved regions exceed
`CXL_CAPACITY` (default `16GB`; set `NUM_NUMA_HINT` if your `NUM_NUMA` is not 4).

If you would rather stress capacity than match the original, roughly 11M objects is the
ceiling on 16 GB once the GCD replicas and a 2 GB SCR are accounted for - but then the
footprint comparison against the RACoherence run no longer holds.


## 16. Measuring invalidation instead of guessing

Both binaries now report MEGALON's own coherence counters over the measured window:

```
coherence: reads=... admits=... (0.0X/op) read_retries=... (0.0X/op) reads_that_retried=...
```

* **admits** (`GetAdmitCount`) - objects pulled into this logical node's cache because they
  were not resident: a first touch, or a refetch after eviction or invalidation. Admits per
  op is the closest available proxy for invalidation traffic.
* **read_retries** (`GetReadRetryCount`) - seqlock retries, i.e. a writer changed the object
  mid-read. This one is a direct measure of read/write interference and should be near zero
  for `hashmap-ro`.
* **reads_that_retried** (`GetReadRetryInvoc`) - how many reads retried at least once, so
  retries/retrying-read distinguishes "many objects lightly contended" from "a few objects
  hammered".

Implementation details that matter if you extend this:

* These are **thread-local** inside libmegalon (`lib::thread_local_meta.pt_stat`), so they
  are sampled inside each worker and summed in main. Reading them from the main thread
  returns that thread's zeros.
* They are cumulative from thread start, so each worker rebases at the start of the
  measured window and reports the delta - preheat admits (which are mostly cold-start
  misses, not invalidations) do not pollute the number.
* `rackobj.h` also declares `GetPageCacheMissCount()` and `GetPageCacheOperationCount()`,
  but nothing in `lib/` or `src/` defines them. Calling either fails at link time. Use the
  four above.

To separate the folding effect from everything else, run `hashmap-rw` twice at the same
`key_space` with the trace and with `builtin` keys, then again at a larger `key_space` if
the device allows: admits/op and retries/op moving together with object count is the
folding effect, and it is quantified rather than assumed.


## 17. "mkdir: cannot create directory '/mydata'"

Almost always a stale export rather than anything computing `/mydata` fresh.
`scripts/setup.sh` line 75 hardcodes

```
RESULT_DIR="/mydata/$USER/rackobj-benchmarks/benchmarks/results/"
```

and appends it to `~/.bashrc`. Once that has run, `$RACKOBJ_RESULT_DIR` points at `/mydata`
for every future shell, and every eval script (including `hashmap.sh`, via
`RESULT_ROOT=${RACKOBJ_RESULT_DIR}hashmap`) tries to mkdir under it.

`setup_lean.sh` used to make this worse: `add_export` skipped any variable already present
in `~/.bashrc`, so re-running it left the stale value in place while reporting success. It
now compares the value, rewrites the line when it differs (keeping
`~/.bashrc.megalon.bak`), and warns when the value live in the current shell disagrees with
what it just wrote - editing `~/.bashrc` does not change a running shell.

Check and fix by hand:

```bash
grep RACKOBJ_RESULT_DIR ~/.bashrc
echo "$RACKOBJ_RESULT_DIR"                      # the running shell may still differ
export RACKOBJ_RESULT_DIR=$HOME/rackobj-benchmarks/benchmarks/results/
```

`scripts/eval/hashmap.sh` now validates before doing any work: the variable must be set,
must end in `/`, must be creatable, and must be writable - with the offending path and the
`~/.bashrc` hint in the error, instead of a bare mkdir failure partway through a run.

Separately, `config/*.yaml` all carry `mount_directory: /mydata`, but `hashmap.sh`
generates its own config and never reads those (section 14).


### One canonical result path

`setup_lean.sh` builds `<root>/rackobj-benchmarks/benchmarks/results/`, matching what
`setup.sh` writes, and every message that suggests a value by hand now uses the same shape.
Nothing parses the path - the only requirements are that it exists, is writable, and ends
in `/` - but keeping one shape matters in practice: exporting a different path by hand and
later re-running `setup_lean.sh` gets the export rewritten to the canonical one, splitting
results across two directories with no warning that it happened.

## 18. Segfault after "C3 created with entries"

That log line is printed *before* `new C3PO(...)` in `C3POHandle::CreateOrMap`, and the
first thing the `C3PO` constructor does is build the GCD:

```
C3PO::C3PO(...) : gcd_(GcdHandle::CreateOrMap(...))
  -> GlobalCacheDirectoryNr::GlobalCacheDirectoryNr(num_entries, LOGICAL_NODE_NUM, base_addr)
     -> NrFfi::create_node_replicated_numa(num_entries, num_replicas, base_addr,
                                           SLOT_SIZE, NUMA_MEM, NUM_NUMA)
```

So a crash with no further output is inside the Rust NR library, on the very first call
into it. The two ways that happens:

1. **The C++ and Rust constants disagree.** Rust reads `LOGICAL_NODE_NUM`, `NUM_EXEC`,
   `NUMA_MEM` and `KEY_SIZE` from its own `ffi/constants.rs`, compiled into
   `libnr_hashmap.a`; C++ passes `NUMA_MEM` and `NUM_NUMA` as arguments. Neither a
   mismatch in the compiled-in values nor a stale archive is a compile or link error - it
   is a wrong `BlockId`/`GCDEntry` layout, or an allocation on a NUMA node that does not
   exist. `KEY_SIZE` is the worst of these: 24 selects a three-field `BlockId`, anything
   else selects the padded variant, and the two sides then disagree about the size of every
   directory key.
2. **`NUM_NUMA` does not match the machine.** `setup_logical_node.sh` auto-detects it, but
   only when it is re-run; the checked-in default is 4. Passing a `NUM_NUMA` larger than
   the machine has sends Rust at a nonexistent node.

`scripts/check_consistency.sh` checks all of it - the two constants files against each
other, `NUM_EXEC == NUM_NUMA-1`, `NUM_NUMA` and `NUMA_MEM` against the live topology
(including whether `NUMA_MEM` is CPU-less, as a CXL node should be), whether
`libnr_hashmap.a` predates `constants.rs`, whether `libmegalon.so` predates either, and it
prints the stashed stamp next to the current values. It ends with the exact gdb line for a
backtrace.

Note the log line `Initializing cache with num element ... on node 2` reports the value of
`NUMA_MEM` actually compiled in, which is a quick way to confirm what the binary believes.

## 19. Real CXL: the NR affinity switch assumes NUMA_MEM has CPUs

When the constants all agree and it still segfaults immediately after
`C3 created with entries`, this is why.

`ffi/ffi_nr_hashmap.rs` places NUMA memory by moving the *calling thread* onto the target
node's CPUs and relying on first touch:

```rust
for ncpu in MACHINE_TOPOLOGY.cpus_on_node(rid_numa) { cpu_set.set(ncpu.cpu as usize)... }
nix::sched::sched_setaffinity(Pid::from_raw(0), &cpu_set)
    .expect("Can't change thread affinity");
```

and `NodeReplicated::with_log_size_and_struct_and_base_addr_numa` allocates the 64 MB log
inside `affinity_mngr.switch(usize::MAX)`, which maps to `NUMA_MEM`:

```rust
let rid_numa = if rid == usize::MAX { NUMA_MEM } else { NUMA_EXEC[rid % NUM_EXEC] };
```

`cpus_on_node()` is `self.data.iter().filter(|t| t.socket == node)`. On the artifact's
intended setup, "CXL" is an emulated second DRAM node that has CPUs, so this works. **A
real CXL Type 3 device is a memory-only NUMA node with no CPUs**, so the filter returns
empty, `sched_setaffinity` is called with an empty mask, fails `EINVAL`, and `.expect()`
panics - across an `extern "C"` boundary, which is UB and typically shows up as SIGSEGV
rather than a Rust panic message. That is exactly the observed crash: first call into the
NR library, no further output.

The fix in `third-party/nr_rust/ffi/ffi_nr_hashmap.rs` (vendored, not a submodule, so it
patches cleanly): when the target node has no CPUs, bind the allocation policy instead of
migrating the thread.

```rust
let target_cpus = MACHINE_TOPOLOGY.cpus_on_node(rid_numa);
if target_cpus.is_empty() {
    mempolicy_bind(rid_numa);       // set_mempolicy(MPOL_BIND, {node})
    return CPULESS_SENTINEL;
}
```

with `AffinityChange::Revert(CPULESS_SENTINEL)` calling `set_mempolicy(MPOL_DEFAULT)`
rather than pinning the thread to a single core. `MPOL_BIND` makes the pages the following
allocation faults in come from that node, which is the placement the affinity switch was
after - and it is what you want anyway, since no thread can run on a CXL node.

Rebuild the NR library and relink after applying:

```bash
rm -f third-party/nr_rust/ffi/target/release/libnr_hashmap.a \
      third-party/nr_rust/prebuilt/libnr_hashmap.a
./scripts/build_lean.sh
```

`check_consistency.sh` now reports whether `NUMA_MEM` is CPU-less and whether the fallback
is present in the tree. Note this was backwards in the first version of that script: it
called a CPU-less `NUMA_MEM` correct, when for the stock code it is precisely the thing
that breaks.

**This patch is not compile-tested** - there is no Rust toolchain in the environment it was
written in. If `cargo` rejects it, the shape to keep is: check `is_empty()`, bind the
policy, use a sentinel so `Revert` does not pin the thread to one core.

Worth checking whether other parts of the artifact make the same assumption; anything that
pins a thread to `NUMA_MEM`'s CPUs will have the same problem. `RidToNumaNode()` on the C++
side only ever returns exec nodes, so the worker pinning is fine.


## 20. The graph array is DRAM, and is now checked

Correct - the pointer-chase array must be node-local DRAM, never `NUMA_MEM`. The original
`malloc`'d it per process on the exec node; putting it on the CXL device would measure CXL
latency in the half of the workload whose entire purpose is to be the local contrast.

The mechanism was already right: `InitForNode` runs on a thread that has called
`rackobj::Register(rid)`, so it is pinned by `RidToNumaNode()`, and `getcpu()` then reports
an exec node. `GetExecNodes()` in `src/common/helper.cc` skips `NUMA_MEM` explicitly, and
the run log confirms it - `logical thread N mapped to (rid, 0|1)` with `NUMA_MEM=2`.

It is now an assertion rather than an assumption:

```cpp
CHECK(static_cast<int>(numa_node) != NUMA_MEM)
    << "graph array would be allocated on NUMA_MEM (" << NUMA_MEM << "), the CXL node. ...";
```

and the placement is logged per node.

### Free-memory pre-check

`numa_alloc_onnode` succeeds lazily. Under `numa_set_strict(1)` an over-commit does not
return null - the process is killed during first touch, which looks like an unexplained
death rather than an allocation error. `InitForNode` now reads
`numa_node_size64(node, &free)` first and fails with a message naming the shortfall.

This matters more than it used to because the total scales with `LOGICAL_NODE_NUM`:

```
total DRAM = LOGICAL_NODE_NUM x GRAPH_ENTRIES x 8 KB
```

At the old hardcoded `GRAPH_ENTRIES=65536` that is 512 MB per logical node - 1.5 GB at
`LOGICAL_NODE_NUM=3`, but **4 GB at `LOGICAL_NODE_NUM=8`**, spread over however many exec
nodes there are (2, in the current setup), on top of `local_size` per exec node. That is a
plausible contributor to a crash that appeared only after `LOGICAL_NODE_NUM` went from 3
to 8.

`GRAPH_ENTRIES` is now an environment variable in `scripts/eval/hashmap.sh`, defaulting to
8192 (512 MB total at `LOGICAL_NODE_NUM=8`), and `check_capacity` prints the total before
each run. `GRAPH_ENTRIES=0` disables the traversal entirely, which is the first thing to
try when bisecting a crash.

## 21. A configuration ladder

The crash in `ReadFromLocal` happens on a path that should be unreachable when
`PARTITIONED_NODE` is off, and it only appears once more than one logical node is active.
`scripts/setup.sh` line 100 shows what upstream actually tests:

```
./setup_logical_node.sh 0 3 24     # NUMA_MEM=0, LOGICAL_NODE_NUM=3, KEY_SIZE=24
```

with `NUM_NUMA=4` (so 3 exec nodes, one logical node per exec node) and the README calling
`NUMA_MEM` the node "designated for CXL memory **simulation**" - a DRAM node, with CPUs,
slowed down via the uncore. Every deviation from that is untested ground, and the current
setup deviates on three axes at once: real CPU-less CXL, 2 exec nodes, and 8 logical nodes.

Work down this ladder until something runs, using
`./scripts/try_config.sh <NUMA_MEM> <LOGICAL_NODE_NUM> [threads]`, which reconfigures,
rebuilds clean (forcing the NR rebuild), checks consistency, then runs **kv-store** and
**hashmap-ro** at the same settings. kv-store is the control: if it fails too, the port is
not implicated.

| rung | command | what it tests |
|---|---|---|
| 1 | `./scripts/try_config.sh 2 3 8` | real CXL, upstream's logical-node count. Closest to tested; 3 logical nodes over 2 exec nodes. |
| 2 | `./scripts/try_config.sh 2 2 8` | one logical node per exec node - the simplest multi-node mapping. |
| 3 | `./scripts/try_config.sh 2 1 8` | single logical node: no cross-node coherence at all. If this passes and rung 2 fails, the fault is in the multi-logical-node path, not in thread count or the port. |
| 4 | emulated CXL (below) | the artifact exactly as designed, ignoring the real CXL device. |

Rung 3 is not a useful measurement - with one logical node MEGALON has nothing to keep
coherent - but it is a working end-to-end baseline that proves the port, the trace loader
and the graph array are sound, and it isolates the failure to the coherence path.

### Rung 4: fall back to emulation

`setup_logical_node.sh` derives `NUM_NUMA` from `lscpu`, which counts the CPU-less CXL node
and then hands it to `RidToNumaNode()` as an exec node candidate. To run the artifact as
designed - ignoring the CXL device entirely and emulating it with a DRAM node - edit the
constants by hand after running the script:

```
src/common/constants.h:            NUMA_MEM 0     NUM_NUMA 2      LOGICAL_NODE_NUM 2 or 3
third-party/nr_rust/ffi/constants.rs:  NUMA_MEM = 0;  NUM_EXEC = 1;   LOGICAL_NODE_NUM = same
```

That makes node 0 the "CXL" node (with CPUs, so the NR affinity path works unpatched) and
node 1 the only exec node, with the logical nodes colocated on it. Then run with
`UNCORE_MODE=slow`, which is what the emulation is for. The numbers are not real-CXL
numbers, but everything is on the path upstream tests, so it distinguishes "the port is
broken" from "this artifact has not been run on real CXL".

Re-run `./scripts/check_consistency.sh` after any hand edit - `NUM_EXEC` must equal
`NUM_NUMA - 1`, and the NR archive must be rebuilt, or the mismatch is a segfault rather
than an error.

## 22. The artifact's benchmarks require NUMA_MEM == 0

`kv-store` does not crash on real CXL - it refuses to start:

```
F kv_store.cc:335] Check failed: numa_node_local == (thread_idx % num_exec_numa) + 1
                   not running on target node: 0
```

`benchmarks/kv_store.cc:335`, `page_cache.cc:335` and `ycsb_benchmark.cc` all assert that a
thread lands on node `(thread_idx % num_exec_numa) + 1`. That formula assumes the exec nodes
are `1..NUM_NUMA-1`, i.e. **that `NUMA_MEM` is node 0**.

The library itself is fine: `GetExecNodes()` in `src/common/helper.cc` builds the exec list
by skipping `NUMA_MEM` wherever it is, and `RidToNumaNode()` indexes into that list. With
`NUMA_MEM=2` on a 3-node machine the exec nodes are `{0, 1}`, `Register(0)` correctly pins
to node 0, and then the benchmark's `+ 1` assertion rejects it. The benchmarks were not
updated when the library gained support for an arbitrary `NUMA_MEM`.

Consequences:

* **`kv-store` cannot act as a control on this machine.** It aborts before reaching any
  coherence code, so it says nothing about the `ReadFromLocal` crash.
* The ported hashmap benchmarks deliberately do not carry that assertion (noted in section
  5 as an open item), which is why they run further and reach the real failure. Adding the
  same `CHECK` would have converted the segfault into a clean abort at thread start - a
  better failure, but the same underlying incompatibility.
* Any upstream eval script is equally unusable with `NUMA_MEM != 0`.

`check_consistency.sh` now fails loudly on `NUMA_MEM != 0` and explains why.

### What this leaves

`NUMA_MEM` must be 0 for the artifact's own code to run, but node 0 on this machine is a
CPU-bearing DRAM node, and the real CXL device is node 2. Those two facts cannot both be
satisfied - which makes rung 4 of the ladder (emulation) the only configuration where the
whole artifact, benchmarks included, is on tested ground:

```
src/common/constants.h:               NUMA_MEM 0    NUM_NUMA 2   LOGICAL_NODE_NUM 2
third-party/nr_rust/ffi/constants.rs: NUMA_MEM = 0; NUM_EXEC = 1; LOGICAL_NODE_NUM = 2;
```

Node 0 becomes the emulated CXL node (it has CPUs, so the NR affinity path works even
without the patch in section 19), node 1 is the sole exec node, and `UNCORE_MODE=slow`
supplies the latency. The real CXL device is unused. Rebuild fully afterwards - both
constants files changed, so the NR archive must be rebuilt too.

Running on the real device needs two upstream fixes: the `+ 1` assertion in the benchmarks,
and whatever makes `ReadFromLocal` reachable with `PARTITIONED_NODE` off. Both are worth
reporting together, since the second is only observable once you work around the first.


## 23. NUM_NUMA must exclude the CPU-less node

With `NUMA_MEM=0` the previous failure is replaced by:

```
F helper.cc:43] Check failed: numa_node == (uint32_t)target_node not running on target node: 1
```

`setup_logical_node.sh` derives `NUM_NUMA` from `lscpu`, which counts **every** NUMA node,
including the CPU-less CXL node. `GetExecNodes()` then walks candidates 0,1,2,... skipping
only `NUMA_MEM`:

```
NUM_NUMA=3, NUMA_MEM=0  ->  exec nodes {1, 2}
```

Node 2 is the CXL device. `RidToNumaNode(1)` returns it, `pinThreadtoNumaNode(2)` builds an
empty cpuset, `pthread_setaffinity_np` leaves the thread on node 1, and the `CHECK` two
lines later aborts. Same root cause as section 19, on the C++ side this time: the artifact
assumes every node except `NUMA_MEM` can run threads.

The fix is to make the CXL node invisible by lowering `NUM_NUMA`:

```
NUM_NUMA=2, NUMA_MEM=0  ->  exec nodes {1}
```

`setup_lean.sh` now takes it as an optional 4th argument, applying it to `NUM_NUMA` in
`constants.h` and `NUM_EXEC = NUM_NUMA-1` in `constants.rs`, then listing the implied exec
nodes and warning about any that have no CPUs:

```bash
./scripts/setup_lean.sh 0 2 24 2      # NUMA_MEM=0, 2 logical nodes, KEY_SIZE=24, NUM_NUMA=2
./scripts/build_lean.sh --clean
```

`check_consistency.sh` performs the same derivation and checks each exec node's `cpulist`.

Note what this configuration is: node 0 is the emulated CXL node, node 1 is the sole exec
node with both logical nodes colocated on it, and the real CXL device is **not used at
all**. That is rung 4 of the ladder. `UNCORE_MODE=slow` supplies the emulated latency.

The three separate places that assume "every non-`NUMA_MEM` node has CPUs" - the Rust
affinity switch (section 19), the benchmarks' `+ 1` exec-node formula (section 22), and
`pinThreadtoNumaNode` here - are one report to the authors: the artifact cannot currently
target a memory-only NUMA node, which is what a real CXL Type 3 device presents as.

## 24. Working configuration (emulated CXL)

Confirmed running: `kv-store` and `hashmap-ro`, 2 threads.

```bash
./scripts/setup_lean.sh 0 2 24 2     # NUMA_MEM=0, LOGICAL_NODE_NUM=2, KEY_SIZE=24, NUM_NUMA=2
./scripts/build_lean.sh --clean
UNCORE_MODE=slow ./scripts/eval/hashmap.sh
```

Topology: node 0 is the emulated CXL node (uncore-slowed), node 1 is the sole exec node
with both logical nodes colocated on it, and the physical CXL device at node 2 is unused.

### Ramping up, in this order

Change one thing at a time; each step re-enables something that has not run yet.

1. **Threads.** 2 -> 4 -> 8 -> the number of CPUs on node 1. At 2 threads both logical
   nodes are active, so cross-node coherence is already exercised; scaling from here tests
   contention, not new code paths. `check_thread_capacity` in `hashmap.sh` now prints the
   exec CPU count and warns when `THREAD_COUNTS` exceeds it - with one exec node it is
   easy to oversubscribe, and the resulting latency looks like a result rather than a
   configuration mistake. `THREAD_COUNTS=(32)` is very likely too high here.
2. **Graph traversal.** `GRAPH_ENTRIES=8192` then higher. This is the first thing that
   allocates node-local DRAM through `numa_alloc_onnode` under `numa_set_strict(1)`.
3. **Key trace.** Point `KEY_TRACE` at the real traces instead of `builtin`. Watch the
   `loaded N keys from ... (text|binary)` line - it reports which format was detected.
4. **hashmap-rw.** Writes engage the seqlock and invalidation paths that a read-only run
   never touches. Check `read_retries` in the coherence line: near zero on `hashmap-ro`,
   non-zero here.
5. **Object count.** `NUM_OBJS` back up if you want a larger working set, watching
   `check_capacity`'s footprint report against `NCR_SIZE`.

### What these numbers are and are not

This is the artifact's emulated-CXL configuration: a DRAM node with its uncore clocked
down, which is what `UNCORE_MODE=slow` is for and what upstream's own results use. They are
directly comparable to the paper. They are **not** measurements on the CXL device in this
machine - that remains blocked on the three CPU-less-node assumptions in sections 19, 22
and 23.

One further caveat specific to this config: with `NUM_EXEC=1`, both logical nodes live on
the same physical node, so "remote" coherence traffic between them never crosses a real
NUMA boundary. Upstream's setup puts each logical node on its own exec node. Inter-node
costs are therefore understated relative to the paper's topology, independently of the
uncore emulation.

## 25. Result size

A full run writes one latency line per measured operation per thread. At 32 threads over a
30 s window that is gigabytes, and the eval script was making it worse in a second way.

Three changes:

* **`LATENCY_SAMPLE_EVERY` now defaults to 100 in `scripts/eval/hashmap.sh`** (1 in 100
  operations sampled), and is passed *explicitly on the sudo line* alongside
  `RACKOBJ_CONFIG`. Exporting it is not enough: `sudo` resets the environment under the
  usual `env_reset` sudoers default, so an exported variable never reaches the binary.
  That is why the knob added in section 13 had no effect here.
* **Results are moved, not copied.** `src_dir` (`${RACKOBJ_RESULT_DIR}hashmap-ro/...`) and
  `dst_dir` (`${RACKOBJ_RESULT_DIR}hashmap/...`) are both under `RACKOBJ_RESULT_DIR`, so
  the `cp -r` inherited from `sample.sh` doubled peak usage. Now `mv`, which is also
  instant on the same filesystem.
* **A budget line before the run** reports the sampling stride and free space, and warns
  under 2 GiB.

Sampling does not affect what you can compute: percentiles are unbiased under uniform
subsampling, and `throughput-N` records the operation count rather than the sample count
(section 13). Only the confidence interval on the tail percentiles widens - at 1 in 100 of
tens of millions of operations, p99.9 still rests on thousands of samples.

To clean up what is already there:

```bash
du -sh "$RACKOBJ_RESULT_DIR"*                     # see what is where
rm -rf "${RACKOBJ_RESULT_DIR}hashmap-ro" "${RACKOBJ_RESULT_DIR}hashmap-rw-"*
```

Those are the staging directories the script writes into before moving results to
`${RACKOBJ_RESULT_DIR}hashmap/`. A crashed or interrupted run leaves them behind, and the
script only removes the one it is about to use.

If space is very tight, `LATENCY_SAMPLE_EVERY=1000` still gives sound percentiles, or
`RESULT_DIR=` (empty first argument to the binaries) skips latency files entirely and
reports only throughput.

## 26. Workaround for the ReadFromLocal crash on real CXL

The minimal repro is now sharp. Same logical topology in both cases - 2 logical nodes,
1 exec node, 2 threads, same key space, same binaries:

| `setup_lean.sh` args | NUMA_MEM | exec nodes | result |
|---|---|---|---|
| `0 2 24 2` | 0 (DRAM, emulated CXL) | {1} | runs to completion |
| `2 2 24 2` | 2 (real CXL, CPU-less) | {0} | SIGSEGV in `ReadFromLocal` |

Only `NUMA_MEM` differs. Thread count and logical-node count are not the variable - an
earlier reading of the 1-thread-vs-8-thread evidence suggested they were, and that was
wrong; 2 threads is enough to crash when `NUMA_MEM` is the real device.

### The guard

`selectCacheNode()` routes a read to `ReadFromLocal` when the GCD reports the object
resident on the current logical node. With `PARTITIONED_NODE` off that state is
unreachable by construction:

* `cache_lcl_ptr_[i]` is only allocated inside `#ifdef PARTITIONED_NODE`
  (`lib/shm_obj_handle.cc`);
* every `MoveToLocalReadOnly()` call site in `src/core/c3.cc` is inside
  `#ifdef PARTITIONED_NODE`, and additionally requires `partition_ratio > 0` (the config
  says `0.0`);
* `rackobj::Register()` never sets `thread_local_meta.local_cache_ptr_` - only
  `RegisterLocalMem()` does, called solely from `lib/glibc/open.cc` on the file path.

So the branch is guarded out when `PARTITIONED_NODE` is undefined: fall back to the CXL
copy if the entry has one, otherwise report a miss and let the normal admit path
re-establish it. `PARTITIONED_NODE` builds are untouched.

Building with `-DHASHMAP_TRAP_LOCAL_ENTRY` converts the same spot into a `LOG(FATAL)` that
prints the key, the logical node, `cn_idx` and whether a CXL copy exists - use that to
characterise the bad entry for the upstream report before switching to the fallback.

### What the workaround does and does not buy

It should let a real-CXL run complete, and since local replication never happens in this
build, routing those reads to CXL is what the code would have done anyway had the entry
been correct. It does **not** explain why the entry is wrong. The underlying defect - a GCD
entry claiming local residency in a build that has no local caches, dependent on whether
`NUMA_MEM` is a real memory-only node - is still unexplained and still worth reporting.

Treat numbers from a patched run as provisional until the authors confirm the entry is
merely spurious rather than a symptom of wider GCD corruption. If it is corruption, other
fields may be wrong too and the throughput would be meaningless.

Untested here: no CXL hardware in the environment this was written in. The `#ifdef`
structure was compile-checked in isolation both ways.

## 27. Root cause: the CXL slot is indexed by NUMA node id

The `ReadFromLocal` crash is an index-space confusion, not memory corruption, and it has a
one-line-per-site fix.

`GCDEntry::cn_array_` has `LOGICAL_NODE_NUM + 1` slots. Per the comment on its definition,
**index 0 is the CXL copy and indices 1..N are the logical nodes**, which is how reads
treat it:

```cpp
ExistOnLogicalNode(entry, nid) { return ExistOnArrayIdx(entry, nid + 1); }
```

But the CXL slot is addressed by *NUMA node id* on both sides:

```cpp
// read  - src/core/c3.h / c3.cc
ExistOnCxl(entry)          { return ExistOnArrayIdx(entry, cxl_nid_); }   // cxl_nid_ = NUMA_MEM
CacheNodeIndexOnCxl(entry) { return CacheNodeIndexOnArrayIdx(entry, cxl_nid_); }

// write - lib/shm_obj_handle.cc, six sites
c3po_->Gcd()->CheckAndInsert(block_id, new_index, shared_cache_node_, ...);  // = NUMA_MEM
```

`cxl_nid_` comes from `C3POHandle::CreateOrMap(..., NUMA_MEM, ...)` and
`shared_cache_node_` is the same value. Reads and writes agree with each other, so the
scheme is self-consistent - and correct **only when `NUMA_MEM == 0`**, where the CXL slot
lands on index 0 as the layout intends.

With `NUMA_MEM = 2`:

```
CXL copy stored at cn_array_[2]
logical node 1   read from cn_array_[1 + 1] = cn_array_[2]     <- same slot
```

A thread on logical node 1 finds the CXL entry, concludes the object is resident locally,
and `CopyToUserBufferLocal` does
`reinterpret_cast<LocalCacheNode*>(rh.cn_index.value())` on what is actually a CXL slot
*index* - a small integer - and dereferences it. SIGSEGV.

Every observation fits:

| observation | explanation |
|---|---|
| `NUMA_MEM=0` works at any thread count | CXL slot is 0; no logical node maps there |
| `NUMA_MEM=2`, 1 thread, works | only logical node 0 active -> reads slot 1, no collision |
| `NUMA_MEM=2`, 2+ threads, crashes | logical node 1 reads slot 2, the CXL slot |
| the faulting thread was the one mapped to `(1, 0)` | exactly the colliding logical node |
| `LOGICAL_NODE_NUM` 3 or 8 made no difference | collision depends on `NUMA_MEM`, not on N |

Worse than a crash: with `NUMA_MEM > LOGICAL_NODE_NUM` the index is out of bounds on an
array of `LOGICAL_NODE_NUM + 1`, so it is a silent out-of-bounds read rather than a
collision.

### The fix

Introduce `C3POHandle::kCxlArrayIdx = 0` and use it wherever `cn_array_` is indexed for the
CXL copy, leaving `cxl_nid_` for its genuine NUMA-node uses (`SharedMetadata`,
`WriteMetadataManagerHandle`, and skipping the memory node when allocating local regions):

* `src/core/c3.h` - `ExistOnCxl`
* `src/core/c3.cc` - `CacheNodeIndexOnCxl`, and the `i != cxl_nid_` skip in
  `FindRemoteCacheNodeIndex`, which was excluding the wrong slot for the same reason
* `lib/shm_obj_handle.cc` - six `CheckAndInsert(..., shared_cache_node_, ...)` sites

This is a behavioural no-op when `NUMA_MEM == 0` - which is every configuration upstream
tests, and why the bug has gone unnoticed - and it makes any `NUMA_MEM` correct. It
supersedes the `selectCacheNode` guard from section 26; that workaround has been reverted.

**Untested here** - no CXL hardware in this environment. Rebuild and re-run
`./scripts/setup_lean.sh 2 2 24 2` to confirm. Worth sending upstream: it is a small,
self-contained fix, and it is the difference between the artifact supporting a real CXL
device and only supporting an emulated one at node 0.

## 28. Root-owned result files

The benchmarks run under `sudo`, so every latency and throughput file - and every directory
the binary creates, such as the per-thread-count `32/` - belongs to root. Unlinking an entry
requires write permission on its *parent* directory, not on the file, so a subsequent
unprivileged `rm -rf` fails on anything the binary made, even under a user-owned
`$RACKOBJ_RESULT_DIR`.

Two changes in `scripts/eval/hashmap.sh`:

* the cleanup of `${RESULT_ROOT}/${variant}` at the start of each variant now uses
  `sudo rm -rf`;
* after each result set is moved into place, `sudo chown -R "$(id -u):$(id -g)"` hands it
  back, so `avg_lat.py`, your own scripts, and plain `rm` all work afterwards.

To clear what is already there:

```bash
sudo rm -rf "${RACKOBJ_RESULT_DIR}hashmap"
# or keep it and take ownership:
sudo chown -R "$(id -u):$(id -g)" "$RACKOBJ_RESULT_DIR"
```

Root ownership does not block reading - the files are mode 644 - so analysis of an existing
result set works without this. It only bites on deletion and on rerunning, which is why it
surfaced now rather than on the first successful run.

Worth noting for anything you script yourself: the staging directories
(`${RACKOBJ_RESULT_DIR}hashmap-ro/...`) have the same problem, which is why the script
already used `sudo rm -rf` there. A crashed run leaves those behind fully root-owned.

## 29. hashmap-rw hang: a blocking lock where a try-lock is assumed

Backtrace of the hung single-writer run (1 thread, write_ratio 1.0, so no contention from
the benchmark itself):

```
Thread 3 (the writer)          Thread 2 (WriteMetadataManager)
  RackOBJKV::Put                 WriteMetadataManager::work_fn
  SharedMemoryObjectHandle::Put  WriteMetadataManager::SampleReclaim
  SwitchRW                       SharedMetadata::SampleVictim
  SharedMetadata::SampleVictim   write_seqlock_only     <- spinning
  write_seqlock_only  <- spinning
Thread 1 (main): std::thread::join, waiting on thread 3
```

`SampleVictim` is written as a try-lock:

```cpp
if (wmeta->WLockOnly()) return idx;   // locking succeeded
...
return std::nullopt;                  // all locking attempts failed
```

but `write_seqlock_only()` (`src/core/seqcount.cc`) **blocks**:

```cpp
while (true) {
    if (curr & FREE_BIT) return false;        // only failure path
    if ((curr & LOCK_BIT) == 0) { ...CAS...; return true; }
    else cpu_relax();                         // spins forever on a held slot
}
```

It returns false only when `FREE_BIT` is set. On a slot another thread holds - or one this
thread already holds - it spins indefinitely, so "all locking attempts failed" is
unreachable and reclamation blocks instead of moving to the next candidate.

Both the critical-path reclamation (`SwitchRW`/`Admit`) and the background
`WriteMetadataManager` call `SampleVictim`, both take wmeta write locks, and neither
imposes an ordering. `SampleVictim` picks 5 random slots out of ~1.17M, so a collision is
rare per call - which is why ~90,000 writes complete first and throughput decays
(45k -> 35k -> 10k -> 0) rather than stopping dead.

Read-only workloads never allocate write metadata, so `hashmap-ro` is unaffected.

### Fix

Add a genuine try-lock and use it where try semantics are assumed:

* `src/core/seqcount.{h,cc}` - `try_write_seqlock_only()`: one CAS, returns false on a held
  or freed slot, never spins.
* `src/core/write_meta.{h,cc}` - `WriteMetadata::TryWLockOnly()`, and `SampleVictim` now
  calls it.

`write_seqlock_only()` is left alone for callers that genuinely want to block.
`flush_manager.cc:132` and `evict_manager.cc:95` use `WLockOnly()` in the same try-shaped
way and would want the same treatment - both are in managers that are currently commented
out for logical nodes, so they are not reachable here.

Verified in isolation: try succeeds on a free slot, returns false (rather than spinning) on
a held slot and on a freed slot, and 8 threads racing a single slot produce exactly one
winner with no hang. **Not verified against the real workload** - no CXL hardware here.
Rebuild and re-run the single-writer case first:

```bash
./scripts/build_lean.sh --clean
sudo RACKOBJ_CONFIG=config/hashmap.generated.yaml ./build/benchmarks/hashmap-rw \
    "$RACKOBJ_RESULT_DIR" 1 1.0 0.99 5 10 0 0 builtin
```

Two corrections to earlier analysis in these notes: the `WriteMetadataManager` *is* started
(thread 2 above is its worker), contrary to section 28, and `logical_scr_size` does not
size the wmeta pool - `InitSharedMetadata` takes `min(logical_scr_size/4,
num_slots*100/WMETA_WATERMARK)`, and the second term (~1.17M) binds at every size tested,
so the scaling experiment could not have shown anything.

## 30. Keeping the reclaimer dormant: slot headroom

The try-lock fix (section 29) removes the deadlock but exposes the next layer: with
`SampleVictim` now able to fail, the unbounded caller loops in `Admit`/`SwitchRW` spin on
`continue` instead. Deadlock becomes livelock - visible as 1.62M ops/s decaying to 0 rather
than a slow crawl to 0.

The real lever is not to enter reclamation at all. The arithmetic:

```
wmeta_pool = min(logical_scr_size/4, slots * 100 / WMETA_WATERMARK)
threshold  = wmeta_pool * WMETA_WATERMARK / 100
```

With `WMETA_WATERMARK = 90` and the second term binding (it does at any realistic
`logical_scr_size`), those cancel: **`threshold ~= slots`**. The load phase allocates one
wmeta per object, so the number of further allocations before `WmetaOverThreshold()` turns
positive is exactly:

```
headroom = slots - key_space
```

The stock `slots = key_space + 1000` therefore leaves ~1023 allocations of margin,
regardless of scale. That is why the emulated run reported `reclaim count: 0, allocate
count: 0` and sailed through 12.7M writes - it never crossed the line - and why anything
that nudges it over lands straight in the reclamation path, which then deadlocks or
livelocks.

`SLOT_HEADROOM_PCT` (default 25) in `scripts/eval/hashmap.sh` sizes `slots` as
`key_space * (1 + pct/100)`, and `check_capacity` prints the resulting headroom. At
`key_space = 1048576` that is 262,144 spare allocations instead of 1,023, at a cost of
1.28 GiB of NCR object data instead of 1.02 GiB.

Being explicit about what this is: a way to stay out of a broken code path, not a fix for
it. A run configured this way is only valid while `reclaim count: 0` - check the epilogue:

```
seqlock alloc ratio: (1048576|1166222) = 89.9122%, reclaim count: 0, allocate count: 0
```

If `reclaim count` is non-zero, reclamation ran and the numbers include whatever that path
does under contention. If the run completes with it at zero, the write path never needed
reclamation and the throughput is meaningful.

The deeper issues stay open for upstream, and they compound:

1. `SampleVictim` used a blocking lock where the caller assumes a try-lock (fixed in
   section 29).
2. The callers of `SampleVictim` retry without bound or backoff, so a failure to find a
   victim spins forever rather than propagating an error.
3. The default configuration sits ~1023 allocations below the reclaim threshold, so the
   entire reclamation path is close to untested by the artifact's own experiments.

## 31. The wmeta leak: freeing a slot you do not hold locked

The epilogue from the real-CXL run is the whole diagnosis:

```
WriteMetadataManager for node 2 on node 0 joined, total reclaim count: 311756
seqlock alloc ratio: (1400956|1456355) = 96.1961%, reclaim count: 498, allocate count: 60420
```

The manager claims **311,756** reclaims. The shared counter records **498** actual frees.
`RecycleWmeta` increments `reclaim_count_` and decrements `allocated_slot_num_` only when
`FreeLock()` succeeds - and `free_seqlock_with_lock()` returns false unless `LOCK_BIT` is
set, i.e. unless *this thread* holds that slot locked:

```cpp
if (curr & FREE_BIT) return true;
if (!(curr & LOCK_BIT)) return false;   // freeing a slot we do not hold: fails
```

Both reclamation paths lock one slot and free a different one:

```cpp
wmeta_idx = SampleVictim(...);                     // locks THIS slot
cur = GetWmeta(wmeta_idx.value());
block_id = cur->GetBlockID();
idx = Gcd()->SwitchToReadOnly(block_id);           // returns the GCD entry's index
RecycleWmeta(idx.value());                         // frees THAT one - may differ
wmeta_over_thres--;                                // counted as success regardless
```

When they differ, three things happen at once: the free fails, so the allocation is never
released; the sampled slot stays **locked forever**, because the success branch never
unlocks it; and the caller counts a reclaim that did not happen. On the critical path it is
worse - `new_wmeta_index_optional` is overwritten by `SwitchToReadOnly`, so the locked index
is not merely unused but lost.

That is a compounding leak, and it matches the observations exactly: allocations climb
(1,400,956 against a key space of 1,048,576 - 352,380 more wmeta than there are objects),
the pool passes the 95% mark where `CheckReserveWmeta` gives up immediately, every write
falls onto the slow reclamation path, and `SampleVictim` finds ever fewer candidates
because leaked slots are permanently locked. Throughput decays 185k -> 0 over twenty
seconds. Note the upstream source has the diagnostic already written and commented out:

```cpp
// CHECK(wmeta_idx == wmeta_idx_optional.value())
//     << "wmeta idx and optional idx doesnot match: " ...
```

### Fix

Four sites, all the same shape: keep the locked index, only recycle when it matches what
`SwitchToReadOnly` returned, unlock otherwise, and never count a failed free as a reclaim.

* `src/manager/wmeta_manager.cc` - `SampleReclaim`, `IterativeReclaim`
* `lib/shm_obj_handle.cc` - three critical-path reclamation loops (`Admit`, and two in the
  write path)

Combined with sections 29 and 30 this is one coherent story: the reclamation subsystem has
a blocking lock where a try-lock is assumed, unbounded retry loops around it, and a leak
that guarantees those loops eventually spin. All three are invisible in the default
configuration, which sits ~1023 allocations below the threshold that would run any of it.

**Untested here.** Rebuild and watch the same three epilogue lines: `reclaim count` should
now track the manager's count, and the alloc ratio should stay near
`key_space / wmeta_pool` instead of climbing toward 95%.

## 32. Recommended benchmarking configuration (validated)

### Code

The port, plus three patches to the artifact. All three are required for real CXL; all are
no-ops or harmless on the emulated configuration.

| patch | what it fixes | section |
|---|---|---|
| `megalon-cxl-slot-index-fix.patch` | `cn_array_` CXL slot indexed by NUMA node id, so a logical node aliases the CXL entry when `NUMA_MEM != 0` | 27 |
| `ffi_nr_hashmap.rs` change | NR affinity switch assumes `NUMA_MEM` has CPUs; binds allocation policy instead when it does not | 19 |
| `megalon-wmeta-fixes.patch` | reclamation: blocking lock used as a try-lock, unbounded retry loops, and freeing a slot the thread does not hold locked | 29-31 |

Verify all three are applied before a run - a half-applied patch looks like a new bug:

```bash
for p in megalon-cxl-slot-index-fix.patch megalon-wmeta-fixes.patch; do
    git apply --check --reverse "$p" && echo "$p: applied" || echo "$p: NOT fully applied"
done
grep -c CPULESS_SENTINEL third-party/nr_rust/ffi/ffi_nr_hashmap.rs   # expect 2
```

The diagnostic counters used to find these bugs (`write branches`, and the
`CheckReserveWmeta` gate/scan warnings) have been removed - upstream's own teardown line
already carries the same signal:

```
seqlock alloc ratio: (N|M) = X%, reclaim count: R, allocate count: A
```

A healthy write run keeps the ratio near `key_space / wmeta_pool` with `R` tracking `A`. A
ratio pinned at 95% means the reservation gate has latched and the result is invalid; a
ratio pinned at the reclaim threshold with `R` and `A` both large means the run is in the
churn regime of section 32. If you need the branch histogram again,
`git log` has it - it was three relaxed atomics in `checkCacheNode`.

### Real CXL

```bash
./scripts/setup_lean.sh 2 2 24 2        # NUMA_MEM=2, LOGICAL_NODE_NUM=2, KEY_SIZE=24, NUM_NUMA=2
./scripts/build_lean.sh --clean
./scripts/check_consistency.sh
SLOT_HEADROOM_PCT=25 LATENCY_SAMPLE_EVERY=100 ./scripts/eval/hashmap.sh   # UNCORE_MODE=pin is the default
```

`UNCORE_MODE` now defaults to `pin`: the latency is real, so pinning only removes turbo
variance (section 9). Pass `UNCORE_MODE=slow` explicitly for the emulated configuration.
`NUM_NUMA=2` excludes the CPU-less node from the exec set (section 23). Keep
`THREAD_COUNTS` at or below the CPU count of the single exec node (the script warns).

### Emulated CXL, for comparison

```bash
./scripts/setup_lean.sh 0 2 24 2 && ./scripts/build_lean.sh --clean
UNCORE_MODE=slow SLOT_HEADROOM_PCT=25 LATENCY_SAMPLE_EVERY=100 ./scripts/eval/hashmap.sh
```

### What the write numbers mean

Measured, single writer, `key_space = 1048576`:

| config | slots | throughput | `ro` share of writes | reclaims |
|---|---|---|---|---|
| emulated | 1,049,600 | 639k ops/s | 0% | 0 |
| real CXL | 1,049,600 | 58k ops/s | 64% | 717,583 |
| real CXL | 1,310,720 | 179k ops/s | 45% | 1,362,485 |

The emulated 639k figure is **not** a like-for-like comparison: there the allocated count
happened to sit below the reclaim threshold, so the manager never ran at all. On real CXL
the steady state settles *at* the threshold - every object written stays RW holding a wmeta
slot until reclaimed, so the count rises to the threshold whatever `slots` is, and the
manager then runs continuously. More `slots` raises the equilibrium and reduces the churn
share, but does not eliminate it.

So for write results, either:

* report real-CXL numbers at a stated `slots` value, noting that ~45% of writes pay a
  wmeta reservation and the background reclaimer is active - this is the honest
  "reclamation engaged" regime, and arguably the one a real deployment would be in; or
* pick `slots` large enough that the threshold exceeds the number of distinct objects ever
  written *plus* in-flight churn, and confirm dormancy by `reclaim count: 0`. Watch the NCR
  cost: `slots * SLOT_SIZE`.

Read-only results (`hashmap-ro`) are unaffected either way - reads never allocate write
metadata, `ro` and `allocate count` stay at zero, and the run needs none of the above
tuning.

Always record these three lines with any result:

```
seqlock alloc ratio: (N|M) = X%, reclaim count: R, allocate count: A
coherence: reads=.. admits=.. read_retries=..
num pages cxl: (active|free) ..
```

They distinguish a dormant-reclamation run from a churning one, which is the difference
between the 639k and 58k figures above.etween the 639k and 58k figures above.
