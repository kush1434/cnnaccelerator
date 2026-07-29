module ifmap_mem #(
    parameter string INIT_FILE = "mem_a.hex"
) (
    input  logic                    clk,
    input  logic [5:0]              read_addr,
    output logic signed [7:0]       read_data
);

    // 64 entries, each containing one signed 8-bit pixel
    logic signed [7:0] mem [0:63];

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    // Registered read: data appears one clock after the address
    always_ff @(posedge clk) begin
        read_data <= mem[read_addr];
    end

endmodule