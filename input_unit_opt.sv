module input_unit_opt
  import cnn_pkg::*;
#(
  parameter bit USE_TAP_LUT = 0
)(
  input logic clk,
  input logic ld_en,
  input logic [LD_ADDR_W-1:0] ld_addr,
  input logic signed [DW-1:0] ld_data,
  input logic [$clog2(OFM_H)-1:0] out_row,
  input logic [$clog2(OFM_W)-1:0] out_col,
  input logic [TAP_W-1:0] k,
  output logic signed [DW-1:0] a_data
);

  localparam int IFM_SHIFT = $clog2(IFM_W);

  logic [$clog2(KS)-1:0] tap_row, tap_col;
  logic [A_ADDR_W-1:0] a_raddr;
  logic [7:0] a_raddr_full;

  generate
    if (USE_TAP_LUT) begin : g_tap_lut
      always_comb begin
        unique case (k)
          4'd0: begin tap_row = 0; tap_col = 0; end
          4'd1: begin tap_row = 0; tap_col = 1; end
          4'd2: begin tap_row = 0; tap_col = 2; end
          4'd3: begin tap_row = 1; tap_col = 0; end
          4'd4: begin tap_row = 1; tap_col = 1; end
          4'd5: begin tap_row = 1; tap_col = 2; end
          4'd6: begin tap_row = 2; tap_col = 0; end
          4'd7: begin tap_row = 2; tap_col = 1; end
          default: begin tap_row = 2; tap_col = 2; end
        endcase
      end
    end else begin : g_tap_div
      assign tap_row = k / KS;
      assign tap_col = k % KS;
    end
  endgenerate

  assign a_raddr_full = ((out_row + tap_row) << IFM_SHIFT) + (out_col + tap_col);
  assign a_raddr = a_raddr_full[A_ADDR_W-1:0];

`ifndef SYNTHESIS
  always_comb begin
    if (a_raddr_full >= A_DEPTH)
      $error("input_unit_opt: a_raddr=%0d out of range", a_raddr_full);
  end
`endif

  mem #(.DW(DW), .DEPTH(A_DEPTH)) memA (
    .clk(clk),
    .we(ld_en),
    .waddr(ld_addr[A_ADDR_W-1:0]),
    .wdata(ld_data),
    .raddr(a_raddr),
    .rdata(a_data)
  );

endmodule
