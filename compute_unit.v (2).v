module compute_unit
    import cnn_pkg::*;
    // makes standard parameters from another place available here, the AI i was using said to use this and create a file with the declarations, so i did that as well
(
    input  logic                     clk,
    input  logic                     rst_n,


    input  logic                     ld_en,
    input  logic [LD_ADDR_W-1:0]     ld_addr,
    input  logic signed [DW-1:0]     ld_data,
// ld_en = load enable, when 1, can wrtite filter weight into memB
// ld_addr is where weight will be stored
// ld_data is swhere value is loaded

    input  logic [TAP_W-1:0]         k,
    input  logic [FILTER_W-1:0]      j,
    //k is current tap number
    //j selects current filter

    input  logic                     valid_in,
    input  logic                     clear_acc,
    //valid_in tells MAC everything is valid
    //clear_acc tells MAC new calculation begins

    input  logic signed [DW-1:0]     a_data,
    output logic signed [ACC_W-1:0]  acc_out,
    output logic                     valid_out
    //a_data is current image pixel from input_unit
    //acc_out is the result
    //valid_out indicated acc_out is valid
);

    logic signed [DW-1:0] memB [0:B_DEPTH-1];
//declares filter weight memory, each memory entery is assigned a DW bit value with B_DEPTH(Taps * p)
    logic [B_ADDR_W-1:0]  b_raddr;
    logic signed [DW-1:0] b_data;
//b_raddr holds adresses used to read memB
// b_data holds filter weight(to be connected to MAC's b input)
    integer unsigned b_index;
//used to caluculate weight adress(must be positive)
    always_ff @(posedge clk) begin
        if (ld_en && (ld_addr < B_DEPTH)) begin
        // make sure load is enabled and ld_adder is a valid adress
            memB[ld_addr] <= ld_data;
            //writes ld_data onto memory location
        end
    end

    always_comb begin
        b_index = (k * P) + j;
        //calculates weight-memory adress
        b_raddr = b_index;
//copy calculated adress to memory adress signal
        if (b_index < B_DEPTH) begin
        //make sure calculated adress is inside weight memory
            b_data = memB[b_raddr];
            //read filter weight and place it in b_data
        end else begin
            b_data = '0;
            //if invalid every bit in b_data set to 0
        end
    end

 mac_unit #(
        .DW   (DW),
        .ACC_W(ACC_W)
    ) u_mac (
        .clk      (clk),
        .rst      (!rst_n),
        .a        (a_data),
        .b        (b_data),
        .valid_in (valid_in),
        .clear_acc(clear_acc),
        .acc_out  (acc_out),
        .valid_out(valid_out)
    );
    
    // the AI i was using told me to put this in here to instantiate mac_unit so i js puit it in
endmodule