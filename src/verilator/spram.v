module spram_sz #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 8,
    parameter NUMWORDS = 1 << ADDR_WIDTH,
    parameter MEM_INIT_FILE = " ",
    parameter MEM_NAME = "MEM"
) (
    input  wire                  clock,
    input  wire [ADDR_WIDTH-1:0] address,
    input  wire [DATA_WIDTH-1:0] data,
    input  wire                  enable,
    input  wire                  wren,
    output wire [DATA_WIDTH-1:0] q,
    input  wire                  cs
);

reg [DATA_WIDTH-1:0] mem [0:NUMWORDS-1];

initial begin
    // The build copies these files beside the simulation executable.
    if (DATA_WIDTH == 24)
        $readmemh("dsp11b23410_p.hex", mem);
    else if (DATA_WIDTH == 16)
        $readmemh("dsp11b23410_d.hex", mem);
end

assign q = cs ? mem[address] : {DATA_WIDTH{1'b1}};

always @(posedge clock) begin
    if (enable && cs && wren)
        mem[address] <= data;
end

endmodule
