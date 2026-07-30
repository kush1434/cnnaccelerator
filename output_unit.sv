









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

  // Registered read port.
  //
  // memC is by far the largest array in the accelerator (C_DEPTH x ACC_W).  A
  // combinational read would force it to synthesise as flops plus a C_DEPTH-way
  // mux; a registered read lets it map onto a block RAM or an SRAM macro
  // instead.  Nothing inside the accelerator reads memC -- this port exists
  // purely for the host to collect results after done -- so the extra cycle
  // costs no throughput.
  //
  // READBACK CONTRACT (changed): present rd_addr and rd_en on one clock edge,
  // rd_data is valid on the NEXT edge.  rd_en is pipelined alongside so the
  // output gate lines up with the data it belongs to.
  //
  // To revert to same-cycle readback, drop .SYNC_READ below and gate rd_data
  // with rd_en instead of rd_en_d.
  mem #(
    .DW        (ACC_W),
    .DEPTH     (C_DEPTH),
    .SYNC_READ (1)
  ) memC (
    .clk   (clk),
    .we    (final_write),
    .waddr (c_addr_d[LAT-1]),
    .wdata (acc_out),
    .raddr (rd_addr),
    .rdata (c_rdata)
  );

  logic rd_en_d;

  always_ff @(posedge clk) begin
    if (!rst_n) rd_en_d <= 1'b0;
    else        rd_en_d <= rd_en;
  end

  assign rd_data = rd_en_d ? c_rdata : '0;

endmodule
