module input_unit
  import cnn_pkg::*;
(
  input  logic                  clk,
  input  logic                  ld_en,
  input  logic [5:0]            ld_addr,
  input  logic signed [DW-1:0]  ld_data,
  input  logic [5:0]            i,
  input  logic [3:0]            k,
  output logic signed [DW-1:0]  a_data
);

  logic [2:0] out_row;
  logic [2:0] out_col;
  logic [1:0] tap_row;
  logic [1:0] tap_col;
  logic [5:0] a_raddr;
  logic [7:0] a_raddr_full;

  assign out_row = i / OFM_W;
  assign out_col = i % OFM_W;
  assign tap_row = k / KS;
  assign tap_col = k % KS;

  assign a_raddr_full = (out_row + tap_row) * IFM_W + (out_col + tap_col);
  assign a_raddr      = a_raddr_full[5:0];

  // synopsys translate_off
  always @(*) begin
    if (a_raddr_full >= 8'd64)
      $error("input_unit: a_raddr=%0d out of range (i=%0d k=%0d)", a_raddr_full, i, k);
  end
  // synopsys translate_on

  mem #(
    .DW(DW),
    .DEPTH(A_DEPTH)
  ) memA (
    .clk  (clk),
    .we   (ld_en),
    .waddr(ld_addr),
    .wdata(ld_data),
    .raddr(a_raddr),
    .rdata(a_data)
  );

endmodule
