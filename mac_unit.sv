// ============================================================================
// mac_unit.sv -- multiply-accumulate, 2-stage pipeline. Unchanged from Part 1
// except ACC_W now defaults to 20 instead of 32 (see cnn_pkg.sv derivation).
// NOTE: takes ACTIVE-HIGH rst. Callers drive .rst(!rst_n).
// ============================================================================
module mac_unit #(
  parameter int DW    = 8,
  parameter int ACC_W = 20
)(
  input  logic                     clk,
  input  logic                     rst,        // active HIGH, synchronous
  input  logic signed [DW-1:0]     a,
  input  logic signed [DW-1:0]     b,
  input  logic                     valid_in,
  input  logic                     clear_acc,
  output logic signed [ACC_W-1:0]  acc_out,
  output logic                     valid_out
);

  logic signed [(2*DW)-1:0] init_prod;
  logic                     stage1_valid;
  logic                     stage1_clear_acc;

  // stage 1: multiply
  always_ff @(posedge clk) begin
    if (rst) begin
      init_prod        <= '0;
      stage1_valid     <= 1'b0;
      stage1_clear_acc <= 1'b0;
    end else begin
      init_prod        <= a * b;
      stage1_valid     <= valid_in;
      stage1_clear_acc <= clear_acc;
    end
  end

  // stage 2: accumulate
  always_ff @(posedge clk) begin
    if (rst) begin
      acc_out   <= '0;
      valid_out <= 1'b0;
    end else begin
      valid_out <= stage1_valid;
      if (stage1_valid && stage1_clear_acc)
        acc_out <= init_prod;                 // first tap: start fresh
      else if (stage1_valid)
        acc_out <= acc_out + init_prod;       // taps 1..8: accumulate
    end
  end

endmodule
