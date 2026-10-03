`timescale 1ns/1ps
module tb_bsram_cache;
    reg clk = 0;
    always #5 clk = ~clk;
    reg resetn = 0;
    reg [19:0] front_addr = 0;
    reg [7:0] front_din = 0;
    reg front_we = 0, front_req = 0;
    wire front_ack, front_done, busy;
    wire [7:0] front_dout;
    wire [19:0] sd_addr;
    wire [15:0] sd_din, sd_dout;
    wire [1:0] sd_ds;
    wire sd_we, sd_req, sd_ack, sd_done;
    wire [3:0] dbg_state;
    integer ack_delay = 0, done_delay = 0;
    reg early_data = 0, initial_ack = 0, initial_done = 0;

    bsram_cache dut (.*);
    bsram_sdram_model controller (
        .clk(clk), .resetn(resetn), .addr(sd_addr), .din(sd_din),
        .ds(sd_ds), .we(sd_we), .req(sd_req), .ack(sd_ack),
        .done(sd_done), .dout(sd_dout), .ack_delay(ack_delay),
        .done_delay(done_delay), .early_data(early_data),
        .initial_ack(initial_ack), .initial_done(initial_done)
    );

    // Architectural memory and independent direct-map policy predictor.
    // No DUT internals are used to predict data or SDRAM transactions.
    reg [7:0] golden [0:1048575];
    integer tags [0:1023];
    reg [1:0] valid_bytes [0:1023], dirty_bytes [0:1023];
    reg [19:0] expected_addr [0:65535];
    reg [15:0] expected_data [0:65535];
    reg [1:0] expected_ds [0:65535];
    reg expected_we [0:65535];
    reg expected_deferred [0:65535];
    integer head = 0, tail = 0;
    integer operations = 0, reads = 0, writes = 0;
    integer mask_count [0:3];
    reg [11:0] states_seen = 0;
    reg [3:0] previous_state = 0;
    reg last_sd_req = 0;
    reg last_front_ack = 0, last_front_done = 0;
    reg last_sd_ack = 0, last_sd_done = 0;
    reg front_inflight = 0, sd_inflight = 0, sd_accepted = 0;
    reg sd_inflight_we = 0, front_was_write = 0;
    integer simultaneous_completions = 0, separate_completions = 0;
    integer sd_phase_count [0:1];
    integer deferred_mask_count [0:3];
    integer deferred_write_mask_count [0:3];
    integer responses_during_write = 0, guarded_sdram_cycles = 0;
    integer seed = 1, rng, random_ops = 4000;
    integer i, j, index, tag_number, value;
    reg [19:0] random_addr;
    reg [7:0] expected_byte;
    reg before_reset_read_done;
    integer reset_cycles;

    task tick;
        @(posedge clk); #2;
    endtask

    task enqueue(input bit wr, input [19:0] address,
                 input [1:0] mask, input [15:0] data_value, input bit deferred = 0);
        if (tail == 65536) $fatal(1, "Expected transaction queue overflow");
        expected_we[tail] = wr;
        expected_addr[tail] = address;
        expected_ds[tail] = mask;
        expected_data[tail] = data_value;
        expected_deferred[tail] = deferred;
        tail = tail + 1;
    endtask

    task predict(input bit wr, input [19:0] address,
                 input [7:0] data_value, output reg [7:0] result);
        integer slot, new_tag, victim;
        reg [1:0] mask;
        reg [1:0] victim_dirty;
        reg [15:0] victim_data;
        begin
            slot = int'(address[10:1]);
            new_tag = int'(address[19:11]);
            mask = address[0] ? 2'b10 : 2'b01;
            victim_dirty = 0;
            victim = 0;
            victim_data = 0;
            if (tags[slot] != new_tag) begin
                if (dirty_bytes[slot] != 0) begin
                    victim = tags[slot] * 2048 + slot * 2;
                    victim_dirty = dirty_bytes[slot];
                    victim_data = {golden[victim+1], golden[victim]};
                end
                tags[slot] = new_tag;
                valid_bytes[slot] = 0;
                dirty_bytes[slot] = 0;
            end
            if (wr) begin
                golden[address] = data_value;
                valid_bytes[slot] = valid_bytes[slot] | mask;
                dirty_bytes[slot] = dirty_bytes[slot] | mask;
                result = data_value;
            end else begin
                if ((valid_bytes[slot] & mask) == 0) begin
                    enqueue(0, {address[19:1], 1'b0}, 2'b11, 0);
                    valid_bytes[slot] = 2'b11;
                end
                result = golden[address];
            end
            if (victim_dirty != 0)
                enqueue(1, 20'(victim), victim_dirty, victim_data, 1);
        end
    endtask

    // Compare every issued transfer, including ordering, byte masks and victim tag.
    always @(posedge clk) begin
        #1;
        if (!resetn) begin
            last_sd_req = sd_req;
            last_sd_ack = sd_ack; last_sd_done = sd_done;
            last_front_ack = front_ack; last_front_done = front_done;
            front_inflight = 0; sd_inflight = 0; sd_accepted = 0;
            previous_state = dbg_state;
        end
        else begin
            if (dbg_state > 11) $fatal(1, "Illegal state %0d", dbg_state);
            if (previous_state == 11 && (dbg_state !== 4'd2 ||
                front_done !== last_front_done || sd_req !== last_sd_req))
                $fatal(1, "READ must spend one cycle reading RAM before LOOKUP");
            states_seen[dbg_state] = 1;
            if (sd_inflight && sd_inflight_we && (dbg_state == 3 || dbg_state == 5))
                guarded_sdram_cycles = guarded_sdram_cycles + 1;
            if (busy !== ((dbg_state != 1) || (front_req != front_ack)))
                $fatal(1, "Incorrect busy output");
            if (sd_req !== last_sd_req) begin
                if (sd_inflight || sd_ack !== last_sd_req)
                    $fatal(1, "SDRAM request issued before previous ack/done");
                sd_inflight = 1;
                sd_inflight_we = sd_we;
                sd_accepted = 0;
                sd_phase_count[sd_req] = sd_phase_count[sd_req] + 1;
                if (head == tail) $fatal(1, "Unexpected SDRAM transaction at %h", sd_addr);
                if (expected_deferred[head] && front_inflight)
                    $fatal(1, "Eviction writeback issued before front_done");
                if ({sd_we, sd_addr, sd_ds} !==
                    {expected_we[head], expected_addr[head], expected_ds[head]})
                    $fatal(1, "Transfer %0d got we/addr/ds=%b/%h/%b expected %b/%h/%b",
                           head, sd_we, sd_addr, sd_ds, expected_we[head],
                           expected_addr[head], expected_ds[head]);
                if (sd_we) begin
                    if ((sd_ds[0] && sd_din[7:0] !== expected_data[head][7:0]) ||
                        (sd_ds[1] && sd_din[15:8] !== expected_data[head][15:8]))
                        $fatal(1, "Incorrect writeback data: got %h expected %h mask %b",
                               sd_din, expected_data[head], sd_ds);
                    writes = writes + 1;
                    mask_count[sd_ds] = mask_count[sd_ds] + 1;
                end else reads = reads + 1;
                head = head + 1;
                last_sd_req = sd_req;
            end
            if (sd_ack !== last_sd_ack) begin
                if (!sd_inflight || sd_accepted || sd_ack !== sd_req)
                    $fatal(1, "Unsolicited or duplicate SDRAM ack");
                sd_accepted = 1;
            end
            if (sd_done !== last_sd_done) begin
                if (!sd_inflight || !sd_accepted)
                    $fatal(1, "SDRAM done without accepted request");
                if (sd_ack !== last_sd_ack) simultaneous_completions = simultaneous_completions + 1;
                else separate_completions = separate_completions + 1;
                sd_inflight = 0;
            end
            if (front_ack !== last_front_ack) begin
                if (dbg_state !== 4'd2 || previous_state !== 4'd11)
                    $fatal(1, "Accepted request must enter LOOKUP from READ");
                if (front_inflight || front_ack !== front_req)
                    $fatal(1, "Front accepted a second request before completion");
                front_inflight = 1;
                front_was_write = front_we;
                if (front_done !== last_front_done)
                    $fatal(1, "Front ack and done occurred on the same cycle");
            end
            if (front_done !== last_front_done) begin
                if (!front_inflight || (sd_inflight && !sd_inflight_we))
                    $fatal(1, "Front done without acceptance or before read fill completion");
                if (sd_inflight && sd_inflight_we)
                    responses_during_write = responses_during_write + 1;
                if (head != tail) begin
                    if (tail-head != 1 || !expected_deferred[head] || !busy)
                        $fatal(1, "Only deferred victim writeback may remain at front_done");
                    if (front_was_write)
                        deferred_write_mask_count[expected_ds[head]] = deferred_write_mask_count[expected_ds[head]] + 1;
                    else
                        deferred_mask_count[expected_ds[head]] = deferred_mask_count[expected_ds[head]] + 1;
                end
                front_inflight = 0;
            end
            last_sd_ack = sd_ack; last_sd_done = sd_done;
            last_front_ack = front_ack; last_front_done = front_done;
            previous_state = dbg_state;
        end
    end

    task wait_complete(input bit previous_done, input [7:0] result);
        integer cycles;
        begin
            cycles = 0;
            while (front_done === previous_done && cycles < 200) begin
                tick();
                cycles = cycles + 1;
            end
            if (front_done === previous_done) $fatal(1, "Front completion timeout state=%0d", dbg_state);
            if (front_dout !== result)
                $fatal(1, "Front data got %h expected %h, operation %0d", front_dout, result, operations);
            if (controller.active && !controller.saved_we)
                $fatal(1, "Front completed before read fill done");
            cycles = 0;
            while ((busy || sd_inflight || controller.active || sd_req != sd_ack) && cycles < 200) begin
                tick();
                cycles = cycles + 1;
                if (front_done !== ~previous_done || front_dout !== result)
                    $fatal(1, "Front response changed during deferred writeback");
            end
            if (busy || sd_inflight || controller.active || sd_req != sd_ack)
                $fatal(1, "Deferred writeback drain timeout");
            if (head != tail || controller.active)
                $fatal(1, "Cache became idle before expected SDRAM transfers finished");
            operations = operations + 1;
        end
    endtask

    task transact(input bit wr, input [19:0] address, input [7:0] data_value);
        reg [7:0] result;
        reg previous_done, requested_phase;
        integer cycles;
        begin
            if (busy) $fatal(1, "Driver issued ordinary request while busy");
            predict(wr, address, data_value, result);
            previous_done = front_done;
            @(negedge clk); #1;
            front_addr = address;
            front_we = wr;
            front_din = data_value;
            front_req = ~front_req;
            requested_phase = front_req;
            #1; // allow continuous busy assignment to settle
            cycles = 0;
            while (front_ack !== requested_phase && cycles < 5) begin
                tick();
                cycles = cycles + 1;
            end
            if (front_ack !== requested_phase) $fatal(1, "Front acceptance timeout");
            if (front_done !== previous_done) $fatal(1, "done changed at acceptance");
            if (wr && front_dout !== data_value)
                $fatal(1, "Write must output accepted byte at ack");
            if (!busy) $fatal(1, "busy dropped at acceptance");
            // Inputs may change immediately after ack; accepted payload must be latched.
            @(negedge clk); #1;
            front_addr = ~address;
            front_din = ~data_value;
            front_we = ~wr;
            wait_complete(previous_done, result);
            if (front_ack !== requested_phase || busy)
                $fatal(1, "Incorrect ack/busy after completion");
        end
    endtask

    task idle_check;
        reg saved_ack, saved_done, saved_req;
        begin
            saved_ack = front_ack; saved_done = front_done; saved_req = sd_req;
            repeat (8) begin
                tick();
                if (busy || front_ack !== saved_ack || front_done !== saved_done || sd_req !== saved_req)
                    $fatal(1, "Idle request replay or unexpected handshake transition");
            end
        end
    endtask

    task reset_cache(input bit ack_phase, input bit done_phase, input bit queued);
        integer slot, word_index;
        begin
            @(negedge clk); #1;
            resetn = 0;
            initial_ack = ack_phase;
            initial_done = done_phase;
            front_req = 0;
            repeat (3) tick();
            if ({front_ack, front_done, front_dout} !== 10'b0 || sd_req !== ack_phase)
                $fatal(1, "Incorrect reset output/SDRAM phase synchronization");
            // Reset invalidates dirty cache state without flushing it.
            for (word_index = 0; word_index < 524288; word_index = word_index + 1) begin
                golden[2*word_index] = controller.mem[word_index][7:0];
                golden[2*word_index+1] = controller.mem[word_index][15:8];
            end
            for (slot = 0; slot < 1024; slot = slot + 1) begin
                tags[slot] = 0; valid_bytes[slot] = 0; dirty_bytes[slot] = 0;
            end
            head = 0; tail = 0;
            @(negedge clk); #1; resetn = 1;
            if (queued) begin
                predict(0, 20'hff801, 0, expected_byte);
                front_addr = 20'hff801; front_we = 0; front_req = 1;
            end
            // Exactly 1024 clear clocks, then PRIME, then IDLE.
            repeat (1024) begin
                tick();
                if (!busy || front_ack !== 0 || front_done !== 0 || sd_req !== ack_phase)
                    $fatal(1, "Cache accepted/completed a request during metadata clear");
            end
            tick();
            if (dbg_state !== 4'd1) $fatal(1, "Cache did not leave PRIME after clear");
            if (queued) begin
                tick(); tick();
                if (front_ack !== 1) $fatal(1, "Request held during reset was lost");
                wait_complete(0, expected_byte);
            end else if (busy) $fatal(1, "Cache not idle after clear");
        end
    endtask

    task queued_pair;
        reg [7:0] first_result, second_result;
        reg first_done, first_phase, second_phase;
        begin
            $display("Queued request while first request waits for SDRAM");
            ack_delay = 12; done_delay = 20;
            predict(0, 20'habc12, 0, first_result);
            first_done = front_done;
            @(negedge clk); #1;
            front_addr = 20'habc12; front_we = 0; front_req = ~front_req;
            first_phase = front_req;
            tick(); tick();
            if (front_ack !== first_phase) $fatal(1, "First queued request not accepted");
            @(negedge clk); #1;
            front_addr = 20'hfedc3; front_din = 8'hc7; front_we = 1;
            front_req = ~front_req; second_phase = front_req;
            while (front_done === first_done) begin
                tick();
                if (front_ack !== first_phase) $fatal(1, "Second request accepted before first completed");
            end
            if (front_dout !== first_result || !busy) $fatal(1, "First queued response incorrect");
            operations = operations + 1;
            predict(1, 20'hfedc3, 8'hc7, second_result);
            tick(); tick();
            if (front_ack !== second_phase) $fatal(1, "Second queued request lost");
            wait_complete(~first_done, second_result);
            transact(0, 20'hfedc3, 0);
        end
    endtask

    task deferred_case(input bit wr, input [1:0] mask);
        reg [19:0] victim_address, fill_address;
        reg [7:0] result, queued_result;
        reg previous_done, first_phase, queued_phase;
        integer cycles;
        begin
            victim_address = 20'h22080 + 20'(4*mask) + (wr ? 20'h40 : 20'h0);
            fill_address = victim_address + 20'h800;
            ack_delay = 0; done_delay = 0;
            if (mask[0]) transact(1, victim_address, 8'hb6);
            if (mask[1]) transact(1, victim_address+1, 8'hd9);
            ack_delay = 8; done_delay = 16;
            predict(wr, fill_address+1, 8'h73, result);
            previous_done = front_done;
            @(negedge clk); #1;
            front_addr = fill_address+1; front_we = wr; front_din = 8'h73;
            front_req = ~front_req;
            first_phase = front_req;
            cycles = 0;
            while (front_done === previous_done && cycles < 200) begin
                tick(); cycles = cycles + 1;
            end
            if (front_done === previous_done || front_ack !== first_phase ||
                front_dout !== result || !busy || head != tail-1 || controller.active)
                $fatal(1, "Dirty miss must complete before victim writeback");
            operations = operations + 1;
            // Queue a read of the victim. Acceptance may overlap writeback, but
            // the fill must wait for its done before reading updated SDRAM bytes.
            ack_delay = 12; done_delay = 24;
            predict(0, victim_address + (mask[0] ? 20'd0 : 20'd1), 0, queued_result);
            @(negedge clk); #1;
            front_addr = victim_address + (mask[0] ? 20'd0 : 20'd1);
            front_we = 0; front_din = 8'(~result); front_req = ~front_req;
            queued_phase = front_req;
            cycles = 0;
            while (front_ack !== queued_phase && cycles < 200) begin
                tick(); cycles = cycles + 1;
                if (front_done !== ~previous_done ||
                    (front_ack !== queued_phase && front_dout !== result))
                    $fatal(1, "Deferred writeback altered the completed read response");
            end
            if (front_ack !== queued_phase)
                $fatal(1, "Queued victim read was lost");
            wait_complete(~previous_done, queued_result);
            transact(0, victim_address, 0);
            transact(0, victim_address+1, 0);
        end
    endtask

    // Unlike transact(), this driver returns at front_done without draining SDRAM.
    task rapid_request(input bit wr, input [19:0] address, input [7:0] data_value);
        reg [7:0] result;
        reg previous_done, phase;
        integer cycles;
        begin
            cycles = 0;
            while (busy && cycles < 200) begin tick(); cycles = cycles + 1; end
            if (busy) $fatal(1, "Rapid request acceptance timeout");
            predict(wr, address, data_value, result);
            previous_done = front_done;
            @(negedge clk); #1;
            front_addr = address; front_din = data_value; front_we = wr;
            front_req = ~front_req; phase = front_req;
            cycles = 0;
            while (front_ack !== phase && cycles < 8) begin tick(); cycles = cycles + 1; end
            if (front_ack !== phase) $fatal(1, "Rapid request not acknowledged");
            @(negedge clk); #1;
            front_addr = ~address; front_din = ~data_value; front_we = ~wr;
            while (front_done === previous_done && cycles < 8) begin tick(); cycles = cycles + 1; end
            if (front_done === previous_done || front_dout !== result)
                $fatal(1, "Cache hit/allocation waited for outstanding SDRAM write");
            operations = operations + 1;
        end
    endtask

    task outstanding_write_case;
        reg phase;
        integer cycles;
        begin
            $display("Cache hits overlap writeback; another writeback and fill wait for done after ack");
            ack_delay = 0; done_delay = 0;
            transact(1, 20'h33040, 8'hb6);
            done_delay = 70;
            rapid_request(1, 20'h33840, 8'h9a);
            cycles = 0;
            while ((!controller.active || !controller.accepted) && cycles < 20) begin
                tick(); cycles = cycles + 1;
            end
            if (!controller.active || !controller.accepted || busy || sd_req !== sd_ack)
                $fatal(1, "Did not reach accepted-but-incomplete writeback in IDLE");
            phase = sd_req;
            rapid_request(0, 20'h33840, 0);
            rapid_request(1, 20'h33841, 8'hd9);
            rapid_request(0, 20'h33841, 0);
            // This allocation finishes too, but cannot issue its own eviction yet.
            rapid_request(1, 20'h34040, 8'h73);
            if (!controller.active || sd_req !== phase || !busy)
                $fatal(1, "Second writeback bypassed the outstanding-write guard");
            // Once the first write finishes, the next victim is copied into the
            // SDRAM registers. Its readback fill must now wait for that second write.
            cycles = 0;
            while (busy && cycles < 200) begin tick(); cycles = cycles + 1; end
            if (busy || sd_req === phase) $fatal(1, "Second writeback did not resume after done");
            transact(0, 20'h33840, 0);
            transact(0, 20'h33841, 0);
            transact(0, 20'h33040, 0);
            done_delay = 0;
        end
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("OPS=%d", random_ops)) begin end
        rng = seed;
        for (i = 0; i < 4; i = i + 1) begin
            mask_count[i] = 0; deferred_mask_count[i] = 0;
            deferred_write_mask_count[i] = 0;
        end
        sd_phase_count[0] = 0; sd_phase_count[1] = 0;
        // Every address has reproducible, asymmetric bytes and varies across tags.
        for (i = 0; i < 524288; i = i + 1)
            controller.mem[i] = {8'((i * 29) ^ (i >> 9) ^ 8'ha7),
                                 8'((i * 17) ^ (i >> 7) ^ 8'h39)};
        $display("bsram_cache seed=%0d randomized operations=%0d", seed, random_ops);
        reset_cache(0, 0, 1);
        idle_check();

        $display("Cold fills, byte hits, clean conflict replacement and address boundaries");
        transact(0, 20'h00000, 0); transact(0, 20'h00001, 0);
        transact(0, 20'h00800, 0); transact(0, 20'h00000, 0);
        transact(0, 20'hffffe, 0); transact(0, 20'hfffff, 0);
        transact(0, 20'h007fe, 0); transact(0, 20'h007ff, 0);

        $display("No-fetch allocation, partial fill preservation, all dirty byte masks");
        ack_delay = 5; done_delay = 9;
        transact(1, 20'h02040, 8'h11); transact(0, 20'h02040, 0);
        transact(0, 20'h02041, 0); // partial fill must preserve dirty low byte
        transact(0, 20'h02840, 0); // low-only eviction then read fill
        transact(0, 20'h02040, 0); // observe actual backing write
        transact(1, 20'h03043, 8'h22); transact(0, 20'h03043, 0);
        transact(0, 20'h03042, 0); // partial fill must preserve dirty high byte
        transact(1, 20'h03842, 8'h33); // high-only eviction then allocate
        transact(0, 20'h03043, 0);
        transact(1, 20'h04044, 8'h44); transact(1, 20'h04045, 8'h55);
        transact(1, 20'h04044, 8'h66); // overwrite, preserve other byte
        transact(0, 20'h04045, 0);
        transact(1, 20'h04845, 8'h77); // both-dirty eviction, high-only allocation
        transact(0, 20'h04044, 0); transact(0, 20'h04045, 0);
        // Evict partial words without filling their missing bytes first.
        transact(1, 20'h05046, 8'h81); transact(1, 20'h05846, 8'h82);
        transact(0, 20'h05047, 0); transact(0, 20'h05046, 0);
        transact(1, 20'h06049, 8'h91); transact(0, 20'h06848, 0);
        transact(0, 20'h06048, 0); transact(0, 20'h06049, 0);
        // Write hits in a clean, fully valid word become dirty without refetch.
        transact(0, 20'h07050, 0); transact(1, 20'h07051, 8'ha1);
        transact(1, 20'h07050, 8'ha2); transact(0, 20'h07850, 0);
        idle_check();
        queued_pair();
        $display("Reads/writes complete before eviction; queued victim fills wait for writeback done");
        deferred_case(0, 2'b01); deferred_case(0, 2'b10); deferred_case(0, 2'b11);
        deferred_case(1, 2'b01); deferred_case(1, 2'b10); deferred_case(1, 2'b11);
        outstanding_write_case();

        $display("Every tag at index 1023, alternating partial allocations and fills");
        ack_delay = 2; done_delay = 3;
        for (i = 0; i < 512; i = i + 1) begin
            random_addr = 20'((i << 11) | 2046 | (i & 1));
            transact(1, random_addr, 8'(i ^ 8'hbc));
            transact(0, random_addr ^ 20'h1, 0);
            transact(0, random_addr, 0);
        end

        $display("All indices/tags: populate, dirty, evict, and verify backing bytes");
        ack_delay = 0; done_delay = 0;
        for (i = 0; i < 1024; i = i + 1) begin
            transact(1, 20'h80000 + 20'(2*i), 8'(i));
            transact(1, 20'h80001 + 20'(2*i), 8'(~i));
        end
        for (i = 0; i < 1024; i = i + 1)
            transact(0, 20'h80800 + 20'(2*i), 0);
        for (i = 0; i < 1024; i = i + 1) begin
            transact(0, 20'h80000 + 20'(2*i), 0);
            transact(0, 20'h80001 + 20'(2*i), 0);
        end

        $display("Reset discards dirty data and clears every index; nonzero SDRAM phases");
        for (i = 0; i < 1024; i = i + 1)
            transact(1, 20'h80000 + 20'(2*i), 8'(i ^ 8'h5a));
        reset_cache(1, 1, 0);
        for (i = 0; i < 1024; i = i + 1) begin
            transact(0, 20'h80000 + 20'(2*i), 0);
            transact(0, 20'h80001 + 20'(2*i), 0);
        end
        reset_cache(1, 0, 0);
        transact(0, 20'hfff01, 0);
        reset_cache(0, 1, 0);
        transact(1, 20'hff002, 8'hf2); transact(0, 20'hff802, 0);

        $display("Reset during unacknowledged and accepted, incomplete fills/writebacks");
        for (j = 0; j < 6; j = j + 1) begin
            if (j >= 2) transact(1, 20'h12b00 + 20'(j*2), 8'hda);
            ack_delay = j >= 4 ? 0 : ((j & 1) == 0 ? 50 : 0);
            done_delay = j >= 4 ? 0 : 50;
            // Both kinds of conflict complete before their victim writeback.
            predict(j >= 2 && j < 4, 20'h12300 + 20'(j*2), 8'h45, expected_byte);
            before_reset_read_done = front_done;
            @(negedge clk); #1;
            front_addr = 20'h12300 + 20'(j*2); front_we = (j >= 2 && j < 4);
            front_din = 8'h45; front_req = ~front_req;
            if (j >= 4) begin
                // Finish the read, then reset while its deferred victim writeback
                // is either waiting for acceptance or waiting for completion.
                reset_cycles = 0;
                while (front_done === before_reset_read_done && reset_cycles < 100) begin
                    tick(); reset_cycles = reset_cycles + 1;
                end
                if (front_done === before_reset_read_done || front_dout !== expected_byte || !busy)
                    $fatal(1, "Deferred reset test did not reach early read response");
                operations = operations + 1;
                ack_delay = (j & 1) == 0 ? 50 : 0; done_delay = 50;
            end
            repeat (8) tick();
            if (!controller.active || controller.accepted !== 1'(j) ||
                controller.saved_we !== (j >= 2))
                $fatal(1, "Reset case %0d: active=%b accepted=%b we=%b state=%0d",
                       j, controller.active, controller.accepted, controller.saved_we, dbg_state);
            reset_cache(1'(j), 1'(~j), 0);
            ack_delay = 0; done_delay = 0;
            transact(0, 20'h12300 + 20'(j*2), 0);
            if (j >= 2) transact(0, 20'h12b00 + 20'(j*2), 0);
        end

        $display("Random traffic with hotspots, conflicts, full-range addresses and latency variation");
        for (i = 0; i < random_ops; i = i + 1) begin
            value = $random(rng) & 32'h7fffffff;
            index = value % 1024;
            tag_number = (value >> 10) % 512;
            case (i % 4)
                0: random_addr = 20'((tag_number << 11) | ((index % 8) << 1) | (value & 1));
                1: random_addr = 20'h60000 + 20'(value % 32);
                2: random_addr = front_addr ^ 20'hfffff; // revisit last accepted address
                3: random_addr = 20'(value);
            endcase
            ack_delay = value % 11;
            done_delay = (value >> 5) % 17;
            early_data = 1'(value >> 9);
            transact(1'(value >> 3), random_addr, 8'(value >> 13));
        end
        // Evict every remaining dirty word, then compare the entire backing memory.
        ack_delay = 1; done_delay = 0;
        for (i = 0; i < 1024; i = i + 1)
            transact(0, 20'((((tags[i] + 1) % 512) << 11) | (i << 1)), 0);
        for (i = 0; i < 524288; i = i + 1)
            if (controller.mem[i] !== {golden[2*i+1], golden[2*i]})
                $fatal(1, "Backing memory mismatch at word %h: got %h expected %h%h",
                       i, controller.mem[i], golden[2*i+1], golden[2*i]);
        idle_check();
        // States 4/8 are unused; RESPOND=9 stages hit data before completion.
        if (states_seen !== 12'heef || mask_count[1] == 0 || mask_count[2] == 0 || mask_count[3] == 0)
            $fatal(1, "Missing state/dirty-mask coverage states=%h masks=%0d/%0d/%0d",
                   states_seen, mask_count[1], mask_count[2], mask_count[3]);
        if (sd_phase_count[0] == 0 || sd_phase_count[1] == 0 ||
            simultaneous_completions == 0 || separate_completions == 0)
            $fatal(1, "Missing toggle phase or ack/done timing coverage");
        if (deferred_mask_count[1] == 0 || deferred_mask_count[2] == 0 || deferred_mask_count[3] == 0)
            $fatal(1, "Missing deferred read writeback coverage for a dirty byte mask");
        if (deferred_write_mask_count[1] == 0 || deferred_write_mask_count[2] == 0 || deferred_write_mask_count[3] == 0)
            $fatal(1, "Missing deferred write writeback coverage for a dirty byte mask");
        if (responses_during_write == 0 || guarded_sdram_cycles == 0)
            $fatal(1, "Missing cache overlap or outstanding-write guard coverage");
        $display("PASS: %0d front operations, %0d SDRAM reads, %0d writebacks; masks 01/10/11=%0d/%0d/%0d",
                 operations, reads, writes, mask_count[1], mask_count[2], mask_count[3]);
        $display("Handshake coverage: simultaneous ack/done=%0d, separate=%0d, req phases 0/1=%0d/%0d",
                 simultaneous_completions, separate_completions, sd_phase_count[0], sd_phase_count[1]);
        $display("Read responses before writeback, dirty masks 01/10/11=%0d/%0d/%0d",
                 deferred_mask_count[1], deferred_mask_count[2], deferred_mask_count[3]);
        $display("Write responses before writeback, dirty masks 01/10/11=%0d/%0d/%0d",
                 deferred_write_mask_count[1], deferred_write_mask_count[2], deferred_write_mask_count[3]);
        $display("Responses during outstanding writes=%0d, guarded SDRAM wait cycles=%0d",
                 responses_during_write, guarded_sdram_cycles);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Global watchdog timeout");
    end
endmodule
