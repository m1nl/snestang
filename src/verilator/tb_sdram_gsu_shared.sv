`timescale 1ns/1ps
// Sparse SDR SDRAM pin model: CL=2, one-word bursts, per-bank active rows.
// Only words used by this directed test are stored.
module gsu_test_sdram #(parameter ROW_BITS=13) (
    input clk, input [12:0] addr, input [1:0] ba, dqm,
    input cs_n, ras_n, cas_n, we_n, inout [15:0] dq
);
    reg [ROW_BITS-1:0] row [0:3];
    reg [23:0] addresses [0:63];
    reg [15:0] words [0:63];
    integer used=0;
    reg [2:0] read_valid=0;
    reg [15:0] rd0, rd1, rd2;
    wire [23:0] word_address = (24'(ba) << (ROW_BITS+9)) |
                               (24'(row[ba]) << 9) | 24'(addr[8:0]);
    function integer find(input [23:0] address);
        integer i;
        begin
            find=-1;
            for(i=0;i<used;i=i+1) if(addresses[i]==address) find=i;
        end
    endfunction
    task put(input [23:0] address, input [15:0] value);
        integer i;
        begin
            i=find(address);
            if(i<0) begin
                if(used==64) $fatal(1,"Sparse memory full");
                i=used; used=used+1; addresses[i]=address;
            end
            words[i]=value;
        end
    endtask
    function [15:0] get(input [23:0] address);
        integer i;
        begin
            i=find(address);
            if(i<0) $fatal(1,"Read from unexpected physical word %h",address);
            get=words[i];
        end
    endfunction
    integer slot;
    always @(posedge clk) begin
        read_valid <= {read_valid[1:0],1'b0};
        rd1 <= rd0; rd2 <= rd1;
        if(!cs_n) case({ras_n,cas_n,we_n})
            3'b011: row[ba] <= addr[ROW_BITS-1:0];
            3'b101: begin rd0 <= get(word_address); read_valid[0] <= 1; end
            3'b100: begin
                slot=find(word_address);
                if(slot<0) $fatal(1,"Write to unexpected physical word %h",word_address);
                if(!dqm[0]) words[slot][7:0]=dq[7:0];
                if(!dqm[1]) words[slot][15:8]=dq[15:8];
            end
            default: ;
        endcase
    end
    assign dq=read_valid[2] ? rd2 : 16'bz;
endmodule

module tb_sdram_gsu_shared;
    parameter DONE_DELAY=0;
`ifdef SDRAM_16M
    localparam ROW_BITS=12;
    localparam [22:0] BSRAM_BASE=23'h300000;
`else
    localparam ROW_BITS=13;
    localparam [22:0] BSRAM_BASE=23'h700000;
`endif
    localparam [23:0] BANK2_WORD=24'(2 << (ROW_BITS+9));
    function [23:0] bs_index(input [19:0] address);
        bs_index=BANK2_WORD + 24'(BSRAM_BASE>>1) + 24'(address>>1);
    endfunction
    function [23:0] ar_index(input [15:0] address);
        ar_index=BANK2_WORD + 24'(address>>1);
    endfunction
    reg clk=0;
    always #5 clk=~clk;
    wire mclk=clk;
    wire clkref=1'b0;
    reg resetn=0;
    tri [15:0] SDRAM_DQ;
    wire [12:0] SDRAM_A;
    wire [1:0] SDRAM_DQM, SDRAM_BA;
    wire SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;
    reg [15:0] cpu_din=0;
    reg cpu_port=0, cpu_req=0, cpu_we=0;
    reg [22:1] cpu_addr=0;
    reg [1:0] cpu_ds=3;
    wire cpu_req_ack;
    wire [15:0] cpu_port0,cpu_port1;
    reg [19:0] bsram_addr=0;
    reg [15:0] bsram_din=0;
    reg [1:0] bsram_ds=3;
    reg bsram_req=0,bsram_we=0;
    wire [15:0] bsram_dout;
    wire bsram_req_ack,bsram_done;
    reg [22:1] gsu_addr=0;
    reg gsu_req=0;
    wire gsu_req_ack,gsu_done;
    wire [15:0] gsu_dout;
    reg [15:0] aram_addr=0;
    reg [7:0] aram_din=0;
    reg aram_req=0,aram_we=0;
    wire aram_req_ack;
    wire [15:0] aram_dout;
    reg [14:0] vram1_addr=0,vram2_addr=0;
    reg [7:0] vram1_din=0,vram2_din=0;
    reg vram1_req=0,vram2_req=0,vram1_we=0,vram2_we=0;
    wire vram1_ack,vram2_ack;
    wire [7:0] vram1_dout,vram2_dout;
    reg [22:1] rv_addr=0;
    reg [15:0] rv_din=0;
    reg [1:0] rv_ds=3;
    reg rv_req=0,rv_we=0;
    wire rv_req_ack;
    wire [15:0] rv_dout;
    wire refreshing,ready;
    wire [23:0] total_refresh;
    sdram_snes_gsu #(.BSRAM_DONE_DELAY(DONE_DELAY)) dut(.*);
    gsu_test_sdram #(.ROW_BITS(ROW_BITS)) chip(
        .clk(~clk), .addr(SDRAM_A), .ba(SDRAM_BA), .dqm(SDRAM_DQM),
        .cs_n(SDRAM_nCS), .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS),
        .we_n(SDRAM_nWE), .dq(SDRAM_DQ));
    integer normal_writes=0,delayed_writes=0,bs_reads=0,refreshes=0;
    reg [7:0] command_cycle;
    always @(posedge clk) command_cycle=dut.cycle;
    // Inspect actual SDRAM commands, independently of host completion signals.
    always @(negedge clk) begin
        #1;
        if(ready && !SDRAM_nCS) begin
            if({SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}==3'b001) refreshes=refreshes+1;
            if(SDRAM_BA==2 && {SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}==3'b100) begin
                if(dut.port[1]==2) begin
                    if(command_cycle==8'h08) normal_writes=normal_writes+1;
                    else if(command_cycle==8'h40) delayed_writes=delayed_writes+1;
                    else $fatal(1,"BSRAM write in wrong slot %h",command_cycle);
                    if(SDRAM_DQM !== ~dut.ds[1]) $fatal(1,"Wrong BSRAM byte masks");
                end
            end
            if(SDRAM_BA==2 && {SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}==3'b101 && dut.port[1]==2) begin
                if(command_cycle!==8'h08) $fatal(1,"BSRAM read outside ARAM read slot");
                bs_reads=bs_reads+1;
            end
        end
    end
    task tick; @(posedge clk); #2; endtask
    task frame_start;
        begin
            @(negedge clk); #2;
            while(dut.cycle!==8'h01) begin @(negedge clk); #2; end
        end
    endtask
    task bs_finish(input bit previous_done, input [15:0] result);
        integer n;
        begin
            n=0;
            while(bsram_done===previous_done && n<200) begin tick(); n=n+1; end
            if(bsram_done===previous_done || bsram_req_ack!==bsram_req)
                $fatal(1,"BSRAM completion/ack timeout");
            if(!bsram_we && bsram_dout!==result)
                $fatal(1,"BSRAM read got %h expected %h",bsram_dout,result);
        end
    endtask
    task bs_transfer(input bit wr, input [19:0] address, input [1:0] mask,
                     input [15:0] value, input [15:0] result);
        reg previous_done;
        begin
            @(negedge clk); #2;
            previous_done=bsram_done;
            bsram_addr=address; bsram_we=wr; bsram_ds=mask;
            bsram_din=value; bsram_req=~bsram_req;
            bs_finish(previous_done,result);
            // Writes commit at the physical SDRAM edge after controller done.
            @(negedge clk); #2;
            if(wr && chip.get(bs_index(address))!==result)
                $fatal(1,"BSRAM physical write got %h expected %h",chip.get(bs_index(address)),result);
        end
    endtask
    reg previous_done,old_ack,old_aram_ack;
    integer n,before_refresh;
    initial begin
        chip.put(bs_index(20'h01234),16'h1234);
        chip.put(bs_index(20'h00000),16'hdead);
        chip.put(bs_index(20'hffffe),16'hbabe);
        chip.put(ar_index(16'h1234),16'h4321);
        chip.put(ar_index(16'hfffe),16'habcd);
        chip.put(24'(22'h2220>>1),16'h2468);
        chip.put(24'(22'h4440>>1),16'h1357);
        repeat(4) tick();
        @(negedge clk); #2; resetn=1;
        n=0; while(!ready && n<200) begin tick(); n=n+1; end
        if(!ready) $fatal(1,"Initialization timeout");
        $display("GSU shared slot: bank size=%0d MiB done delay=%0d",1<<(ROW_BITS-10),DONE_DELAY);
        bs_transfer(1,20'h01234,3,16'h5aa5,16'h5aa5);
        bs_transfer(1,20'h01234,2,16'hc300,16'hc3a5);
        bs_transfer(1,20'h01234,1,16'h0066,16'hc366);
        bs_transfer(0,20'h01234,3,0,16'hc366);
        bs_transfer(0,20'h00000,3,0,16'hdead);
        bs_transfer(0,20'hffffe,3,0,16'hbabe);

        // ARAM wins a simultaneous request; CPU reads proceed in channel 0.
        frame_start(); previous_done=bsram_done; old_ack=bsram_req_ack;
        aram_addr=16'h1234; aram_we=0; aram_req=~aram_req;
        bsram_addr=20'h01234; bsram_we=0; bsram_req=~bsram_req;
        cpu_addr=22'h2220>>1; cpu_we=0; cpu_req=~cpu_req;
        tick();
        if(dut.port[1]!==1 || dut.port[0]!==1) $fatal(1,"ARAM priority/independent CPU slot failed");
        n=0; while(aram_req_ack!==aram_req && n<30) begin
            tick(); n=n+1;
            if(bsram_req_ack!==old_ack) $fatal(1,"BSRAM accepted before priority ARAM");
        end
        if(aram_req_ack!==aram_req) $fatal(1,"ARAM acceptance timeout");
        bs_finish(previous_done,16'hc366);
        if(aram_dout!==16'h4321 || cpu_port0!==16'h2468)
            $fatal(1,"Shared reads contaminated ARAM/CPU data");

        // Reserve a BSRAM write with CPU read, then introduce a late ARAM read.
        // Its arrival must not change the delayed-write schedule already chosen.
        frame_start(); previous_done=bsram_done; old_aram_ack=aram_req_ack;
        bsram_addr=20'h01234; bsram_we=1; bsram_ds=3;
        bsram_din=16'ha55a; bsram_req=~bsram_req;
        cpu_addr=22'h4440>>1; cpu_req=~cpu_req;
        tick();
        if(dut.port[1]!==2 || !dut.write_delay) $fatal(1,"BSRAM delayed write not reserved");
        @(negedge clk); #2;
        aram_addr=16'hfffe; aram_req=~aram_req;
        while(bsram_done===previous_done) begin
            tick();
            if(aram_req_ack!==old_aram_ack) $fatal(1,"Late ARAM changed reserved BSRAM operation");
        end
        @(negedge clk); #2;
        if(chip.get(bs_index(20'h01234))!==16'ha55a) $fatal(1,"Delayed write data failed");
        repeat(16) tick();
        if(aram_req_ack!==aram_req || aram_dout!==16'habcd || cpu_port0!==16'h1357)
            $fatal(1,"Late ARAM/CPU request lost");

        // ARAM byte writes retain both masks, including the delayed schedule.
        frame_start();
        aram_addr=16'h1234; aram_we=1; aram_din=8'h69; aram_req=~aram_req;
        cpu_addr=22'h2220>>1; cpu_req=~cpu_req;
        tick();
        if(dut.port[1]!==1 || !dut.write_delay) $fatal(1,"ARAM delayed write not reserved");
        repeat(8) tick();
        if(aram_req_ack!==aram_req || chip.get(ar_index(16'h1234))!==16'h4369)
            $fatal(1,"ARAM low-byte delayed write failed");
        frame_start();
        aram_addr=16'h1235; aram_din=8'h96; aram_req=~aram_req;
        tick();
        if(dut.write_delay) $fatal(1,"ARAM normal write unexpectedly delayed");
        repeat(8) tick();
        if(aram_req_ack!==aram_req || chip.get(ar_index(16'h1234))!==16'h9669)
            $fatal(1,"ARAM high-byte normal write failed");
        aram_we=0;

        // A delayed read completion must survive replacing port[1] next frame.
        frame_start(); previous_done=bsram_done;
        bsram_we=0; bsram_req=~bsram_req;
        while(bsram_req_ack!==bsram_req) tick();
        @(negedge clk); #2; aram_addr=16'h1234; aram_req=~aram_req;
        bs_finish(previous_done,16'ha55a);
        repeat(16) tick();
        if(aram_dout!==16'h9669) $fatal(1,"ARAM read overwritten by BSRAM");

        // Hard refresh blocks BSRAM while preserving priority ARAM service.
        frame_start(); previous_done=bsram_done; old_ack=bsram_req_ack;
        before_refresh=refreshes;
        force dut.need_refresh=1'b1;
        bsram_req=~bsram_req; aram_req=~aram_req;
        repeat(24) begin
            tick();
            if(bsram_req_ack!==old_ack || bsram_done!==previous_done)
                $fatal(1,"BSRAM bypassed need_refresh gate");
        end
        if(aram_req_ack!==aram_req || refreshes==before_refresh)
            $fatal(1,"ARAM priority or refresh progress failed");
        release dut.need_refresh;
        bs_finish(previous_done,16'ha55a);
        if(normal_writes==0 || delayed_writes==0 || bs_reads==0)
            $fatal(1,"Missing normal/delayed shared-slot command coverage");
        $display("PASS: ARAM priority, bank-tail mapping, masks, CPU overlap, delayed writes, read done and refresh");
        $finish;
    end
    initial begin #100000; $fatal(1,"Shared slot watchdog"); end
endmodule
