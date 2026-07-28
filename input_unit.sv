







import cnn_pkg::*;

module input_unit (
  input  logic                     clk,
  input  logic                     ld_en,
  input  logic [LD_ADDR_W-1:0]     ld_addr,
  input  logic signed [DW-1:0]     ld_data,
  input  logic [PATCH_W-1:0]       i,
  input  logic [TAP_W-1:0]         k,
  output logic signed [DW-1:0]     a_data
);

  logic [$clog2(OFM_H)-1:0] out_row, out_col;
  logic [$clog2(KS)-1:0]    tap_row, tap_col;
  logic [A_ADDR_W-1:0]      a_raddr;


  assign out_row = i / OFM_W;
  assign out_col = i % OFM_W;
  assign tap_row = k / KS;
  assign tap_col = k % KS;


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

  always_comb begin
    if (a_raddr >= A_DEPTH)
      $error("input_unit: a_raddr=%0d out of range (i=%0d k=%0d)", a_raddr, i, k);
  end
`endif

endmodule
