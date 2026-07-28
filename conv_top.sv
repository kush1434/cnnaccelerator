module conv_top #(
    // Main configuration
    parameter int IMAGE_HEIGHT = 5,
    parameter int IMAGE_WIDTH  = 5,
    parameter int FILTER_SIZE  = 3,
    parameter int DW           = 8,
    parameter int ACC_W        = 32,

    // Derived dimensions
    parameter int IMAGE_DEPTH =
        IMAGE_HEIGHT * IMAGE_WIDTH,

    parameter int FILTER_DEPTH =
        FILTER_SIZE * FILTER_SIZE,

    parameter int OUTPUT_HEIGHT =
        IMAGE_HEIGHT - FILTER_SIZE + 1,

    parameter int OUTPUT_WIDTH =
        IMAGE_WIDTH - FILTER_SIZE + 1,

    parameter int OUTPUT_DEPTH =
        OUTPUT_HEIGHT * OUTPUT_WIDTH,

    // Address widths
    parameter int LOAD_ADDR_W =
        (IMAGE_DEPTH <= 1) ? 1 : $clog2(IMAGE_DEPTH),

    parameter int OUTPUT_ADDR_W =
        (OUTPUT_DEPTH <= 1) ? 1 : $clog2(OUTPUT_DEPTH)
)(
    input  logic clk,
    input  logic rst,

    input  logic start,
    output logic busy,
    output logic done,

    // Load image or filter
    input  logic                     ld_en,
    input  logic                     ld_sel_ab,
    input  logic [LOAD_ADDR_W-1:0]   ld_addr,
    input  logic signed [DW-1:0]     ld_data,

    // Read convolution output
    input  logic                     rd_en,
    input  logic [OUTPUT_ADDR_W-1:0] rd_addr,
    output logic signed [ACC_W-1:0]  rd_data
);

    localparam int FILTER_ADDR_W =
        (FILTER_DEPTH <= 1) ? 1 : $clog2(FILTER_DEPTH);

    //--------------------------------------------------
    // Controller state

    logic idle;
    logic inputs_done;

    logic [OUTPUT_ADDR_W-1:0] i;
    logic [FILTER_ADDR_W-1:0] k;

    //--------------------------------------------------
    // Loading controls

    logic image_ld_en;
    logic filter_ld_en;

    //--------------------------------------------------
    // Datapath controls

    logic valid_in;
    logic clear_acc;
    logic last_tap;

    //--------------------------------------------------
    // Datapath signals

    logic signed [DW-1:0]    a_data;
    logic signed [ACC_W-1:0] acc_out;
    logic                    valid_out;

    //--------------------------------------------------
    // Output controls

    logic [OUTPUT_ADDR_W-1:0] output_waddr;

    //--------------------------------------------------
    // Basic control assignments

    assign busy = !idle;

    // ld_sel_ab:
    // 0 = image
    // 1 = filter
    assign image_ld_en  =
        ld_en && !ld_sel_ab && idle;

    assign filter_ld_en =
        ld_en && ld_sel_ab && idle;

    // Send one image/filter pair during every active tap.
    assign valid_in =
        !idle && !inputs_done;

    // Clear the accumulator before the first tap of each patch.
    assign clear_acc =
        valid_in && (k == 0);

    // Marks the ninth/last multiplication of the dot product.
    assign last_tap =
        valid_in && (k == FILTER_DEPTH - 1);

    //--------------------------------------------------
    // Input unit
    //
    // input_unit owns:
    //   - memA
    //   - image loading
    //   - im2col address calculation
    //
    // It outputs one selected image pixel as a_data.

    input_unit input_unit_inst (
        .clk     (clk),

        .ld_en   (image_ld_en),
        .ld_addr (ld_addr),
        .ld_data (ld_data),

        .i       (i),
        .k       (k),

        .a_data  (a_data)
    );

    //--------------------------------------------------
    // Compute unit
    //
    // compute_unit owns:
    //   - filter memory
    //   - filter loading
    //   - MAC accumulator
    //
    // valid_out must indicate that one complete dot
    // product/result is ready.

    compute_unit compute_unit_inst (
        .clk       (clk),
        .rst       (rst),

        .ld_en     (filter_ld_en),
        .ld_addr   (ld_addr[FILTER_ADDR_W-1:0]),
        .ld_data   (ld_data),

        .k         (k),
        .a_data    (a_data),

        .valid_in  (valid_in),
        .clear_acc (clear_acc),
        .last_tap  (last_tap),

        .acc_out   (acc_out),
        .valid_out (valid_out)
    );

    //--------------------------------------------------
    // Output unit
    //
    // output_unit owns output memory.
    // Each valid_out pulse writes one convolution result.

    output_unit output_unit_inst (
        .clk        (clk),
        .rst        (rst),

        .write_en   (valid_out),
        .write_addr (output_waddr),
        .write_data (acc_out),

        .rd_en      (rd_en),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data)
    );

    //--------------------------------------------------
    // Controller
    //
    // i = output position
    // k = filter tap within the 3x3 window

    always_ff @(posedge clk) begin
        if (rst) begin
            idle         <= 1'b1;
            inputs_done  <= 1'b0;
            done         <= 1'b0;

            i            <= '0;
            k            <= '0;
            output_waddr <= '0;
        end
        else begin
            // done is normally a one-cycle pulse.
            done <= 1'b0;

            //--------------------------------------------------
            // Start a new convolution

            if (start && idle) begin
                idle         <= 1'b0;
                inputs_done  <= 1'b0;

                i            <= '0;
                k            <= '0;
                output_waddr <= '0;
            end

            //--------------------------------------------------
            // Send image/filter values into the compute unit

            else if (!idle && !inputs_done) begin
                if (k == FILTER_DEPTH - 1) begin
                    k <= '0;

                    if (i == OUTPUT_DEPTH - 1) begin
                        // All input terms have entered the
                        // computation pipeline.
                        inputs_done <= 1'b1;
                    end
                    else begin
                        i <= i + 1'b1;
                    end
                end
                else begin
                    k <= k + 1'b1;
                end
            end

            //--------------------------------------------------
            // Count completed dot products

            if (!idle && valid_out) begin
                if (output_waddr == OUTPUT_DEPTH - 1) begin
                    // Final result has been stored.
                    idle         <= 1'b1;
                    inputs_done  <= 1'b0;
                    done         <= 1'b1;
                    output_waddr <= '0;
                end
                else begin
                    output_waddr <= output_waddr + 1'b1;
                end
            end
        end
    end

endmodule
