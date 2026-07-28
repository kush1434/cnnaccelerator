
import cnn_pkg::*;
// kush's claude flagged this as having to be here instead of after the module decleration
module compute_unit_4mac (
    input  logic                     clk,
    input  logic                     rst_n,


    input  logic                     ld_en,
    input  logic [LD_ADDR_W-1:0]     ld_addr,
    input  logic signed [DW-1:0]     ld_data,


    input  logic [TAP_W-1:0]         k,


    input  logic                     valid_in,
    input  logic                     clear_acc,


    input  logic signed [DW-1:0]     a_data,


    output logic signed [ACC_W-1:0]  acc_out0,
    output logic signed [ACC_W-1:0]  acc_out1,
    output logic signed [ACC_W-1:0]  acc_out2,
    output logic signed [ACC_W-1:0]  acc_out3,

    //make four seperate outpuits, one for each AMC working in parallel
    output logic                     valid_out
);

    localparam int NUM_MACS = 4;
//declarre amounmt of MACs(filters) we are gonna be

    logic signed [DW-1:0] memB [0:B_DEPTH-1];
//temp memory that js stores filter weights
    logic signed [DW-1:0] b_data [0:NUM_MACS-1];
//make one weight signal for each MAC
    logic signed [ACC_W-1:0] mac_acc [0:NUM_MACS-1];
//make one accumulator resutl signal for each MAC
    logic [NUM_MACS-1:0] mac_valid;
//create one valid bit per MAC
    integer f;
//f counts the numebr of loops

    always_ff @(posedge clk) begin
        if (ld_en && (ld_addr < B_DEPTH)) begin
            memB[ld_addr] <= ld_data;
        end
    end
//write filter weight into memB on rising edge


    always_comb begin
        for (f = 0; f < NUM_MACS; f = f + 1) begin
            if (((k * P) + f) < B_DEPTH) begin
                b_data[f] = memB[(k * P) + f];
            end else begin
                b_data[f] = '0;
            end
        end
    end
//selects one filter weight per mac based on current k(tap) value


    genvar g;
// this basically makes it so that I can make 4 seperate mac units without having to do the declerations 4 times 
    generate
        for (g = 0; g < NUM_MACS; g = g + 1) begin : GEN_MACS
            mac_unit #(
                .DW   (DW),
                .ACC_W(ACC_W)
            ) u_mac (
                .clk      (clk),
                .rst      (!rst_n),

          
                .a        (a_data),

       
                .b        (b_data[g]),

                .valid_in (valid_in),
                .clear_acc(clear_acc),

                .acc_out  (mac_acc[g]),
                .valid_out(mac_valid[g])
            );
        end
    endgenerate


    assign acc_out0 = mac_acc[0];
    assign acc_out1 = mac_acc[1];
    assign acc_out2 = mac_acc[2];
    assign acc_out3 = mac_acc[3];


    assign valid_out = mac_valid[0];

endmodule