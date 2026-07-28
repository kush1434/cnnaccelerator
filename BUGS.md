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

---

## Mutation testing results

`./mutate.sh` — full regression per mutant, RTL restored after each (and on
interrupt, via an EXIT trap). Final run: **9 injected, 9 caught, 0 escaped,
0 compile-fail, 0 invalid.**

| Mutant | Injected bug | Status | Caught by |
|--------|--------------|--------|-----------|
| M1 | `input_unit`: swap `out_row` / `out_col` | CAUGHT | T1, T6, T7, T8, T9, T10, T12, RND (all 40 seeds) |
| M2 | `input_unit`: swap `tap_row` / `tap_col` | CAUGHT | T10, RND (all 40 seeds) |
| M3 | `compute_unit`: `b_raddr` `k*P+j` → `j*N_TAP+k` | CAUGHT | T1, T7, T8, T9, T10, T12, RND |
| M4 | `conv_top`: drop `k==0` qualifier from `clear_acc` | CAUGHT | T1, T2, T4, T5, T6, T7, … (11 tests) |
| M5 | `conv_top`: `j` wrap `P-1` → `P-2` | CAUGHT | T1–T6 and 7 more (13 tests) |
| M6 | `output_unit`: write addr `c_addr_d[LAT-1]` → `[LAT-2]` | CAUGHT | T1–T6 and 7 more (13 tests) |
| M7 | `output_unit`: `we` = `valid_out` instead of `final_write` | CAUGHT *(after TB-3)* | write-port monitor, in all 13 tests |
| M8 | `output_unit`: address map `i*P+j` → `j*N_PATCH+i` | CAUGHT | T1, T2, T6, T7, T8, T9, RND |
| M9 | `cnn_pkg`: `ACC_W` 20 → 18 | CAUGHT | T4, T5, RND (31 of 200 seeds) |

Two observations worth keeping:

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
