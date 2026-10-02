// 1024 direct-mapped, 16-bit BSRAM words. Tag, valid and dirty bits live in
// one synchronously read metadata RAM. Dirty bytes reach SDRAM only on eviction.
module bsram_cache (
    input  wire        clk,
    input  wire        resetn,
    input  wire [19:0] front_addr,
    input  wire [7:0]  front_din,
    input  wire        front_we,
    input  wire        front_req,
    output reg         front_ack,
    output reg         front_done,
    output reg  [7:0]  front_dout,
    output wire        busy,
    output reg  [19:0] sd_addr,
    output reg  [15:0] sd_din,
    output reg  [1:0]  sd_ds,
    output reg         sd_we,
    output reg         sd_req,
    input  wire        sd_ack,
    input  wire        sd_done,
    input  wire [15:0] sd_dout,
    output wire [3:0]  dbg_state
);
    // Metadata layout: {tag[12:4], dirty[3:2], valid[1:0]}.
    reg [12:0] meta [0:1023];
    reg [15:0] data [0:1023];
    reg [12:0] meta_q;
    reg [15:0] data_q;
    reg [9:0]  clear_index;

    reg [19:0] pending_addr;
    reg [7:0]  pending_din;
    reg        pending_we;
    reg        sd_done_seen;

    wire  [1:0] byte_mask = pending_addr[0] ? 2'b10 : 2'b01;

    wire [8:0] pending_tag = pending_addr[19:11];

    wire       block = pending_addr[0];
    wire [8:0] tag   = meta_q[12:4];
    wire [1:0] dirty = meta_q[3:2];
    wire [1:0] valid = meta_q[1:0];

    reg  [9:0] index;

    wire tag_match = tag == pending_tag;

    wire [15:0] merged = {
        tag_match && valid[1] ? data_q[15:8] : sd_dout[15:8],
        tag_match && valid[0] ? data_q[ 7:0] : sd_dout[ 7:0]
    };

    localparam [3:0] CLEAR = 0, IDLE = 1, LOOKUP = 2, WRITEBACK = 3,
                     WAIT_WRITEBACK = 4, FILL = 5, WAIT_FILL = 6,
                     ALLOCATE = 7, WAIT_RESPOND = 8, RESPOND = 9, PRIME = 10,
                     READ = 11;
    reg [3:0] state;

    assign dbg_state = state;

    assign busy = (state != IDLE) || (front_req != front_ack);

    reg        data_we;
    reg [15:0] data_din;
    reg        meta_we;
    reg [12:0] meta_din;

    // One full-word write port per RAM. Byte writes preserve the other byte
    // from the word read after latching the request, avoiding partial RAM writes.
    always @* begin
        data_we = 0;
        data_din = 0;
        meta_we = 0;
        index = pending_addr[10:1];
        meta_din = 0;
        if (resetn) begin
            case (state)
                CLEAR: begin
                    meta_we = 1;
                    index = clear_index;
                end
                READ: ;
                LOOKUP: if (tag_match && pending_we) begin
                    data_we = 1;
                    data_din = block ? {pending_din, data_q[7:0]} : {data_q[15:8], pending_din};
                    meta_we = 1;
                    meta_din = {tag, (dirty | byte_mask), (valid | byte_mask)};
                end
                WAIT_FILL: if (sd_done != sd_done_seen) begin
                    data_we = 1;
                    data_din = merged;
                    meta_we = 1;
                    meta_din = {pending_tag, tag_match ? dirty : 2'b00, 2'b11};
                end
                ALLOCATE: begin
                    data_we = 1;
                    data_din = block ? {pending_din, 8'b0} : {8'b0, pending_din};
                    meta_we = 1;
                    meta_din = {pending_tag, byte_mask, byte_mask};
                end
                default: begin end
            endcase
        end
    end

    // Dedicated synchronous read outputs have no reset or alternate drivers.
    // Read one cycle after acceptance, using the latched address. The outputs
    // hold the accepted request's word throughout lookup and SDRAM waits.
    always @(posedge clk) begin
        if (state == READ) begin
            meta_q <= meta[front_addr[10:1]];
            data_q <= data[front_addr[10:1]];
        end else begin
            if (meta_we)
                meta[index] <= meta_din;
            if (data_we)
                data[index] <= data_din;
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            front_ack <= 0;
            front_done <= 0;
            front_dout <= 0;
            sd_addr <= 0;
            sd_din <= 0;
            sd_ds <= 0;
            sd_we <= 0;
            sd_req <= sd_ack;
            sd_done_seen <= sd_done;
            pending_addr <= 0;
            pending_din <= 0;
            pending_we <= 0;
            clear_index <= 0;
            state <= CLEAR;
        end else begin
            case (state)
                CLEAR: begin
                    if (clear_index == 10'd1023)
                        state <= PRIME;
                    else
                        clear_index <= clear_index + 1'b1;
                end

                PRIME: state <= IDLE;

                IDLE: if (front_req != front_ack) begin
                    state <= READ;
                end

                READ: begin
                    front_ack <= front_req;
                    front_dout <= front_din;
                    pending_addr <= front_addr;
                    pending_din <= front_din;
                    pending_we <= front_we;
                    state <= LOOKUP;
                end

                LOOKUP: begin
                    if (tag_match && (pending_we || (block ? valid[1] : valid[0]))) begin
                        if (!pending_we) begin
                            front_dout <= block ? data_q[15:8] : data_q[7:0];
                        end
                        state <= RESPOND;
                    end else if (tag != pending_tag && |dirty) begin
                        state <= WRITEBACK;
                    end else if (pending_we) begin
                        state <= ALLOCATE;
                    end else begin
                        state <= FILL;
                    end
                end

                WRITEBACK: if (sd_req == sd_ack) begin
                    sd_addr <= {tag, index, 1'b0};
                    sd_din <= data_q;
                    sd_ds <= dirty;
                    sd_we <= 1;
                    sd_done_seen <= sd_done;
                    sd_req <= ~sd_req;
                    state <= WAIT_WRITEBACK;
                end

                WAIT_WRITEBACK: if (sd_done != sd_done_seen) begin
                    if (pending_we)
                        state <= ALLOCATE;
                    else
                        state <= FILL;
                end

                FILL: if (sd_req == sd_ack) begin
                    sd_addr <= {pending_addr[19:1], 1'b0};
                    sd_ds <= 2'b11;
                    sd_we <= 0;
                    sd_done_seen <= sd_done;
                    sd_req <= ~sd_req;
                    state <= WAIT_FILL;
                end

                WAIT_FILL: if (sd_done != sd_done_seen) begin
                    front_dout <= block ? merged[15:8] : merged[7:0];
                    state <= WAIT_RESPOND;
                end

                ALLOCATE: begin
                    state <= WAIT_RESPOND;
                end

                WAIT_RESPOND: state <= RESPOND;

                RESPOND: begin
                    front_done <= ~front_done;
                    state <= IDLE;
                end
                default: state <= CLEAR;
            endcase
        end
    end
endmodule
