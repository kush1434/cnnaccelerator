// ============================================================================
// compute_unit.sv  -- OWNER: Kiran
// Holds the four 3x3 filters and the multiply-accumulate unit.
//
// memB stores the weights as a flat 9x4 table, tap-major:
//   address = k*P + j   (tap k, filter j)
// One pixel arrives per cycle from input_unit; one weight is selected here;
// mac_unit multiplies and accumulates over the 9 taps of a patch.
// ============================================================================
import cnn_pkg::*;
module compute_unit (
  input  logic                     clk,
  input  logic                     rst_n,     // active LOW, synchronous
  input  logic                     ld_en,     // weight write enable
  input  logic [LD_ADDR_W-1:0]     ld_addr,
  input  logic signed [DW-1:0]     ld_data,
  input  logic [TAP_W-1:0]         k,         // tap    0..8  (from top)
  input  logic [FILTER_W-1:0]      j,         // filter 0..3  (from top)
  input  logic                     valid_in,  // a term is being fed
  input  logic                     clear_acc, // first tap of a new dot product
  input  logic signed [DW-1:0]     a_data,    // pixel (from input_unit)
  output logic signed [ACC_W-1:0]  acc_out,
  output logic                     valid_out  // LAT cycles after valid_in
);

  logic [B_ADDR_W-1:0]  b_raddr;
  logic signed [DW-1:0] b_data;

  assign b_raddr = k * P + j;                 // row-major into the 9x4 table

  mem #(.DW(DW), .DEPTH(B_DEPTH)) memB (
    .clk   (clk),
    .we    (ld_en),
    .waddr (ld_addr[B_ADDR_W-1:0]),
    .wdata (ld_data),
    .raddr (b_raddr),
    .rdata (b_data)
  );

  mac_unit #(.DW(DW), .ACC_W(ACC_W)) u_mac (
    .clk       (clk),
    .rst       (!rst_n),                      // mac_unit takes active-high rst
    .a         (a_data),
    .b         (b_data),
    .valid_in  (valid_in),
    .clear_acc (clear_acc),
    .acc_out   (acc_out),
    .valid_out (valid_out)
  );

endmodule
