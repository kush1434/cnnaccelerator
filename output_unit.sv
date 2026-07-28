









import cnn_pkg::*;
module output_unit (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [PATCH_W-1:0]       i,
  input  logic [FILTER_W-1:0]      j,
  input  logic [TAP_W-1:0]         k,
  input  logic                     valid_in,
  input  logic signed [ACC_W-1:0]  acc_out,
  input  logic                     valid_out,
  input  logic                     rd_en,
  input  logic [C_ADDR_W-1:0]      rd_addr,
  output logic signed [ACC_W-1:0]  rd_data,
  output logic                     final_write
);

  logic [C_ADDR_W-1:0]  c_addr_now;
  logic                 final_term_now;
  logic [C_ADDR_W-1:0]  c_addr_d   [0:LAT-1];
  logic                 final_term_d [0:LAT-1];
  logic signed [ACC_W-1:0] c_rdata;
  integer s;

  assign c_addr_now     = i * P + j;
  assign final_term_now = valid_in && (k == N_TAP-1);



  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (s = 0; s < LAT; s = s + 1) begin
        c_addr_d[s]     <= '0;
        final_term_d[s] <= 1'b0;
      end
    end else begin
      c_addr_d[0]     <= c_addr_now;
      final_term_d[0] <= final_term_now;
      for (s = 1; s < LAT; s = s + 1) begin
        c_addr_d[s]     <= c_addr_d[s-1];
        final_term_d[s] <= final_term_d[s-1];
      end
    end
  end


  assign final_write = valid_out && final_term_d[LAT-1];

  mem #(.DW(ACC_W), .DEPTH(C_DEPTH)) memC (
    .clk   (clk),
    .we    (final_write),
    .waddr (c_addr_d[LAT-1]),
    .wdata (acc_out),
    .raddr (rd_addr),
    .rdata (c_rdata)
  );

  assign rd_data = rd_en ? c_rdata : '0;

endmodule
