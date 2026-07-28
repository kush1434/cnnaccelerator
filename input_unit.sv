// ============================================================================
// input_unit.sv  -- OWNER: Nitya
// Holds the raw 8x8 image and computes the im2col read address.
//
// The im2col matrix (36 x 9) is NEVER built. memA holds the 64 pixels exactly
// as loaded; this module computes, each cycle, which pixel patch i / tap k
// needs. That is what replaces a 324-entry expansion buffer.
// ============================================================================
import cnn_pkg::*;                            // OUTSIDE the header: yosys cannot
                                              // parse `module x import pkg::*;`
module input_unit (
  input  logic                     clk,
  input  logic                     ld_en,     // image write enable
  input  logic [LD_ADDR_W-1:0]     ld_addr,
  input  logic signed [DW-1:0]     ld_data,
  input  logic [PATCH_W-1:0]       i,         // patch index 0..35   (from top)
  input  logic [TAP_W-1:0]         k,         // tap index   0..8    (from top)
  output logic signed [DW-1:0]     a_data     // one pixel, combinational
);

  logic [$clog2(OFM_H)-1:0] out_row, out_col;
  logic [$clog2(KS)-1:0]    tap_row, tap_col;
  logic [A_ADDR_W-1:0]      a_raddr;

  // decode the flat counters into 2-D positions
  assign out_row = i / OFM_W;                 // which output row   0..5
  assign out_col = i % OFM_W;                 // which output col   0..5
  assign tap_row = k / KS;                    // which kernel row   0..2
  assign tap_col = k % KS;                    // which kernel col   0..2

  // patch corner + offset within the patch, flattened row-major
  assign a_raddr = (out_row + tap_row) * IFM_W + (out_col + tap_col);

  mem #(.DW(DW), .DEPTH(A_DEPTH)) memA (
    .clk   (clk),
    .we    (ld_en),
    .waddr (ld_addr[A_ADDR_W-1:0]),
    .wdata (ld_data),
    .raddr (a_raddr),
    .rdata (a_data)
  );

`ifndef SYNTHESIS
  // with PAD=0 the counter bounds guarantee this; if it fires, i or k is wrong
  always_comb begin
    if (a_raddr >= A_DEPTH)
      $error("input_unit: a_raddr=%0d out of range (i=%0d k=%0d)", a_raddr, i, k);
  end
`endif

endmodule
