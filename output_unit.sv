import cnn_pkg::*;

module output_unit (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [PATCH_W-1:0]       i,
  input  logic [TAP_W-1:0]         k,
  input  logic                     valid_in,
  input  logic signed [ACC_W-1:0]  acc_out0,
  input  logic signed [ACC_W-1:0]  acc_out1,
  input  logic signed [ACC_W-1:0]  acc_out2,
  input  logic signed [ACC_W-1:0]  acc_out3,
  input  logic                     valid_out,
  input  logic                     rd_en,
  input  logic [C_ADDR_W-1:0]      rd_addr,
  output logic signed [ACC_W-1:0]  rd_data,
  output logic                     final_write
);

  logic                 final_term_now;
  logic                 final_term_d [0:LAT-1];
  logic signed [ACC_W-1:0] c_rdata;

  logic [PATCH_W-1:0]       wr_i;
  logic [FILTER_W-1:0]      wr_filt;
  logic                     wr_active;
  logic signed [ACC_W-1:0]  wr_acc [0:P-1];
  logic [C_ADDR_W-1:0]      wr_addr;
  logic [PATCH_W-1:0]       patch_i_d [0:LAT-1];

  integer s;

  assign final_term_now = valid_in && (k == N_TAP-1);
  assign wr_addr        = wr_i * P + wr_filt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (s = 0; s < LAT; s = s + 1) begin
        final_term_d[s] <= 1'b0;
        patch_i_d[s]    <= '0;
      end
    end else begin
      final_term_d[0] <= final_term_now;
      if (final_term_now)
        patch_i_d[0] <= i;
      for (s = 1; s < LAT; s = s + 1) begin
        final_term_d[s] <= final_term_d[s-1];
        patch_i_d[s]    <= patch_i_d[s-1];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_active <= 1'b0;
      wr_filt   <= '0;
      wr_i      <= '0;
    end else begin
      if (valid_out && final_term_d[LAT-1] && !wr_active) begin
        wr_active <= 1'b1;
        wr_filt   <= '0;
        wr_i      <= patch_i_d[LAT-1];
        wr_acc[0] <= acc_out0;
        wr_acc[1] <= acc_out1;
        wr_acc[2] <= acc_out2;
        wr_acc[3] <= acc_out3;
      end else if (wr_active) begin
        if (wr_filt == P-1)
          wr_active <= 1'b0;
        else
          wr_filt <= wr_filt + 1'b1;
      end
    end
  end

  assign final_write = wr_active;

  mem #(.DW(ACC_W), .DEPTH(C_DEPTH)) memC (
    .clk   (clk),
    .we    (final_write),
    .waddr (wr_addr),
    .wdata (wr_acc[wr_filt]),
    .raddr (rd_addr),
    .rdata (c_rdata)
  );

  assign rd_data = rd_en ? c_rdata : '0;

endmodule
