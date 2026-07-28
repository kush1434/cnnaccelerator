








import cnn_pkg::*;
module compute_unit (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     ld_en,
  input  logic [LD_ADDR_W-1:0]     ld_addr,
  input  logic signed [DW-1:0]     ld_data,
  input  logic [TAP_W-1:0]         k,
  input  logic [FILTER_W-1:0]      j,
  input  logic                     valid_in,
  input  logic                     clear_acc,
  input  logic signed [DW-1:0]     a_data,
  output logic signed [ACC_W-1:0]  acc_out,
  output logic                     valid_out
);

  logic [B_ADDR_W-1:0]  b_raddr;
  logic signed [DW-1:0] b_data;

  assign b_raddr = k * P + j;

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
    .rst       (!rst_n),
    .a         (a_data),
    .b         (b_data),
    .valid_in  (valid_in),
    .clear_acc (clear_acc),
    .acc_out   (acc_out),
    .valid_out (valid_out)
  );

endmodule
