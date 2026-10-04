# GSU SDRAM shared-slot regression

Run from `src` with Icarus Verilog installed:

```sh
make -C verilator -f Makefile.sdram_gsu test
```

The runner tests the production `sdram_cl2_3ch_gsu.v` controller with a sparse
SDRAM pin model in four configurations: 16 MiB / 32 MiB SDRAM, each with
`BSRAM_DONE_DELAY` disabled and enabled. Executables go into
`/tmp/snestang-sdram-gsu` by default (`BUILD_DIR` overrides this).

ARAM and BSRAM share slot 1 and bank 2. ARAM wins whenever both requests are
pending at slot reservation (cycle 0). The selected operation remains reserved
through its RAS/CAS sequence; a later ARAM request is serviced in the next frame.
ARAM occupies bank offsets `0x000000–0x00FFFF`. BSRAM occupies the final 1 MiB:
`0x300000–0x3FFFFF` for 16 MiB SDRAM and `0x700000–0x7FFFFF` for 32 MiB SDRAM.
`need_refresh` blocks new BSRAM reservations, including reads, while ARAM retains
priority. Requests already reserved complete normally.

Coverage includes BSRAM reads at both ends of its address range, full-word and
masked writes, ARAM byte writes and reads, simultaneous ARAM/BSRAM requests,
independent CPU reads, normal and delayed write schedules, a late ARAM request,
read completion across a frame boundary, and refresh progress while BSRAM waits.
The tests verify actual SDRAM commands, physical word addresses, data and masks
as well as host request/ack/done signals.

The pin model covers CL2 single-word transfers at the controller's expected
clock phase. It does not validate electrical timing, synthesis, or board behavior.
