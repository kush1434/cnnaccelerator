// ============================================================================
// tb_conv_top.sv -- system-level verification environment for conv_top
// ----------------------------------------------------------------------------
// Target simulator: Icarus Verilog 12  (iverilog -g2012)
//
// Build & run:
//   iverilog -g2012 -o tb.vvp cnn_pkg.sv mem.sv mac_unit.sv input_unit.sv \
//            compute_unit.sv output_unit.sv conv_top.sv tb_conv_top.sv
//   vvp tb.vvp
//
// Plusargs:
//   +seeds=<n>   override the randomized regression depth (default NUM_SEEDS)
//   +vcd         dump waves to tb_conv_top.vcd
//
// ----------------------------------------------------------------------------
// COMPONENTS (each block is labelled below)
//   1. clock / reset generator
//   2. DUT instance
//   3. stimulus arrays + vector generators
//   4. loader      task  - fills memA / memB through the load port
//   5. golden model task - independent nested-loop convolution
//   6. driver      task  - pulses start, waits for done, measures duration
//   7. monitor     task  - sweeps rd_addr 0..C_DEPTH-1, captures rd_data
//   8. scoreboard  task  - compares, prints addr/patch/filter/got/expected
//   9. coverage tracker  - fixed-size counter array + case-based name function
//  10. directed tests T1..T11
//  11. randomized regression
//  12. coverage report + final summary
//
// ----------------------------------------------------------------------------
// WHY THE GOLDEN MODEL LOOKS NOTHING LIKE THE RTL
//
// The RTL derives its image address arithmetically from the flat patch index:
//     (i/OFM_W + k/KS)*IFM_W + (i%OFM_W + k%KS)
// The model below must NOT reuse that expression.  If both sides share one
// formula, a misreading of the addressing makes model and RTL wrong in exactly
// the same way, the comparison still comes out green, and nothing has been
// verified.  That is a correlated error, and it is the failure mode that
// matters most here.
//
// So the model is written as five nested loops that spell out the textbook
// definition of a convolution -- output row, output column, filter, kernel row,
// kernel column -- with no flat patch index and no div/mod anywhere.  Different
// structure, same answer, so agreement is actual evidence.
//
// T1 (identity kernel) and T11 (single boundary weight) go one step further and
// are checked against values computed by hand in the test itself, independently
// of the golden model, which is what validates the model itself.
// ============================================================================

`timescale 1ns/1ps

import cnn_pkg::*;

// ============================================================================
// HIERARCHICAL PROBE PATHS -- the only place in this file that names an
// instance inside the DUT.
// ----------------------------------------------------------------------------
// MUST TRACK conv_top.sv's INSTANCE NAMES.  These names are owned by the design
// side and have already been renamed once (u_output -> u_output_unit), which
// broke elaboration in three separate places at once.  Keeping every path here
// makes the next rename a one-line edit instead of a hunt through 1100 lines.
//
// If the testbench stops elaborating with "Unable to bind wire/reg/memory
// dut.<something>", the fix is almost certainly in this block -- compare
// against the instance names in conv_top.sv and output_unit.sv.
//
//   `TB_OUT_UNIT    the output_unit instance inside conv_top
//   `TB_RESULT_MEM  the mem instance inside it that holds the C_DEPTH results
//
// Checked against both microarchitectures currently in the repo: the 1-MAC
// build (branch main) and the 4-MAC build (branch final) both name these
// u_output_unit and memC, so one definition covers both.
// ============================================================================
`define TB_DUT         dut
`define TB_OUT_UNIT    `TB_DUT.u_output_unit
`define TB_RESULT_MEM  `TB_OUT_UNIT.memC

module tb_conv_top;

  // ==========================================================================
  // Parameters  (nothing below hardcodes a number that cnn_pkg already knows)
  // ==========================================================================

  // Randomized regression depth.  A parameter so a quick smoke run can dial it
  // down (-Ptb_conv_top.NUM_SEEDS=20) and a full regression can dial it up;
  // also overridable at run time with +seeds=<n>.
  parameter integer NUM_SEEDS = 200;

  localparam integer CLK_P      = 10;
  localparam integer MAX_PRINT  = 5;                       // mismatches printed per test

  // Readback latency of conv_top's rd_data port, in clocks.
  //
  //   0 = combinational read (rd_data valid in the same cycle as rd_addr)
  //   1 = registered read    (rd_data valid one cycle later)
  //
  // memC uses a registered read so it can map to a block RAM instead of
  // synthesising as flops plus a C_DEPTH-way mux -- see the note in
  // output_unit.sv.  Everything below is written against this constant rather
  // than assuming a value, so flipping it back to 0 is all the testbench needs
  // if the design side reverts.
  localparam integer RD_LAT     = 1;

  // NOMINAL_CYCLES is an ORDER-OF-MAGNITUDE BOUND used only to size the
  // watchdog.  It is deliberately NOT used to time any stimulus.
  //
  // The real length of an inference is a property of the microarchitecture, not
  // of the parameters: the 1-MAC design walks i/j/k for N_PATCH*P*N_TAP cycles
  // plus window preload and pipeline drain, while the 4-MAC variant unrolls the
  // j loop and finishes in N_PATCH*N_TAP.  Any test that injects stimulus
  // partway through a run therefore measures the length first
  // (see calibrate_run_length / meas_cycles) rather than computing it.
  localparam integer NOMINAL_CYCLES = N_PATCH * P * N_TAP;
  localparam integer TIMEOUT_C      = NOMINAL_CYCLES * 4 + 1024;

  // Worst-case |accumulator|: N_TAP products of the two most negative INT8s.
  //   N_TAP * 2^(DW-1) * 2^(DW-1) = 9 * 128 * 128 = 147456
  localparam integer ACC_WORST  = N_TAP * (1 << (DW-1)) * (1 << (DW-1));

  localparam integer INT8_MAX   =  (1 << (DW-1)) - 1;      //  127
  localparam integer INT8_MIN   = -(1 << (DW-1));          // -128

  // Centre tap of the kernel, derived: for KS=3 this is tap 4, offset (1,1).
  localparam integer KS_MID     = KS / 2;
  localparam integer TAP_CENTRE = KS_MID * KS + KS_MID;

  // Accumulator magnitude buckets (spec: zero / <1K / 1K..100K / >100K).
  localparam integer TH_SMALL   = 1024;
  localparam integer TH_MED     = 100000;

  // Value written into memC before every run so that "never written" is
  // distinguishable from "written correctly".  Outside the legal result range
  // +/-ACC_WORST, and derived from ACC_W so it tracks a width change.
  localparam signed [ACC_W-1:0] POISON = {1'b0, {(ACC_W-1){1'b1}}};

  // ==========================================================================
  // 9. Coverage tracker -- Icarus has no covergroups, so: a fixed-size array of
  //    counters, localparam bin IDs, and a case-based name function.
  // ==========================================================================
  localparam integer COV_BUSY_LOW    = 0;
  localparam integer COV_BUSY_HIGH   = 1;
  localparam integer COV_DONE        = 2;
  localparam integer COV_ACC_ZERO    = 3;
  localparam integer COV_ACC_SMALL   = 4;
  localparam integer COV_ACC_MED     = 5;
  localparam integer COV_ACC_NEARMAX = 6;
  localparam integer COV_ACC_NEG     = 7;
  localparam integer COV_B2B         = 8;
  localparam integer COV_RST_MID     = 9;
  localparam integer COV_START_BUSY  = 10;
  localparam integer COV_SCALAR_N    = 11;

  localparam integer COV_PATCH_BASE  = COV_SCALAR_N;                  // + N_PATCH bins
  localparam integer COV_FILT_BASE   = COV_PATCH_BASE + N_PATCH;      // + P bins
  localparam integer N_CORNER        = 4;
  localparam integer COV_CORNER_BASE = COV_FILT_BASE + P;             // + 4 bins
  localparam integer NUM_BINS        = COV_CORNER_BASE + N_CORNER;

  integer cov [0:NUM_BINS-1];

  task cov_hit_bin(input integer b);
    begin
      if (b >= 0 && b < NUM_BINS) cov[b] = cov[b] + 1;
    end
  endtask

  // The four OFM corners, expressed in parameters rather than as 0/5/30/35.
  function integer corner_patch(input integer c);
    begin
      case (c)
        0:       corner_patch = 0;                    // top-left
        1:       corner_patch = OFM_W - 1;            // top-right
        2:       corner_patch = (OFM_H - 1) * OFM_W;  // bottom-left
        default: corner_patch = N_PATCH - 1;          // bottom-right
      endcase
    end
  endfunction

  function [8*22:1] bin_name(input integer b);
    begin
      case (b)
        COV_BUSY_LOW:    bin_name = "busy_low";
        COV_BUSY_HIGH:   bin_name = "busy_high";
        COV_DONE:        bin_name = "done_pulse";
        COV_ACC_ZERO:    bin_name = "acc_zero";
        COV_ACC_SMALL:   bin_name = "acc_small_lt1K";
        COV_ACC_MED:     bin_name = "acc_med_1K_100K";
        COV_ACC_NEARMAX: bin_name = "acc_nearmax_gt100K";
        COV_ACC_NEG:     bin_name = "acc_negative";
        COV_B2B:         bin_name = "back_to_back_run";
        COV_RST_MID:     bin_name = "reset_mid_run";
        COV_START_BUSY:  bin_name = "start_while_busy";
        default:         bin_name = "indexed";
      endcase
    end
  endfunction

  // ==========================================================================
  // 1. Clock / reset generator + DUT signals
  // ==========================================================================
  logic                    clk;
  logic                    rst_n;
  logic                    start;
  logic                    busy;
  logic                    done;
  logic                    ld_en;
  logic                    ld_sel_ab;
  logic [LD_ADDR_W-1:0]    ld_addr;
  logic signed [DW-1:0]    ld_data;
  logic                    rd_en;
  logic [C_ADDR_W-1:0]     rd_addr;
  logic signed [ACC_W-1:0] rd_data;

  initial clk = 1'b0;
  always #(CLK_P/2) clk = ~clk;

  // ==========================================================================
  // 2. DUT
  // ==========================================================================
  conv_top dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (start),
    .busy      (busy),
    .done      (done),
    .ld_en     (ld_en),
    .ld_sel_ab (ld_sel_ab),
    .ld_addr   (ld_addr),
    .ld_data   (ld_data),
    .rd_en     (rd_en),
    .rd_addr   (rd_addr),
    .rd_data   (rd_data)
  );

  // ==========================================================================
  // 3. Stimulus arrays and bookkeeping
  // ==========================================================================
  reg signed [DW-1:0] img [0:A_DEPTH-1];   // image, index = row*IFM_W + col
  reg signed [DW-1:0] wgt [0:B_DEPTH-1];   // weights, index = tap*P + filter

  // Expected results are kept at FULL precision (integer), never truncated to
  // ACC_W.  If the model stored ACC_W-wide values it would wrap exactly the way
  // a too-narrow accumulator wraps, and an ACC_W bug would compare equal.
  integer exp_c [0:C_DEPTH-1];
  integer got_c [0:C_DEPTH-1];

  integer tests_run, tests_failed, total_errors;
  integer num_seeds, rr_fail, rr_err;
  integer first_cycles, rc_cycles, sb_max_print;
  // Measured length of one clean inference, established by calibrate_run_length
  // before any test that needs to act partway through a run.
  integer meas_cycles, cal_err, t_inject, t_cov0;
  integer wir_n, wir_target;
  integer drv_timeout;

  // per-task loop variables (module level: Icarus does not reliably support
  // automatic storage inside initial blocks)
  integer ld_i, mon_a, sb_a, sb_printed, cv_i, cv_mag, pz_i, vs_i, vs_j;
  integer gm_orow, gm_ocol, gm_f, gm_fr, gm_fc, gm_sum;
  integer t_r, t_c, t_p, t_f, t_n, t_hand, t_err, t_werr;
  integer rs_s, rs_i, rs_tmp, rs_seed, rs_extreme;
  integer cr_b, cr_hit;
  real    cov_pct;

  // ==========================================================================
  // 9b. Coverage sampler -- runs every cycle
  // ==========================================================================
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if (busy === 1'b1) cov_hit_bin(COV_BUSY_HIGH);
      else               cov_hit_bin(COV_BUSY_LOW);
      if (done  === 1'b1) cov_hit_bin(COV_DONE);
      if (start === 1'b1 && busy === 1'b1) cov_hit_bin(COV_START_BUSY);
    end
  end

  // ==========================================================================
  // 7b. Write-port protocol monitor
  // --------------------------------------------------------------------------
  // Comparing memory contents after a run is not enough on its own.  The result
  // address i*P+j is constant across all N_TAP taps of a dot product (k is the
  // fastest counter), so a design that writes on every retired term instead of
  // only the last one lands all N_TAP partial sums on the SAME address, and the
  // last of them is the finished value.  Final memory contents come out
  // identical and the scoreboard sees nothing wrong.
  //
  // The difference is in the write activity, so that is what this monitor
  // watches: exactly C_DEPTH writes per inference, each address written exactly
  // once, and never a write while idle.  It probes the memory instance's own
  // port rather than output_unit's final_write signal, so a broken we
  // connection cannot hide behind a correct-looking final_write.
  // --------------------------------------------------------------------------
  wire                 wp_we   = `TB_RESULT_MEM.we;
  wire [C_ADDR_W-1:0]  wp_addr = `TB_RESULT_MEM.waddr;

  integer wr_count, wr_while_idle, wp_i, wp_bad;
  integer wr_per_addr [0:C_DEPTH-1];

  always @(posedge clk) begin
    if (rst_n === 1'b1 && wp_we === 1'b1) begin
      wr_count = wr_count + 1;
      if (wp_addr < C_DEPTH) wr_per_addr[wp_addr] = wr_per_addr[wp_addr] + 1;
      if (busy !== 1'b1)     wr_while_idle = wr_while_idle + 1;
    end
  end

  task clear_write_monitor;
    begin
      wr_count      = 0;
      wr_while_idle = 0;
      for (wp_i = 0; wp_i < C_DEPTH; wp_i = wp_i + 1) wr_per_addr[wp_i] = 0;
    end
  endtask

  task check_write_protocol(output integer werr);
    begin
      werr = 0;
      if (wr_count !== C_DEPTH) begin
        $display("        WRITE COUNT: %0d writes to memC this inference, expected exactly %0d",
                 wr_count, C_DEPTH);
        $display("                     (one write per output element, not one per accumulated term)");
        werr = werr + 1;
      end
      wp_bad = 0;
      for (wp_i = 0; wp_i < C_DEPTH; wp_i = wp_i + 1)
        if (wr_per_addr[wp_i] !== 1) begin
          if (wp_bad < MAX_PRINT)
            $display("        addr %0d written %0d time(s), expected exactly 1",
                     wp_i, wr_per_addr[wp_i]);
          wp_bad = wp_bad + 1;
        end
      if (wp_bad != 0) begin
        $display("        %0d address(es) not written exactly once", wp_bad);
        werr = werr + 1;
      end
      if (wr_while_idle != 0) begin
        $display("        %0d write(s) occurred while busy was low", wr_while_idle);
        werr = werr + 1;
      end
    end
  endtask

  // ==========================================================================
  // 4. Loader -- drives the load port to fill both memories.
  //    Loads are only accepted while busy is low, which is where this is called.
  // ==========================================================================
  task load_memories;
    begin
      for (ld_i = 0; ld_i < A_DEPTH; ld_i = ld_i + 1) begin
        @(negedge clk);
        ld_en     = 1'b1;
        ld_sel_ab = 1'b0;                 // 0 = image
        ld_addr   = ld_i[LD_ADDR_W-1:0];
        ld_data   = img[ld_i];
      end
      for (ld_i = 0; ld_i < B_DEPTH; ld_i = ld_i + 1) begin
        @(negedge clk);
        ld_en     = 1'b1;
        ld_sel_ab = 1'b1;                 // 1 = weights, addr = tap*P + filter
        ld_addr   = ld_i[LD_ADDR_W-1:0];
        ld_data   = wgt[ld_i];
      end
      @(negedge clk);
      ld_en     = 1'b0;
      ld_sel_ab = 1'b0;
      ld_addr   = '0;
      ld_data   = '0;
    end
  endtask

  // ==========================================================================
  // 5. Golden model -- textbook convolution, five nested loops.
  //    No flat patch index, no div, no mod: structurally unrelated to the RTL.
  // ==========================================================================
  task golden_model;
    begin
      for (gm_orow = 0; gm_orow < OFM_H; gm_orow = gm_orow + 1)
        for (gm_ocol = 0; gm_ocol < OFM_W; gm_ocol = gm_ocol + 1)
          for (gm_f = 0; gm_f < P; gm_f = gm_f + 1) begin
            gm_sum = 0;
            for (gm_fr = 0; gm_fr < KS; gm_fr = gm_fr + 1)
              for (gm_fc = 0; gm_fc < KS; gm_fc = gm_fc + 1)
                gm_sum = gm_sum
                       + img[(gm_orow + gm_fr) * IFM_W + (gm_ocol + gm_fc)]
                       * wgt[(gm_fr * KS + gm_fc) * P + gm_f];
            exp_c[(gm_orow * OFM_W + gm_ocol) * P + gm_f] = gm_sum;
          end
    end
  endtask

  // ==========================================================================
  // 6. Driver -- pulse start, wait for done, measure the run length.
  //    inject_start_cycle >= 0 pulses start again mid-run (for T8); -1 = never.
  // ==========================================================================
  task run_inference(input integer inject_start_cycle, output integer cycles);
    begin
      drv_timeout = 0;
      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;      // start was high across exactly one posedge
      cycles = 1;
      while (done !== 1'b1 && cycles < TIMEOUT_C) begin
        @(posedge clk);
        #1;
        cycles = cycles + 1;
        if (cycles == inject_start_cycle)      start = 1'b1;
        else if (start === 1'b1)               start = 1'b0;
      end
      if (done !== 1'b1) begin
        drv_timeout = 1;
        $display("        ERROR: timed out waiting for done (%0d cycles)", cycles);
      end
      start = 1'b0;
      @(negedge clk);
    end
  endtask

  // ==========================================================================
  // 7. Monitor -- sweep the readback port across the whole result memory.
  //    rd_data is only valid while rd_en is high, RD_LAT clocks after the
  //    address is presented.  Holding rd_en and rd_addr stable across the
  //    latency keeps this correct for RD_LAT = 0 as well as 1.
  // ==========================================================================
  task read_all_results;
    begin
      for (mon_a = 0; mon_a < C_DEPTH; mon_a = mon_a + 1) begin
        @(negedge clk);
        rd_en   = 1'b1;
        rd_addr = mon_a[C_ADDR_W-1:0];
        repeat (RD_LAT) @(negedge clk);  // wait out the readback pipeline
        #1;
        got_c[mon_a] = rd_data;          // signed ACC_W -> integer, sign extended
      end
      @(negedge clk);
      rd_en   = 1'b0;
      rd_addr = '0;
    end
  endtask

  // Poison the result memory so a missing write cannot masquerade as a stale
  // but plausible value left over from the previous test.
  task poison_results;
    begin
      for (pz_i = 0; pz_i < C_DEPTH; pz_i = pz_i + 1)
        `TB_RESULT_MEM.storage[pz_i] = POISON;
    end
  endtask

  // ==========================================================================
  // 8. Scoreboard + per-result coverage sampling
  // ==========================================================================
  task sample_result_coverage(input integer a);
    begin
      cov_hit_bin(COV_PATCH_BASE + (a / P));
      cov_hit_bin(COV_FILT_BASE  + (a % P));
      for (cv_i = 0; cv_i < N_CORNER; cv_i = cv_i + 1)
        if ((a / P) == corner_patch(cv_i)) cov_hit_bin(COV_CORNER_BASE + cv_i);

      cv_mag = exp_c[a];
      if (cv_mag < 0) begin
        cv_mag = -cv_mag;
        cov_hit_bin(COV_ACC_NEG);
      end
      if      (cv_mag == 0)       cov_hit_bin(COV_ACC_ZERO);
      else if (cv_mag <  TH_SMALL) cov_hit_bin(COV_ACC_SMALL);
      else if (cv_mag <= TH_MED)   cov_hit_bin(COV_ACC_MED);
      else                         cov_hit_bin(COV_ACC_NEARMAX);
    end
  endtask

  task scoreboard(output integer nerr);
    begin
      nerr       = 0;
      sb_printed = 0;
      for (sb_a = 0; sb_a < C_DEPTH; sb_a = sb_a + 1) begin
        sample_result_coverage(sb_a);
        if (got_c[sb_a] !== exp_c[sb_a]) begin
          nerr = nerr + 1;
          if (sb_printed < sb_max_print) begin
            $display("        MISMATCH addr=%3d  patch=%2d filter=%0d  got=%8d  expected=%8d",
                     sb_a, sb_a / P, sb_a % P, got_c[sb_a], exp_c[sb_a]);
            sb_printed = sb_printed + 1;
          end
        end
      end
      if (nerr > sb_max_print && sb_max_print > 0)
        $display("        ... %0d further mismatches suppressed", nerr - sb_max_print);
      if (drv_timeout) nerr = nerr + 1;
    end
  endtask

  // One full transaction: poison, load, model, run, read back, compare.
  task run_and_check(output integer nerr);
    begin
      poison_results;
      load_memories;
      golden_model;
      clear_write_monitor;
      run_inference(-1, rc_cycles);
      read_all_results;
      scoreboard(nerr);

      // Write-port protocol holds for every inference, not just one test.
      check_write_protocol(t_werr);
      nerr = nerr + t_werr;

      // Every inference walks the same fixed counter sequence, so the run
      // length is invariant.  A change means the control path grew or lost
      // cycles even if the data happens to come out right.
      if (first_cycles < 0) first_cycles = rc_cycles;
      else if (rc_cycles !== first_cycles) begin
        $display("        RUN LENGTH CHANGED: %0d cycles now vs %0d on the first run",
                 rc_cycles, first_cycles);
        nerr = nerr + 1;
      end
    end
  endtask

  // ==========================================================================
  // 6b. Run-length calibration and mid-run timing helpers
  // --------------------------------------------------------------------------
  // Tests that act partway through an inference (T8 injects a start pulse, T9
  // asserts reset) used to count a fixed N_PATCH*P*N_TAP/2 cycles.  That is a
  // statement about one microarchitecture, not about the design under test: on
  // a 4-MAC build that unrolls the j loop the run is a quarter as long, the
  // injection point lands after done, and the test fails for a reason that has
  // nothing to do with the RTL.
  //
  // Instead: time one clean inference up front, and derive every injection
  // point from that measurement.  The run length is deterministic (run_and_check
  // asserts it never changes), so a fraction of the measured value is always
  // inside the run whatever the architecture.
  // ==========================================================================
  task calibrate_run_length;
    begin
      $display("\n--- Calibration: measuring one clean inference ---");
      vec_identity;
      poison_results;
      load_memories;
      golden_model;
      clear_write_monitor;
      run_inference(-1, meas_cycles);
      read_all_results;
      scoreboard(cal_err);
      check_write_protocol(t_werr);
      cal_err = cal_err + t_werr;

      first_cycles = meas_cycles;
      $display("        measured run length : %0d cycles (start to done)", meas_cycles);
      $display("        nominal 1-MAC guess : %0d cycles -- NOT used for timing", NOMINAL_CYCLES);
      $display("        mid-run stimulus is timed off the measured value, so a different");
      $display("        microarchitecture needs no test edits");

      if (meas_cycles < 4) begin
        $display("        ERROR: measured run length %0d is too short to inject into", meas_cycles);
        cal_err = cal_err + 1;
      end
      if (cal_err != 0) begin
        $display("        ERROR: the calibration inference itself reported %0d error(s);", cal_err);
        $display("               every mid-run injection point below is therefore suspect");
        total_errors = total_errors + cal_err;
      end
    end
  endtask

  // Fraction of the measured run length, clamped so the injection point can
  // never sit at or past the end of the run.
  function integer inject_point(input integer num, input integer den);
    integer v;
    begin
      v = (meas_cycles * num) / den;
      if (v < 2)                v = 2;
      if (v > meas_cycles - 2)  v = meas_cycles - 2;
      inject_point = v;
    end
  endfunction

  // Wait until an inference is genuinely underway: busy asserted, then num/den
  // of the measured run length.  Stops early if the run ends first, so the
  // caller is left mid-run whenever that is physically possible.  If it is not,
  // the caller's own busy check reports it -- this helper never papers over a
  // bad injection point, it just refuses to overshoot silently.
  task wait_into_run(input integer num, input integer den);
    begin
      wir_n = 0;
      while (busy !== 1'b1 && done !== 1'b1 && wir_n < TIMEOUT_C) begin
        @(negedge clk);
        wir_n = wir_n + 1;
      end
      wir_target = inject_point(num, den);
      wir_n = 0;
      while (wir_n < wir_target && busy === 1'b1 && done !== 1'b1) begin
        @(negedge clk);
        wir_n = wir_n + 1;
      end
    end
  endtask

  task finish_test(input [8*72:1] tname, input integer nerr);
    begin
      tests_run    = tests_run + 1;
      total_errors = total_errors + nerr;
      if (nerr == 0) $display("[PASS] %0s", tname);
      else begin
        tests_failed = tests_failed + 1;
        $display("[FAIL] %0s   (%0d error(s))", tname, nerr);
      end
    end
  endtask

  task reset_dut;
    begin
      rst_n     = 1'b0;
      start     = 1'b0;
      ld_en     = 1'b0;
      ld_sel_ab = 1'b0;
      ld_addr   = '0;
      ld_data   = '0;
      rd_en     = 1'b0;
      rd_addr   = '0;
      repeat (4) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
    end
  endtask

  // ==========================================================================
  // 3b. Vector generators
  // ==========================================================================
  task vec_clear;
    begin
      for (vs_i = 0; vs_i < A_DEPTH; vs_i = vs_i + 1) img[vs_i] = '0;
      for (vs_i = 0; vs_i < B_DEPTH; vs_i = vs_i + 1) wgt[vs_i] = '0;
    end
  endtask

  // image = 0,1,2,...  (fits INT8 because A_DEPTH-1 < INT8_MAX)
  task vec_img_ramp;
    begin
      for (vs_i = 0; vs_i < A_DEPTH; vs_i = vs_i + 1) img[vs_i] = vs_i[DW-1:0];
    end
  endtask

  task vec_const(input integer iv, input integer wv);
    begin
      for (vs_i = 0; vs_i < A_DEPTH; vs_i = vs_i + 1) img[vs_i] = iv[DW-1:0];
      for (vs_i = 0; vs_i < B_DEPTH; vs_i = vs_i + 1) wgt[vs_i] = wv[DW-1:0];
    end
  endtask

  // T1: image ramp, filter 0 = single 1 at the centre tap, all else zero.
  task vec_identity;
    begin
      vec_clear;
      vec_img_ramp;
      wgt[TAP_CENTRE * P + 0] = 8'sd1;
    end
  endtask

  // T2: one hot pixel in the image interior, every weight = 1.
  task vec_single_hot;
    begin
      vec_clear;
      img[(KS * IFM_W) + KS] = 8'sd1;                       // pixel at (KS, KS)
      for (vs_i = 0; vs_i < B_DEPTH; vs_i = vs_i + 1) wgt[vs_i] = 8'sd1;
    end
  endtask

  // T11: only the very last weight address (tap N_TAP-1, filter P-1) is set.
  task vec_weight_boundary;
    begin
      vec_clear;
      vec_img_ramp;
      wgt[(N_TAP-1) * P + (P-1)] = 8'sd1;                   // ld_addr = B_DEPTH-1
    end
  endtask

  // ==========================================================================
  // 10. Directed tests
  // ==========================================================================

  // ---- T1 ------------------------------------------------------------------
  task test1_identity;
    begin
      $display("\n--- T1: identity kernel (filter 0 = 1 at centre tap %0d) ---", TAP_CENTRE);
      vec_identity;
      run_and_check(t_err);

      // Hand check, independent of the golden model: an identity kernel copies
      // the image interior, and img[a] = a, so the output at (r,c) must be the
      // image index one kernel-centre in from the top-left corner.
      t_n = 0;
      for (t_r = 0; t_r < OFM_H; t_r = t_r + 1)
        for (t_c = 0; t_c < OFM_W; t_c = t_c + 1) begin
          t_hand = (t_r + KS_MID) * IFM_W + (t_c + KS_MID);
          if (got_c[(t_r * OFM_W + t_c) * P + 0] !== t_hand) begin
            if (t_n < MAX_PRINT)
              $display("        HAND-CHECK patch(%0d,%0d) filter 0: got=%0d expected=%0d",
                       t_r, t_c, got_c[(t_r * OFM_W + t_c) * P + 0], t_hand);
            t_n = t_n + 1;
          end
        end
      if (t_n != 0) begin
        $display("        hand check failed on %0d of %0d positions", t_n, N_PATCH);
        t_err = t_err + t_n;
      end

      $display("        write-port monitor: %0d writes to memC, expected %0d (one per output element)",
               wr_count, C_DEPTH);
      $display("        filter 0 output as a %0dx%0d grid (interior of the image, starts at %0d):",
               OFM_H, OFM_W, IFM_W + KS_MID);
      for (t_r = 0; t_r < OFM_H; t_r = t_r + 1) begin
        $write("        ");
        for (t_c = 0; t_c < OFM_W; t_c = t_c + 1)
          $write("%5d", got_c[(t_r * OFM_W + t_c) * P + 0]);
        $write("\n");
      end

      finish_test("T1  identity kernel reproduces the image interior", t_err);
    end
  endtask

  // ---- T2 ------------------------------------------------------------------
  task test2_single_hot;
    begin
      $display("\n--- T2: single hot pixel, all-ones filters ---");
      vec_single_hot;
      run_and_check(t_err);

      // A single hot pixel convolved with an all-ones kernel must light up
      // exactly KS*KS output positions, per filter.
      for (t_f = 0; t_f < P; t_f = t_f + 1) begin
        t_n = 0;
        for (t_p = 0; t_p < N_PATCH; t_p = t_p + 1)
          if (got_c[t_p * P + t_f] !== 0) t_n = t_n + 1;
        if (t_n != KS * KS) begin
          $display("        filter %0d lit %0d positions, expected %0d (patch overlap error)",
                   t_f, t_n, KS * KS);
          t_err = t_err + 1;
        end
      end

      finish_test("T2  single hot pixel gives a KSxKS block of ones", t_err);
    end
  endtask

  // ---- T3 ------------------------------------------------------------------
  task test3_zero_image;
    begin
      $display("\n--- T3: all-zero image, non-zero weights ---");
      vec_clear;
      for (vs_j = 0; vs_j < B_DEPTH; vs_j = vs_j + 1) wgt[vs_j] = INT8_MAX[DW-1:0];
      run_and_check(t_err);

      for (t_p = 0; t_p < C_DEPTH; t_p = t_p + 1)
        if (got_c[t_p] !== 0) begin
          if (t_p < MAX_PRINT)
            $display("        addr %0d is %0d, expected 0 (stuck output / uninitialised memory)",
                     t_p, got_c[t_p]);
          t_err = t_err + 1;
        end

      finish_test("T3  zero image with non-zero weights gives all zeros", t_err);
    end
  endtask

  // ---- T4 ------------------------------------------------------------------
  task test4_all_max;
    begin
      $display("\n--- T4: image and weights all %0d ---", INT8_MAX);
      vec_const(INT8_MAX, INT8_MAX);
      run_and_check(t_err);

      t_hand = N_TAP * INT8_MAX * INT8_MAX;
      for (t_p = 0; t_p < C_DEPTH; t_p = t_p + 1)
        if (got_c[t_p] !== t_hand) t_err = t_err + 1;
      $display("        every output should be %0d * %0d * %0d = %0d",
               N_TAP, INT8_MAX, INT8_MAX, t_hand);

      finish_test("T4  all +INT8_MAX upper range", t_err);
    end
  endtask

  // ---- T5 ------------------------------------------------------------------
  task test5_all_min;
    begin
      $display("\n--- T5: image and weights all %0d  (true worst case) ---", INT8_MIN);
      vec_const(INT8_MIN, INT8_MIN);
      run_and_check(t_err);

      // -128 * -128 = +16384, nine of them = +147456.  This is the largest
      // magnitude the accumulator can ever hold, so it is the value that proves
      // ACC_W is wide enough.  A 19-bit accumulator wraps here; an 18-bit one
      // wraps badly.
      $display("        expecting exactly %0d * (%0d * %0d) = %0d at every address",
               N_TAP, INT8_MIN, INT8_MIN, ACC_WORST);
      for (t_p = 0; t_p < C_DEPTH; t_p = t_p + 1)
        if (got_c[t_p] !== ACC_WORST) begin
          if (t_p < MAX_PRINT)
            $display("        addr %0d: got %0d, expected %0d  (accumulator too narrow?)",
                     t_p, got_c[t_p], ACC_WORST);
          t_err = t_err + 1;
        end
      assert (got_c[0] === ACC_WORST)
        else $display("        ASSERT FAILED: worst-case accumulator not representable in ACC_W=%0d", ACC_W);

      finish_test("T5  all -INT8_MIN worst case, exact value 147456", t_err);
    end
  endtask

  // ---- T6 ------------------------------------------------------------------
  task test6_mixed_signs;
    begin
      $display("\n--- T6: mixed signs, negative accumulators ---");
      vec_clear;
      for (vs_i = 0; vs_i < A_DEPTH; vs_i = vs_i + 1)
        img[vs_i] = ((vs_i % 2) == 0) ?  8'sd100 : -8'sd100;
      for (vs_i = 0; vs_i < B_DEPTH; vs_i = vs_i + 1)
        wgt[vs_i] = ((vs_i % 2) == 0) ? -8'sd120 :  8'sd110;
      run_and_check(t_err);

      t_n = 0;
      for (t_p = 0; t_p < C_DEPTH; t_p = t_p + 1)
        if (exp_c[t_p] < 0) t_n = t_n + 1;
      $display("        %0d of %0d expected results are negative", t_n, C_DEPTH);
      if (t_n == 0) begin
        $display("        ERROR: this test is supposed to produce negative accumulators");
        t_err = t_err + 1;
      end

      finish_test("T6  mixed signs produce correct negative accumulators", t_err);
    end
  endtask

  // ---- T7 ------------------------------------------------------------------
  task test7_back_to_back;
    begin
      $display("\n--- T7: T1 vectors then T2 vectors, no reset between ---");
      t_err = 0;

      vec_identity;
      run_and_check(t_n);
      t_err = t_err + t_n;
      if (t_n != 0) $display("        first inference (T1 vectors) already wrong");

      // Second inference with no reset in between.  If the accumulator is not
      // cleared at k==0 the second run's dot products inherit the first run's
      // residue and every result drifts.
      vec_single_hot;
      run_and_check(t_n);
      t_err = t_err + t_n;
      if (t_n != 0) $display("        second inference (T2 vectors) wrong -> accumulator not cleared between runs");

      cov_hit_bin(COV_B2B);
      finish_test("T7  back-to-back inferences without reset", t_err);
    end
  endtask

  // ---- T8 ------------------------------------------------------------------
  task test8_start_while_busy;
    begin
      $display("\n--- T8: start pulsed while busy (must be ignored) ---");
      vec_identity;

      poison_results;
      load_memories;
      golden_model;
      clear_write_monitor;

      // Injection point comes from the measured run length, not from a
      // compile-time cycle count, so this test follows the architecture.
      t_cov0   = cov[COV_START_BUSY];
      t_inject = inject_point(1, 2);          // halfway through the measured run
      $display("        measured run = %0d cycles -> injecting spurious start at cycle %0d",
               meas_cycles, t_inject);
      run_inference(t_inject, rc_cycles);
      read_all_results;
      scoreboard(t_err);
      check_write_protocol(t_werr);
      t_err = t_err + t_werr;

      if (rc_cycles !== first_cycles) begin
        $display("        run length %0d differs from a clean run (%0d): the spurious start was not ignored",
                 rc_cycles, first_cycles);
        t_err = t_err + 1;
      end else
        $display("        run length %0d cycles, identical to a clean run", rc_cycles);

      // Precondition guard, kept deliberately.  If the pulse never overlapped
      // busy then this test proved nothing, and that must be an error rather
      // than a silent pass -- it is the check that made the hardcoded-timing
      // bug visible in the first place.
      if (cov[COV_START_BUSY] <= t_cov0) begin
        $display("        ERROR: the spurious start pulse never actually overlapped busy");
        $display("               (injected at cycle %0d of a %0d-cycle run -- injection point is wrong)",
                 t_inject, rc_cycles);
        t_err = t_err + 1;
      end else
        $display("        confirmed: start overlapped busy at cycle %0d and was ignored", t_inject);

      finish_test("T8  start while busy is ignored, result unchanged", t_err);
    end
  endtask

  // ---- T9 ------------------------------------------------------------------
  task test9_reset_mid_run;
    begin
      $display("\n--- T9: reset asserted mid-run ---");
      t_err = 0;
      vec_identity;
      poison_results;
      load_memories;

      // Start a run and kill it partway through.  The wait is driven by the
      // measured run length and stops early if the run ends first, so the reset
      // lands inside the inference whatever the architecture's run length is.
      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;
      wait_into_run(1, 3);                    // a third of the way in

      // Precondition guard, kept deliberately: if the reset did not actually
      // land mid-run this test proved nothing and must say so.
      if (busy !== 1'b1) begin
        $display("        ERROR: expected busy high mid-run");
        $display("               (waited %0d cycles into a %0d-cycle run -- injection point is wrong)",
                 wir_target, meas_cycles);
        t_err = t_err + 1;
      end else
        $display("        confirmed: reset asserted %0d cycles into a %0d-cycle run, busy still high",
                 wir_target, meas_cycles);
      rst_n = 1'b0;
      repeat (4) @(negedge clk);
      cov_hit_bin(COV_RST_MID);

      if (busy !== 1'b0) begin
        $display("        ERROR: busy still high during reset");
        t_err = t_err + 1;
      end
      if (done !== 1'b0) begin
        $display("        ERROR: done asserted during reset");
        t_err = t_err + 1;
      end

      rst_n = 1'b1;
      repeat (2) @(negedge clk);

      if (busy !== 1'b0) begin
        $display("        ERROR: busy did not clear after reset release");
        t_err = t_err + 1;
      end

      // Now a completely clean inference.  Anything that survived the reset
      // (counters, accumulator, address pipeline, final_count) shows up here.
      run_and_check(t_n);
      t_err = t_err + t_n;
      if (t_n != 0) $display("        clean run after reset is wrong -> state survived reset");

      finish_test("T9  reset mid-run leaves no state behind", t_err);
    end
  endtask

  // ---- T10 -----------------------------------------------------------------
  task test10_corner_patches;
    begin
      $display("\n--- T10: corner patches %0d, %0d, %0d, %0d ---",
               corner_patch(0), corner_patch(1), corner_patch(2), corner_patch(3));
      // A signed ramp so corner values are large and distinct, with weights
      // that differ per filter so a filter mix-up also shows.
      vec_clear;
      for (vs_i = 0; vs_i < A_DEPTH; vs_i = vs_i + 1)
        img[vs_i] = vs_i - (A_DEPTH / 2);
      for (vs_i = 0; vs_i < B_DEPTH; vs_i = vs_i + 1)
        wgt[vs_i] = ((vs_i % P) + 1) * ((vs_i / P) - KS_MID);
      run_and_check(t_err);

      for (t_n = 0; t_n < N_CORNER; t_n = t_n + 1) begin
        t_p = corner_patch(t_n);
        $write("        patch %2d (row %0d, col %0d):", t_p, t_p / OFM_W, t_p % OFM_W);
        for (t_f = 0; t_f < P; t_f = t_f + 1) begin
          $write("  f%0d=%0d", t_f, got_c[t_p * P + t_f]);
          if (got_c[t_p * P + t_f] !== exp_c[t_p * P + t_f]) begin
            t_err = t_err + 1;
            $write("(WRONG, exp %0d)", exp_c[t_p * P + t_f]);
          end
        end
        $write("\n");
      end

      finish_test("T10 all four corner patches address correctly", t_err);
    end
  endtask

  // ---- T11 -----------------------------------------------------------------
  task test11_weight_boundary;
    begin
      $display("\n--- T11: only weight at tap %0d / filter %0d (ld_addr %0d) is set ---",
               N_TAP-1, P-1, B_DEPTH-1);
      vec_weight_boundary;
      run_and_check(t_err);

      // Hand check, independent of the golden model.  The last tap sits at
      // kernel offset (KS-1, KS-1), so with weight 1 and img[a]=a the output
      // for filter P-1 at (r,c) is just the image pixel at (r+KS-1, c+KS-1).
      // Every other filter must be zero.
      t_n = 0;
      for (t_r = 0; t_r < OFM_H; t_r = t_r + 1)
        for (t_c = 0; t_c < OFM_W; t_c = t_c + 1) begin
          t_hand = (t_r + KS - 1) * IFM_W + (t_c + KS - 1);
          if (got_c[(t_r * OFM_W + t_c) * P + (P-1)] !== t_hand) begin
            if (t_n < MAX_PRINT)
              $display("        HAND-CHECK patch(%0d,%0d) filter %0d: got=%0d expected=%0d",
                       t_r, t_c, P-1, got_c[(t_r * OFM_W + t_c) * P + (P-1)], t_hand);
            t_n = t_n + 1;
          end
          for (t_f = 0; t_f < P-1; t_f = t_f + 1)
            if (got_c[(t_r * OFM_W + t_c) * P + t_f] !== 0) t_n = t_n + 1;
        end
      if (t_n != 0) begin
        $display("        hand check failed %0d times -> off-by-one in the k*P+j weight address",
                 t_n);
        t_err = t_err + t_n;
      end

      finish_test("T11 weight address boundary tap N_TAP-1 / filter P-1", t_err);
    end
  endtask

  // ---- T12 (beyond the required set) ---------------------------------------
  // The interface says loads are only accepted while busy is low.  Nothing above
  // exercises that rule, so drive the load port with garbage in the middle of a
  // run: if any of it reaches memA or memB, the results change.
  task test12_load_while_busy;
    begin
      $display("\n--- T12 (extra): load port must be ignored while busy ---");
      vec_identity;
      poison_results;
      load_memories;
      golden_model;
      clear_write_monitor;

      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;

      // Hammer the load port with values that would visibly corrupt the result.
      for (t_n = 0; t_n < A_DEPTH; t_n = t_n + 1) begin
        @(negedge clk);
        ld_en     = 1'b1;
        ld_sel_ab = t_n[0];
        ld_addr   = t_n[LD_ADDR_W-1:0];
        ld_data   = INT8_MIN[DW-1:0];
      end
      @(negedge clk);
      ld_en = 1'b0; ld_addr = '0; ld_data = '0;
      if (busy !== 1'b1) begin
        $display("        ERROR: run finished before the load attempt completed");
        t_err = 1;
      end else t_err = 0;

      // Let the run finish.
      t_n = 0;
      while (done !== 1'b1 && t_n < TIMEOUT_C) begin
        @(posedge clk); #1; t_n = t_n + 1;
      end
      @(negedge clk);

      read_all_results;
      scoreboard(t_n);
      t_err = t_err + t_n;
      check_write_protocol(t_werr);
      t_err = t_err + t_werr;
      if (t_n != 0)
        $display("        results changed -> the load port was NOT blocked while busy");

      finish_test("T12 load port ignored while busy (extra)", t_err);
    end
  endtask

  // ==========================================================================
  // 11. Randomized regression
  // ==========================================================================
  task random_regression;
    begin
      $display("\n--- Randomized regression: %0d seeds ---", num_seeds);
      rr_fail = 0;

      for (rs_s = 0; rs_s < num_seeds; rs_s = rs_s + 1) begin
        // Reseeding from the seed index makes every seed independently
        // reproducible: if seed 137 fails, re-running reproduces those exact
        // vectors rather than a fresh random set.
        rs_seed = rs_s + 1;
        rs_tmp  = $urandom(rs_seed);

        // Roughly one seed in three forces every value to an extreme.
        //
        // WHY: uniform random INT8 almost never produces a near-overflow
        // accumulator.  Nine products of independent uniform values average
        // toward zero -- typical |accumulator| lands in the low thousands out
        // of a possible 147456 -- so an accumulator that is one or two bits too
        // narrow still returns the right answer on essentially every uniform
        // test and can survive thousands of them.  Forcing all values to
        // -128/+127 drives every product to +/-16384 and every accumulator to
        // within a factor of one of the true worst case, which is the only
        // stimulus that actually exercises the top of the accumulator range.
        rs_extreme = ((rs_s % 3) == 0);

        for (rs_i = 0; rs_i < A_DEPTH; rs_i = rs_i + 1)
          img[rs_i] = rs_extreme
                    ? ($urandom_range(0,1) ? INT8_MAX[DW-1:0] : INT8_MIN[DW-1:0])
                    : ($urandom_range(0, (1<<DW)-1) - (1 << (DW-1)));
        for (rs_i = 0; rs_i < B_DEPTH; rs_i = rs_i + 1)
          wgt[rs_i] = rs_extreme
                    ? ($urandom_range(0,1) ? INT8_MAX[DW-1:0] : INT8_MIN[DW-1:0])
                    : ($urandom_range(0, (1<<DW)-1) - (1 << (DW-1)));

        // Keep the log readable: full detail for the first few failing seeds.
        sb_max_print = (rr_fail < 3) ? MAX_PRINT : 0;
        run_and_check(rr_err);

        if (rr_err != 0) begin
          rr_fail = rr_fail + 1;
          $display("        seed %0d FAILED (%0d mismatch(es), mode=%0s)",
                   rs_s, rr_err, rs_extreme ? "EXTREME" : "uniform");
        end
        total_errors = total_errors + rr_err;

        if (((rs_s + 1) % 50) == 0)
          $display("        ... %0d/%0d seeds done, %0d failing", rs_s + 1, num_seeds, rr_fail);
      end

      sb_max_print = MAX_PRINT;
      tests_run = tests_run + 1;
      if (rr_fail == 0)
        $display("[PASS] RND randomized regression, %0d seeds (%0d extreme-biased)",
                 num_seeds, (num_seeds + 2) / 3);
      else begin
        tests_failed = tests_failed + 1;
        $display("[FAIL] RND randomized regression: %0d of %0d seeds failed", rr_fail, num_seeds);
      end
    end
  endtask

  // ==========================================================================
  // 12. Coverage report + summary
  // ==========================================================================
  task coverage_report;
    begin
      $display("\n============================================================");
      $display(" COVERAGE REPORT   (%0d bins)", NUM_BINS);
      $display("------------------------------------------------------------");
      $display("  %-26s %10s   %s", "BIN", "HITS", "STATUS");
      cr_hit = 0;

      for (cr_b = 0; cr_b < NUM_BINS; cr_b = cr_b + 1) begin
        if (cov[cr_b] > 0) cr_hit = cr_hit + 1;

        if (cr_b < COV_SCALAR_N)
          $display("  %-26s %10d   %0s", bin_name(cr_b), cov[cr_b],
                   (cov[cr_b] > 0) ? "HIT" : "MISS");
      end

      // Indexed groups: summarise, then name any that missed.
      $write("  %-26s %10s   ", "patch_0..N_PATCH-1", "-");
      cr_hit = cr_hit;
      t_n = 0;
      for (cr_b = 0; cr_b < N_PATCH; cr_b = cr_b + 1)
        if (cov[COV_PATCH_BASE + cr_b] > 0) t_n = t_n + 1;
      $display("%0d/%0d %0s", t_n, N_PATCH, (t_n == N_PATCH) ? "HIT" : "MISS");
      if (t_n != N_PATCH)
        for (cr_b = 0; cr_b < N_PATCH; cr_b = cr_b + 1)
          if (cov[COV_PATCH_BASE + cr_b] == 0) $display("        patch %0d MISS", cr_b);

      $write("  %-26s %10s   ", "filter_0..P-1", "-");
      t_n = 0;
      for (cr_b = 0; cr_b < P; cr_b = cr_b + 1)
        if (cov[COV_FILT_BASE + cr_b] > 0) t_n = t_n + 1;
      $display("%0d/%0d %0s", t_n, P, (t_n == P) ? "HIT" : "MISS");

      for (cr_b = 0; cr_b < N_CORNER; cr_b = cr_b + 1)
        $display("  corner_patch_%-13d %10d   %0s", corner_patch(cr_b),
                 cov[COV_CORNER_BASE + cr_b],
                 (cov[COV_CORNER_BASE + cr_b] > 0) ? "HIT" : "MISS");

      cov_pct = (100.0 * cr_hit) / NUM_BINS;
      $display("------------------------------------------------------------");
      $display("  bins hit: %0d / %0d   =  %0.2f%%", cr_hit, NUM_BINS, cov_pct);
      $display("============================================================");
    end
  endtask

  // ==========================================================================
  // Main
  // ==========================================================================
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_conv_top.vcd");
      $dumpvars(0, tb_conv_top);
    end

    for (cr_b = 0; cr_b < NUM_BINS; cr_b = cr_b + 1) cov[cr_b] = 0;
    tests_run    = 0;
    tests_failed = 0;
    total_errors = 0;
    rr_fail      = 0;
    first_cycles = -1;
    sb_max_print = MAX_PRINT;
    drv_timeout  = 0;

    // +seeds=<n> overrides the compile-time NUM_SEEDS parameter.
    if (!$value$plusargs("seeds=%d", num_seeds)) num_seeds = NUM_SEEDS;

    $display("============================================================");
    $display(" conv_top system-level verification environment");
    $display(" IFM %0dx%0d  KS %0d  P %0d  OFM %0dx%0d", IFM_H, IFM_W, KS, P, OFM_H, OFM_W);
    $display(" N_PATCH %0d  N_TAP %0d  DW %0d  ACC_W %0d  LAT %0d", N_PATCH, N_TAP, DW, ACC_W, LAT);
    $display(" A_DEPTH %0d  B_DEPTH %0d  C_DEPTH %0d", A_DEPTH, B_DEPTH, C_DEPTH);
    $display(" nominal 1-MAC length: %0d cycles (watchdog sizing only; the real", NOMINAL_CYCLES);
    $display("                       run length is measured, not assumed)");
    $display(" randomized seeds: %0d", num_seeds);
    $display("============================================================");

    reset_dut;

    // Must run before any test that acts partway through an inference.
    calibrate_run_length;

    test1_identity;
    test2_single_hot;
    test3_zero_image;
    test4_all_max;
    test5_all_min;
    test6_mixed_signs;
    test7_back_to_back;
    test8_start_while_busy;
    test9_reset_mid_run;
    test10_corner_patches;
    test11_weight_boundary;
    test12_load_while_busy;

    random_regression;

    coverage_report;

    $display("\n============================================================");
    $display(" SUMMARY");
    $display("   tests run      : %0d  (12 directed + 1 randomized regression)", tests_run);
    $display("   tests failed   : %0d", tests_failed);
    $display("   random seeds   : %0d   (failed: %0d)", num_seeds, rr_fail);
    $display("   total errors   : %0d", total_errors);
    $display("   measured run   : %0d cycles from start to done", first_cycles);
    if (total_errors == 0 && tests_failed == 0)
      $display("   VERDICT        : *** ALL TESTS PASSED ***");
    else
      $display("   VERDICT        : *** FAILED ***");
    $display("============================================================");

    $finish;
  end

  // Global watchdog: the run must always terminate.
  initial begin
    #200_000_000;
    $display("[FAIL] global watchdog timeout");
    $display("   VERDICT        : *** FAILED (timeout) ***");
    $finish;
  end

endmodule
