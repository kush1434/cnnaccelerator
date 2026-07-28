// ============================================================================
// conv_top.sv  -- OWNER: Toprak
// Top level: counters, control FSM, load port, and the three sub-units.
//
// Adapted from Part 1 matmul_top. The loop nest is unchanged in structure:
//   i = patch  (was: row of A)      0..35
//   j = filter (was: col of B)      0..3
//   k = tap    (was: shared dim)    0..8
// A convolution is the same GEMM with a different row-addressing function.
// ============================================================================
import cnn_pkg::*;
module conv_top (
  input  logic                     clk,
  input  logic                     rst_n,     // active LOW, synchronous
  input  logic                     start,     // 1-cycle pulse
  output logic                     busy,
  output logic                     done,      // 1-cycle pulse
  input  logic                     ld_en,
  input  logic                     ld_sel_ab, // 0 = image, 1 = weights
  input  logic [LD_ADDR_W-1:0]     ld_addr,
  input  logic signed [DW-1:0]     ld_data,
  input  logic                     rd_en,
  input  logic [C_ADDR_W-1:0]      rd_addr,
  output logic signed [ACC_W-1:0]  rd_data
);

  localparam int COUNT_W = $clog2(C_DEPTH + 1);

  // ---- controller state ---------------------------------------------------
  logic                  idle, inputs_done;
  logic [PATCH_W-1:0]    i;
  logic [FILTER_W-1:0]   j;
  logic [TAP_W-1:0]      k;
  logic [COUNT_W-1:0]    final_count;

  // ---- datapath -----------------------------------------------------------
  logic                    valid_in, clear_acc;
  logic signed [DW-1:0]    a_data;
  logic signed [ACC_W-1:0] acc_out;
  logic                    valid_out, final_write;
  logic                    image_ld_en, filter_ld_en;

  assign busy         = !idle;
  assign image_ld_en  = ld_en && !ld_sel_ab && idle;
  assign filter_ld_en = ld_en &&  ld_sel_ab && idle;

  assign valid_in  = !idle && !inputs_done;
  assign clear_acc = valid_in && (k == 0);    // first tap of each dot product

  // ---- sub-units ----------------------------------------------------------
  input_unit u_input (
    .clk(clk), .ld_en(image_ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
    .i(i), .k(k), .a_data(a_data)
  );

  compute_unit u_compute (
    .clk(clk), .rst_n(rst_n),
    .ld_en(filter_ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
    .k(k), .j(j), .valid_in(valid_in), .clear_acc(clear_acc),
    .a_data(a_data), .acc_out(acc_out), .valid_out(valid_out)
  );

  output_unit u_output (
    .clk(clk), .rst_n(rst_n),
    .i(i), .j(j), .k(k), .valid_in(valid_in),
    .acc_out(acc_out), .valid_out(valid_out),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
    .final_write(final_write)
  );

  // ---- controller ---------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      idle <= 1'b1; inputs_done <= 1'b0; done <= 1'b0;
      i <= '0; j <= '0; k <= '0; final_count <= '0;
    end else begin
      done <= 1'b0;                            // normally low

      if (start && idle) begin
        idle <= 1'b0; inputs_done <= 1'b0;
        i <= '0; j <= '0; k <= '0; final_count <= '0;
      end
      else if (!idle && !inputs_done) begin
        if (k == N_TAP-1) begin
          k <= '0;
          if (j == P-1) begin
            j <= '0;
            if (i == N_PATCH-1) inputs_done <= 1'b1;
            else                i <= i + 1'b1;
          end else j <= j + 1'b1;
        end else k <= k + 1'b1;
      end

      // count completed results; one pulse per element, not per term
      if (!idle && final_write) begin
        if (final_count == C_DEPTH-1) begin
          final_count <= '0;
          idle        <= 1'b1;
          inputs_done <= 1'b0;
          done        <= 1'b1;
        end else final_count <= final_count + 1'b1;
      end
    end
  end

endmodule
