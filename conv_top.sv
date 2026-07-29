module conv_top
  import cnn_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     start,
  output logic                     done,
  output logic                     busy,
  input  logic                     ld_en,
  input  logic                     ld_sel_ab,
  input  logic [LD_ADDR_W-1:0]     ld_addr,
  input  logic signed [DW-1:0]     ld_data,
  input  logic                     rd_en,
  input  logic [C_ADDR_W-1:0]      rd_addr,
  output logic signed [ACC_W-1:0]  rd_data
);

  logic [PATCH_W-1:0] i;
  logic [FILTER_W-1:0] j;
  logic [TAP_W-1:0] k;
  logic idle, inputs_done, preloading;
  logic valid_in, clear_acc;
  logic image_ld_en, weight_ld_en;
  logic signed [DW-1:0] a_data;
  logic signed [ACC_W-1:0] acc_out;
  logic valid_out, final_write;
  logic start_window, window_ready;
  logic [C_ADDR_W-1:0] final_count;

  assign busy = !idle;
  assign valid_in = !idle && !inputs_done && !preloading;
  assign clear_acc = valid_in && (k == '0);
  assign image_ld_en = ld_en && !ld_sel_ab && idle;
  assign weight_ld_en = ld_en && ld_sel_ab && idle;
  assign start_window = start && idle;

  input_unit u_input_unit (
    .clk(clk), .rst_n(rst_n), .ld_en(image_ld_en), .ld_addr(ld_addr),
    .ld_data(ld_data), .start_window(start_window), .i(i), .j(j), .k(k),
    .valid_in(valid_in), .window_ready(window_ready), .a_data(a_data)
  );

  compute_unit u_compute_unit (
    .clk(clk), .rst_n(rst_n), .ld_en(weight_ld_en), .ld_addr(ld_addr),
    .ld_data(ld_data), .k(k), .j(j), .valid_in(valid_in),
    .clear_acc(clear_acc), .a_data(a_data), .acc_out(acc_out),
    .valid_out(valid_out)
  );

  output_unit u_output_unit (
    .clk(clk), .rst_n(rst_n), .i(i), .j(j), .k(k), .valid_in(valid_in),
    .acc_out(acc_out), .valid_out(valid_out), .rd_en(rd_en),
    .rd_addr(rd_addr), .rd_data(rd_data), .final_write(final_write)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      idle <= 1'b1;
      preloading <= 1'b0;
      inputs_done <= 1'b0;
      done <= 1'b0;
      i <= '0; j <= '0; k <= '0; final_count <= '0;
    end else begin
      done <= 1'b0;
      if (start && idle) begin
        idle <= 1'b0;
        preloading <= 1'b1;
        inputs_done <= 1'b0;
        i <= '0; j <= '0; k <= '0; final_count <= '0;
      end else if (!idle) begin
        if (preloading) begin
          if (window_ready) preloading <= 1'b0;
        end else if (!inputs_done) begin
          if (k == N_TAP-1) begin
            k <= '0;
            if (j == P-1) begin
              j <= '0;
              if (i == N_PATCH-1) inputs_done <= 1'b1;
              else i <= i + 1'b1;
            end else j <= j + 1'b1;
          end else k <= k + 1'b1;
        end

        if (final_write) begin
          if (final_count == C_DEPTH-1) begin
            final_count <= '0;
            idle <= 1'b1;
            preloading <= 1'b0;
            inputs_done <= 1'b0;
            done <= 1'b1;
          end else final_count <= final_count + 1'b1;
        end
      end
    end
  end
endmodule
