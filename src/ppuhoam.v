module ppuhoam (
    input clock,
    input [4:0] address,
    input [7:0] data,
    input wren,
    output [7:0] q
);

`ifndef VERILATOR

//reg [7:0] mem [0:31];
//reg [7:0] dout;
//
//assign q = dout;
//
//always @(posedge clock) begin
//    dout <= mem[address];
//    if (wren)
//        mem[address] <= data;
//end

Gowin_SP_HOAM mem(.dout(q), .clk(clock), .oce(), .ce(1'b1), .reset(1'b0), .wre(wren), .ad(address), .din(data));

`else

reg [7:0] mem [0:31] /* synthesis syn_ramstyle="distributed_ram" */;
reg [7:0] dout;

assign q = dout;

always @(posedge clock) begin
    if (wren)
        mem[address] <= data;
    else
        dout <= mem[address];
end

`endif

endmodule
