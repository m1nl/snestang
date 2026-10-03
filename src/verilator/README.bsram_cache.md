# BSRAM cache regression

Requires Icarus Verilog (`iverilog` and `vvp`) and Make. From `src`:

```sh
make -C verilator -f Makefile.bsram_cache test
make -C verilator -f Makefile.bsram_cache test SEEDS="7 123" OPS=10000
```

The default runs three deterministic seeds with 4,000 randomized requests each,
in addition to the directed tests. Build output goes to `/tmp/snestang-bsram-cache`;
override `BUILD_DIR` if needed. Any assertion failure returns a nonzero exit status.
`SEED` initializes a private random generator, making failures reproducible.
The expected-transfer queue holds 65,536 transfers; a 20 ms simulation watchdog
also bounds each run. Very large `OPS` settings may need these limits increased.

`tb_bsram_cache.sv` instantiates the real `bsram_cache.v` and a behavioral
controller at its SDRAM interface. It uses an independent byte-addressed memory
scoreboard and direct-map policy predictor. Every SDRAM request is checked for
address, ordering, direction, byte enables, and enabled writeback bytes. Read
results are checked against the architectural memory. After evicting all dirty
lines, the entire 1 MiB backing store is compared with that memory, including bytes
that should remain untouched. Expectations do not inspect the DUT's RAMs or tags;
`dbg_state` is used for state coverage, initialization timing, and diagnostics.

Coverage includes:

- The 1,024-cycle metadata clear and PRIME cycle, held requests during initialization,
  reset output values, and all four initial SDRAM `ack`/`done` phase combinations.
- Cold fills, low/high byte hits, clean conflicts, zero and maximum addresses,
  index boundaries, every cache index, and an exhaustive sweep of all 512 tags.
- Write allocation without a read, repeated byte writes, writing a clean word,
  and writes to both bytes of a partially valid word.
- Both partial-fill directions, preserving valid dirty bytes while reading the
  missing byte and retaining the dirty mask for subsequent eviction.
- Low-only, high-only, and both-byte writebacks; eviction of partial words;
  reads fill and writes allocate before completing and writing back the victim.
- Early read/write completion, requests queued during eviction, and cache hits
  completing while a writeback is outstanding. Fills and further writebacks must
  wait for the old write's `done`, even when `req` already matches `ack`.
- Input changes after front `ack`, requests queued while busy, stable idle
  handshakes, and no duplicate requests/completions.
- The `IDLE` → `READ` → `LOOKUP` pipeline: `IDLE` detects a request; `READ`
  captures its payload and synchronously reads metadata/data on the acceptance
  edge; `LOOKUP` processes the RAM outputs on the next edge. Inputs change after
  acceptance to verify that subsequent processing uses the accepted payload.
  Writes return the accepted byte at both `ack` and completion.
- Dirty data discarded by reset and complete invalidation across all indices;
  reset during unacknowledged and accepted-but-incomplete SDRAM fills/writebacks,
  including deferred writebacks after the front request has already completed.
- Random reads/writes, concentrated hotspots, conflicting tags, repeated addresses,
  and full-range addresses with variable controller delays.

## Controller interface

`bsram_sdram_model.sv` implements the controller boundary: `req` toggles for a new
request, `ack` takes that phase when accepted, and `done` toggles only when the
transfer completes. `ack` and `done` are independent phases, not pulses. `ds[0]`
enables the low byte and `ds[1]` the high byte; reads fetch a whole aligned word.
Acceptance and completion delays are independently configurable. Zero completion
delay exercises simultaneous `ack`/`done`, matching the write behavior of
`sdram_cl2_3ch.v`; positive delay exercises the separate read completion.
Read data can appear at acceptance or only at completion. Between transfers,
the latter mode poisons the data bus to catch premature sampling.

Protocol assertions check stable SDRAM payloads through completion, acceptance
before completion, no overlapping backend transfers, and front completion after
the requested fill completes. On dirty misses, the only remaining transfer
at `front_done` must be the deferred victim writeback, which must start after that
response. Cache requests may proceed once the victim has been copied into the
SDRAM request registers, but further SDRAM transactions wait for write completion.
The test
requires coverage of every active cache state, every dirty mask (including deferred
writeback), both request phases, and simultaneous/separate `ack`/`done` timing.

The cache retains the victim in its synchronous metadata/data read outputs while
the fill or allocation replaces the RAM entry. It keeps `busy` asserted until
WRITEBACK copies the victim into the SDRAM request registers, then returns to IDLE
while `write_waiting` tracks completion independently. Cache hits can finish in
that interval. Both FILL and WRITEBACK check `!write_waiting` as well as
`req == ack`, preventing an old write completion from being consumed by a fill.
Allocation RAM writes are enabled only for writes, so read fills retain their
data, validity and dirty masks when passing through the completion state.

The top-level request generator waits for `busy` to clear and qualifies
`BSRAM_DONE` against the current address and a pending write, preventing a
subsequent GSU access from consuming the previous request's completion while a
new fill is blocked behind writeback. The default driver drains outstanding
transfers between ordinary requests; directed cases deliberately overlap them.

This tests the cache's controller interface with a model. It does not instantiate
the production SDRAM controller or verify SDRAM pins, arbitration, refresh,
clock-domain crossings, or physical memory timing.
