`timescale 1ns/1ps

module tb_input_unit
  import cnn_pkg::*;
;

  logic                  clk;
  logic                  ld_en;
  logic [5:0]            ld_addr;
  logic signed [DW-1:0]  ld_data;
  logic [5:0]            i;
  logic [3:0]            k;
  logic signed [DW-1:0]  a_data;

  int p, t, n;
  int errors;
  int addr_dut;
  int addr_ref;
  int data_ref;

  input_unit dut (
    .clk(clk),
    .ld_en(ld_en),
    .ld_addr(ld_addr),
    .ld_data(ld_data),
    .i(i),
    .k(k),
    .a_data(a_data)
  );

  always #5 clk = ~clk;

  function automatic int golden_addr(input int patch, input int tap);
    int orow, ocol, trow, tcol;
    begin
      orow = patch / OFM_W;
      ocol = patch % OFM_W;
      trow = tap   / KS;
      tcol = tap   % KS;
      golden_addr = (orow + trow) * IFM_W + (ocol + tcol);
    end
  endfunction

  task automatic show_patch(input int patch);
    int tt;
    int a;
    begin
      $display("");
      $display("  Patch %0d  (OFM row=%0d col=%0d)", patch, patch/OFM_W, patch%OFM_W);
      $display("  +--------+--------+--------+");
      for (tt = 0; tt < 9; tt++) begin
        a = golden_addr(patch, tt);
        if (tt % 3 == 0) $write("  |");
        $write("  %2d    |", a);
        if (tt % 3 == 2) $display("");
      end
      $display("  +--------+--------+--------+");
      $write("  flat order (k=0..8):");
      for (tt = 0; tt < 9; tt++) $write(" %0d", golden_addr(patch, tt));
      $display("");
    end
  endtask

  initial begin
    clk     = 0;
    ld_en   = 0;
    ld_addr = '0;
    ld_data = '0;
    i       = '0;
    k       = '0;
    errors  = 0;

    $display("====================================================");
    $display(" input_unit testbench");
    $display("====================================================");
    $display("1) Loading counting image into memA (value == address)...");
    for (n = 0; n < A_DEPTH; n++) begin
      @(negedge clk);
      ld_en   = 1'b1;
      ld_addr = n[5:0];
      ld_data = n[DW-1:0];
    end
    @(negedge clk);
    ld_en = 1'b0;
    $display("   done. 64 pixels loaded.");

    $display("");
    $display("2) Input image in memA (8x8, row-major, value == address):");
    $display("      col:  0   1   2   3   4   5   6   7");
    $display("          +---+---+---+---+---+---+---+---+");
    for (n = 0; n < IFM_H; n++) begin
      $write("   row %0d |", n);
      for (t = 0; t < IFM_W; t++)
        $write(" %2d|", n*IFM_W + t);
      $display("");
      $display("          +---+---+---+---+---+---+---+---+");
    end
    $display("   Tip: patch 0 is the top-left 3x3 boxed below.");
    $display("        patch 6 starts one row down (addresses 8..).");

    $display("");
    $display("3) Reference windows (from golden equations, not from DUT):");
    show_patch(0);
    show_patch(1);
    show_patch(6);
    $display("");
    $display("   Sanity: patch 6 must start at 8, not 6.");
    $display("   If you see 6 7 8 ..., row/col are swapped.");

    $display("");
    $display("4) Full sweep: all %0d patches x %0d taps = %0d checks",
             N_PATCH, N_TAP, N_PATCH*N_TAP);
    $display("   (printing only mismatches + a short sample)");
    $display("");

    for (p = 0; p < N_PATCH; p++) begin
      for (t = 0; t < N_TAP; t++) begin
        i = p[5:0];
        k = t[3:0];
        #1;

        addr_ref = golden_addr(p, t);
        addr_dut = dut.a_raddr;
        data_ref = addr_ref;

        if (p == 0) begin
          $display("   i=%2d  k=%0d  |  addr DUT=%2d  golden=%2d  |  a_data=%2d",
                   p, t, addr_dut, addr_ref, a_data);
        end

        if (addr_dut != addr_ref) begin
          $display("   FAIL addr  i=%0d k=%0d  DUT=%0d  golden=%0d",
                   p, t, addr_dut, addr_ref);
          errors++;
        end

        if (a_data !== data_ref[DW-1:0]) begin
          $display("   FAIL data  i=%0d k=%0d  a_data=%0d  expected=%0d",
                   p, t, a_data, data_ref);
          errors++;
        end

        if (addr_dut >= A_DEPTH) begin
          $display("   FAIL range i=%0d k=%0d  addr=%0d (>= %0d)",
                   p, t, addr_dut, A_DEPTH);
          errors++;
        end
      end
    end

    $display("");
    $display("5) DUT windows for patches 1 and 6 (what the hardware actually returned):");
    for (p = 1; p <= 6; p += 5) begin
      $write("   patch %0d:", p);
      for (t = 0; t < N_TAP; t++) begin
        i = p[5:0];
        k = t[3:0];
        #1;
        $write(" %0d", dut.a_raddr);
      end
      $display("");
    end

    $display("");
    $display("====================================================");
    if (errors == 0)
      $display(" RESULT: PASS  (%0d address+data checks)", N_PATCH*N_TAP);
    else
      $display(" RESULT: FAIL  (%0d errors)", errors);
    $display("====================================================");
    $finish;
  end

endmodule
