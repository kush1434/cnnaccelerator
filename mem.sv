



module mem #(
  parameter int DW    = 8,
  parameter int DEPTH = 64
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

  assign rdata = storage[raddr];

endmodule
