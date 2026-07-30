



module mem #(
  parameter int DW    = 8,
  parameter int DEPTH = 64,

  // Read port style.
  //
  //   SYNC_READ = 0  combinational read -- rdata is valid in the SAME cycle
  //                  as raddr.  This is the historical behaviour and remains
  //                  the default, so every existing instance is unchanged.
  //
  //   SYNC_READ = 1  registered read -- rdata is valid ONE cycle after raddr.
  //
  // Why the option exists: a combinational read cannot be implemented by a
  // block RAM or an SRAM macro, because no such array returns data in the same
  // cycle the address is presented.  Synthesis therefore has no choice but to
  // build the array out of flops plus a DEPTH-way read mux.  For the 144x20
  // result memory that came to ~9,000 cells, about two thirds of the entire
  // accelerator, of which only 2,880 were the storage flops themselves and the
  // rest was the 144-way mux.
  //
  // SYNC_READ = 1 is the canonical simple-dual-port shape (one write port, one
  // registered read port) that infers a BRAM on FPGA and maps onto a single
  // port SRAM on ASIC.
  //
  // Read-during-write to the same address returns the OLD contents in both
  // modes (read-before-write), so the only difference is the extra cycle.
  parameter int SYNC_READ = 0
)(
  input  logic                     clk,
  input  logic                     we,
  input  logic [$clog2(DEPTH)-1:0] waddr,
  input  logic signed [DW-1:0]     wdata,
  input  logic [$clog2(DEPTH)-1:0] raddr,
  output logic signed [DW-1:0]     rdata
);

  logic signed [DW-1:0] storage [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (we) storage[waddr] <= wdata;
  end

  generate
    if (SYNC_READ != 0) begin : g_sync_read
      always_ff @(posedge clk) rdata <= storage[raddr];
    end else begin : g_comb_read
      assign rdata = storage[raddr];
    end
  endgenerate

endmodule
