module dpram #(
    parameter ADDR_WIDTH = 7,
    parameter DATA_WIDTH = 8
) (
    input wire clock,
    input wire [DATA_WIDTH-1:0] data_a,
    input wire [DATA_WIDTH-1:0] data_b,
    input wire [ADDR_WIDTH-1:0] address_a,
    input wire [ADDR_WIDTH-1:0] address_b,
    input wire wren_b,
    input wire wren_a,
    output reg [DATA_WIDTH-1:0] q_a,
    output reg [DATA_WIDTH-1:0] q_b
);

reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH)-1];

always @(posedge clock) begin
    if (wren_a)
        mem[address_a] <= data_a;
    else
        q_a <= mem[address_a];

    if (wren_b)
        mem[address_b] <= data_b;
    else
        q_b <= mem[address_b];
end

endmodule
