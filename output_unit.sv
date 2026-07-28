// ============================================================================
// output_unit.sv  -- OWNER: Kush
// Stores completed results, and keeps each result matched to its address.
//
// WHY THE PIPELINE: mac_unit takes LAT cycles. By the time a result emerges,
// the counters i/j/k have already advanced. Writing to memC[i*P+j] with the
// CURRENT i and j would put the answer in the wrong slot, so the destination
// address and the last-tap marker are delayed by exactly LAT cycles to travel
// alongside the data through the MAC.
// ============================================================================
import cnn_pkg::*;
module output_unit (
  input  logic                     clk,
  input  logic                     rst_n,     // active LOW, synchronous
  input  logic [PATCH_W-1:0]       i,         // patch  (from top)
  input  logic [FILTER_W-1:0]      j,         // filter (from top)
  input  logic [TAP_W-1:0]         k,         // tap    (from top)
  input  logic                     valid_in,  // a term is being fed
  input  logic signed [ACC_W-1:0]  acc_out,   // from compute_unit
  input  logic                     valid_out, // from compute_unit
  input  logic                     rd_en,
  input  logic [C_ADDR_W-1:0]      rd_addr,
  output logic signed [ACC_W-1:0]  rd_data,
  output logic                     final_write // one pulse per completed result
);

  logic [C_ADDR_W-1:0]  c_addr_now;
  logic                 final_term_now;
  logic [C_ADDR_W-1:0]  c_addr_d   [0:LAT-1];
  logic                 final_term_d [0:LAT-1];
  logic signed [ACC_W-1:0] c_rdata;
  integer s;

  assign c_addr_now     = i * P + j;
  assign final_term_now = valid_in && (k == N_TAP-1);

  // delay both by LAT, built from the parameter so a different MAC latency
  // only requires changing cnn_pkg.sv
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

  // write once per completed element, not once per term (9x less write activity)
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
