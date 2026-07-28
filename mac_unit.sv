




module mac_unit #(
  parameter int DW    = 8,
  parameter int ACC_W = 20
)(
  input  logic                     clk,
  input  logic                     rst,
  input  logic signed [DW-1:0]     a,
  input  logic signed [DW-1:0]     b,
  input  logic                     valid_in,
  input  logic                     clear_acc,
  output logic signed [ACC_W-1:0]  acc_out,
  output logic                     valid_out
);

  logic signed [(2*DW)-1:0] init_prod;
  logic                     stage1_valid;
  logic                     stage1_clear_acc;


  always_ff @(posedge clk) begin
    if (rst) begin
      init_prod        <= '0;
      stage1_valid     <= 1'b0;
      stage1_clear_acc <= 1'b0;
    end else begin
      init_prod        <= a * b;
      stage1_valid     <= valid_in;
      stage1_clear_acc <= clear_acc;
    end
  end


  always_ff @(posedge clk) begin
    if (rst) begin
      acc_out   <= '0;
      valid_out <= 1'b0;
    end else begin
      valid_out <= stage1_valid;
      if (stage1_valid && stage1_clear_acc)
        acc_out <= init_prod;
      else if (stage1_valid)
        acc_out <= acc_out + init_prod;
    end
  end

endmodule
