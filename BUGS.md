# Bug log — conv_top verification

Owner: verification (testbench, golden model, coverage, this log).
RTL is owned by the design side and is not modified except temporarily by `mutate.sh`.

Environment: Icarus Verilog 12 (`iverilog -g2012`).

```bash
iverilog -g2012 -o tb.vvp cnn_pkg.sv mem.sv mac_unit.sv input_unit.sv compute_unit.sv output_unit.sv conv_top.sv tb_conv_top.sv && vvp tb.vvp
```

---

## RTL defects

| # | Date | Symptom | Test that found it | Root cause | Fix |
|---|------|---------|--------------------|------------|-----|
| — | — | *None found to date.* | — | — | — |

As of 2026-07-28 the RTL passes 12 directed tests and 200 randomized seeds with
zero mismatches, at 100% of the 55 coverage bins.

That statement is only worth what the testbench is worth, so it is backed by a
mutation score rather than by a green log: **9 of 9 injected RTL bugs are
detected** (`./mutate.sh`). One of those nine escaped on the first attempt and
is written up as TB-3 below — the fix for it is now enforced on every inference,
including all 200 random seeds.

### Areas deliberately not covered

Recorded so nobody reads "all tests passed" as "everything is verified":

- **Timing / CDC** — single clock domain, no asynchronous crossings, nothing to check.
- **Out-of-range load addresses** — `ld_addr` is `LD_ADDR_W` = 6 bits, so weight
  loads at `ld_addr` ≥ `B_DEPTH` (36..63) index past the end of a 36-entry array.
  Simulation silently drops those writes; real hardware may not. The testbench
  never issues them. Flagged for the design side to define, not a defect.
- **Accumulator overflow beyond ACC_W** — cannot happen for INT8 inputs and
  `N_TAP` = 9 taps (worst case 147456 fits in 20 bits, proven by T5), and the
  design has no saturation logic or overflow flag to test.
- **Readback while busy** — `rd_data` is combinational off `memC`, so reading
  mid-inference returns whatever has been written so far. Not specified as
  legal or illegal; the testbench only reads after `done`.

---

## Design change: memC readback is now registered (2026-07-29)

Not a bug — an optimisation, recorded here because it **changes conv_top's
external interface**.

**What changed.** `mem.sv` gained a `SYNC_READ` parameter (default `0`, so
`memA` and `memB` are bit-identical to before). `output_unit.sv` instantiates
`memC` with `SYNC_READ(1)` and pipelines `rd_en` alongside.

**New readback contract.** Present `rd_addr` and `rd_en` on one clock edge;
`rd_data` is valid on the **next** edge. It used to be valid in the same cycle.
Anything on the host side that reads results needs to know this.

**Why.** A combinational read cannot map to a block RAM or SRAM macro, because
no such array returns data in the cycle the address is presented. Synthesis
therefore had to build the 144×20 result memory from flops plus a 144-way read
mux — about two thirds of the whole accelerator.

Measured with yosys, `synth_ice40`, whole `conv_top`:

| | before | after | change |
|---|---|---|---|
| total cells | 8,514 | 2,973 | **−65%** |
| flip-flops | 3,888 | 1,058 | **−73%** |
| LUT4 | 4,306 | 1,662 | −61% |
| block RAM | 0 | 2 | +2 |

The 2,830 flops that disappeared are exactly `memC` (144 × 20 = 2,880) moving
into BRAM, and the LUT drop is the 144-way read mux going away. Generic
`synth` shows no change (+4 cells) — the win only exists against a target that
has real memory blocks, which is worth knowing before anyone re-measures.

`memA` and `memB` still read combinationally: both feed the MAC datapath, so
converting them means generating their addresses a cycle earlier. Worth doing
(another ~2,500 cells) but it is a datapath change, not a one-line one.

**Reverting** is two lines: drop `.SYNC_READ(1)` in `output_unit.sv`, gate
`rd_data` with `rd_en` instead of `rd_en_d`, and set `RD_LAT = 0` in the
testbench. Verified: that combination still passes 13/13 with 55/55 bins.

**Testbench impact.** `read_all_results` holds address and enable stable across
`RD_LAT` clocks before sampling, so `RD_LAT` is an *upper bound* rather than an
exact figure — `RD_LAT = 1` reads a combinational port correctly too. That is
why the unmodified 4-MAC build on `final`, whose `output_unit` still uses a
combinational `memC`, passes unchanged with the same testbench.

---

## Testbench / methodology defects

Bugs found in the verification environment itself during bring-up. TB-3 and TB-4
both mattered: each was a case where the environment would have reported a false
pass.

| # | Date | Symptom | Test that found it | Root cause | Fix |
|---|------|---------|--------------------|------------|-----|
| TB-1 | 2026-07-28 | `tb_conv_top.sv: syntax error / malformed statement` at compile | first compile | `void'($value$plusargs(...))` — Icarus 12 does not support the `void'()` cast | Replaced with `if (!$value$plusargs("seeds=%d", num_seeds)) num_seeds = NUM_SEEDS;` |
| TB-2 | 2026-07-28 | Result line printed `[PASS] 6  mixed signs...` — leading `T` missing | visual inspection of T6 output | Test-name argument was a packed `[8*52:1]` string; T6's name is 53 chars, so the first character was truncated | Widened the `finish_test` name argument to `[8*72:1]` |
| TB-3 | 2026-07-28 | Mutant M7 (`memC.we` driven by `valid_out` instead of `final_write`) **escaped** — full regression still reported ALL TESTS PASSED | `mutate.sh` M7 | The result address `i*P+j` is constant across all `N_TAP` taps of a dot product, because `k` is the fastest counter. Writing on every retired term therefore lands all 9 partial sums on the *same* address, and the 9th is the finished value — so end-of-run memory contents are byte-identical to correct behaviour. A scoreboard that only compares final memory contents is structurally blind to it. | Added an always-on **write-port protocol monitor** that probes `dut.u_output.memC.we/.waddr` directly (not `final_write`, which the mutant leaves correct) and checks per inference: exactly `C_DEPTH` writes, each address written exactly once, and no writes while idle. Wired into `run_and_check`, so it now guards every directed test and every random seed. M7 is now caught by 13 tests. |
| TB-4 | 2026-07-28 | `mutate.sh`'s "SED DID NOT APPLY" guard could never fire, so a mutation whose pattern matched nothing would be injected as a no-op and then reported as a legitimately caught mutant | inspecting the whole-file `diff` output during the M1 run | RTL is checked out with CRLF endings; `sed` writes LF. `cmp -s` therefore reported *every* file as changed, including no-op ones — the guard was structurally dead | Compare with `diff -q --strip-trailing-cr`. Verified in both directions: a pattern matching nothing is now reported as invalid, a real pattern is still reported as a mutation |
| TB-5 | 2026-07-29 | Testbench would not elaborate at all: `Unable to bind wire/reg/memory dut.u_output.memC.we` and two more, 5 elaboration errors | first build against current `main` | `conv_top.sv` renamed its output stage instance `u_output` → `u_output_unit`. The TB had the instance name written out longhand in three separate places (lines 246, 247, 394), so one design-side rename broke three call sites at once | Every hierarchical path now comes from one macro block at the top of the file (`` `TB_DUT `` / `` `TB_OUT_UNIT `` / `` `TB_RESULT_MEM ``) with a comment saying it must track `conv_top`'s instance names. A future rename is a one-line edit. Verified the same block binds against both the 1-MAC (`main`) and 4-MAC (`final`) builds — both name these `u_output_unit` and `memC` |
| TB-6 | 2026-07-29 | T8 reported *"the spurious start pulse never actually overlapped busy"* and T9 *"expected busy high mid-run"* against the 4-MAC build — tests failing for a reason unrelated to the RTL | running the environment against branch `final` | T8/T9 timed their mid-run stimulus off `RUN_CYCLES = N_PATCH*P*N_TAP`, a compile-time constant describing one microarchitecture. The 4-MAC build unrolls `j` and finishes in 331 cycles, so an injection at cycle 648 landed after `done`. The same constant was *already* wrong on `main`: the new window-preload phase makes a real run 1309 cycles, not 1296 | Added `calibrate_run_length`, which times one clean inference before any test that acts mid-run. T8 derives its injection point from `inject_point(1,2)` of the measured value; T9 uses `wait_into_run(1,3)`, which waits on observed `busy` and stops early if the run ends. `RUN_CYCLES` is renamed `NOMINAL_CYCLES` and used only to size the watchdog. Both precondition guards were kept deliberately and now also print the injection point vs the actual run length |
| TB-7 | 2026-07-29 | `mutate.sh` would silently stop testing three of its nine mutants once the file rename lands — and M1/M2/M4 were *already* dead on current `main` | auditing the mutant patterns against current `main` while retargeting for `final` | The script hardcoded `input_unit.sv`/`compute_unit.sv`. Worse, `main`'s `input_unit.sv` had been rewritten as a double-buffered window loader with no `out_row`/`tap_row` signals, and `conv_top` now writes `(k == '0)` rather than `(k == 0)` — so M1, M2 and M4 matched nothing on the branch being tested every day | The script now detects the configuration from the module names `conv_top.sv` actually instantiates (both variants can be in the tree at once, so file presence proves nothing), derives the build list from that, and carries per-variant (file, pattern) pairs for every mutant. M5 is reported **N/A** on the 4-MAC build rather than invalid or caught, because the filter loop is unrolled and there is no `j` counter to break. A **guard self-test** now runs before any mutant and aborts the script if the TB-4 guard is not working in both directions |

---

## Mutation testing results

`./mutate.sh` — full regression per mutant, RTL restored after each (and on
interrupt, via an EXIT trap). The script detects which microarchitecture
`conv_top.sv` builds and applies the matching pattern set, so the same nine
bugs are tested against either configuration.

**1-MAC build (branch `main`): 9 considered, 9 caught, 0 escaped, 0 N/A, 0 invalid.**
**4-MAC build (branch `final`): 9 considered, 8 caught, 0 escaped, 1 N/A, 0 invalid.**

| Mutant | Injected bug | 1-MAC target | 4-MAC target | Status |
|--------|--------------|--------------|--------------|--------|
| M1 | swap output row / col | `input_unit.sv` window address | `conv_top.sv` `out_row`/`out_col` drivers (they are inputs to `input_unit_opt`) | CAUGHT / CAUGHT |
| M2 | swap kernel tap row / col | `input_unit.sv` window address | `input_unit_opt.sv` `tap_row`/`tap_col` | CAUGHT / CAUGHT |
| M3 | transpose weight address | `compute_unit.sv` `b_raddr` `k*P+j`→`j*N_TAP+k` | `compute_unit_4mac.v` `memB[(k*P)+f]`→`[(f*N_TAP)+k]` | CAUGHT / CAUGHT |
| M4 | drop `k==0` from `clear_acc` | `conv_top.sv` | `conv_top.sv` | CAUGHT / CAUGHT |
| M5 | `j` wrap `P-1`→`P-2` | `conv_top.sv` | **N/A** — filter loop unrolled, no `j` counter exists | CAUGHT / N/A |
| M6 | LAT alignment one stage short | `output_unit.sv` `c_addr_d[LAT-1]`→`[LAT-2]` | `output_unit.sv` `final_term_d[LAT-1]`→`[LAT-2]` in the capture trigger | CAUGHT / CAUGHT |
| M7 | `we` = `valid_out` not `final_write` | `output_unit.sv` | `output_unit.sv` | CAUGHT / CAUGHT |
| M8 | transpose result address map | `c_addr_now = i*P+j` | `wr_addr = wr_i*P+wr_filt` | CAUGHT / CAUGHT |
| M9 | `ACC_W` 20 → 18 | `cnn_pkg.sv` | `cnn_pkg.sv` | CAUGHT / CAUGHT |

### An equivalent mutant, and a design observation that came out of it

The obvious 4-MAC analogue of M6 is `patch_i_d[LAT-1]` → `[LAT-2]`, and it
**escapes** — correctly, because it is algebraically equivalent. `patch_i_d[0]`
is loaded *conditionally* (`if (final_term_now)`), and `final_term_now` fires
once every `N_TAP` cycles, while the value is read only `LAT` cycles later. For
any `LAT < N_TAP` every stage of `patch_i_d` therefore holds the same value at
the only moment any of them is read, so shortening the pipeline changes nothing.

Two consequences:

1. M6 on the 4-MAC build targets the *marker* pipeline `final_term_d[LAT-1]`
   instead, which is what actually decides when the four accumulators are
   captured. That one is caught by 12 tests.
2. **For the design side:** `patch_i_d` is a redundant pipeline in the 4-MAC
   `output_unit`. The conditional load already performs the alignment, so the
   `LAT`-deep shift register costs `LAT × PATCH_W` flops and buys nothing. Not a
   bug — the design is correct — but it is dead logic worth deleting.

Two further observations worth keeping:

- **M9 is caught by only 31 of 200 random seeds** (~15%) but by T5 every time. That is
  the biased-seed argument made concrete: uniform INT8 stimulus produces nine
  products that average toward zero, so most seeds never push the accumulator
  near the 20-bit limit and cannot see a too-narrow accumulator. The directed
  worst-case test and the ~1-in-3 extreme-biased seeds are what actually cover
  that bit of the state space.
- **M2 is caught by only T10 plus the random regression**, not by T1–T9.
  Swapping `tap_row`/`tap_col` transposes the kernel, which is invisible to any
  symmetric stimulus — an all-ones filter, a constant image, or a single centre
  tap all look the same transposed. Asymmetric stimulus is what catches it.
