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

`scripts/eval/hashmap.sh` takes `UNCORE_MODE`:

| mode | effect | when |
|---|---|---|
| `slow` (default) | NUMA_MEM package to `SLOW_FREQ_KHZ` (800 MHz), others to `FAST_FREQ_KHZ` | DRAM-only machine, reproducing the paper |
| `pin` | every package to `FAST_FREQ_KHZ`, nothing slowed | real CXL memory — removes turbo-driven run-to-run variance on the exec side without emulating anything |
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
