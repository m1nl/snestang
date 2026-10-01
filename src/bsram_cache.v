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
    reg [12:0] pending_meta;
    reg [9:0]  clear_index;

    reg [19:0] pending_addr;
    reg [7:0]  pending_din;
    reg        pending_we;
    reg        partial_fill;
    reg        sd_done_seen;
    reg [15:0] merged;
    wire [1:0] byte_mask = pending_addr[0] ? 2'b10 : 2'b01;

    wire [8:0] tag = meta_q[12:4];
    wire [1:0] dirty = meta_q[3:2];
    wire [1:0] valid = meta_q[1:0];

    localparam [3:0] CLEAR = 0, IDLE = 1, LOOKUP = 2, WRITEBACK = 3,
                     WAIT_WRITEBACK = 4, FILL = 5, WAIT_FILL = 6,
                     ALLOCATE = 7, WAIT_RESPOND = 8, RESPOND = 9, PRIME = 10;
    reg [3:0] state;

    assign dbg_state = state;

    // Sample the accepted request's metadata; LOOKUP uses it next clock.
    always @(posedge clk)
        meta_q <= meta[front_addr[10:1]];
    assign busy = (state != IDLE) || (front_req != front_ack);

    reg [3:0] state_old;

    always @(posedge clk) begin
        state_old <= state;

        if (state != state_old) $display("STATE %d", state);

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
            pending_meta <= 0;
            partial_fill <= 0;
            merged <= 0;
            clear_index <= 0;
            state <= CLEAR;
        end else begin
            case (state)
                CLEAR: begin
                    meta[clear_index] <= 0;
                    if (clear_index == 10'd1023)
                        state <= PRIME;
                    else
                        clear_index <= clear_index + 1'b1;
                end

                PRIME: state <= IDLE;

                IDLE: if (front_req != front_ack) begin
                    front_ack <= front_req;
                    pending_addr <= front_addr;
                    pending_din <= front_din;
                    pending_we <= front_we;
                    front_dout <= front_din;
                    state <= LOOKUP;
                end

                LOOKUP: begin
                    pending_meta <= meta_q;
                    if (tag == pending_addr[19:11] &&
                        (pending_we || (pending_addr[0] ? meta_q[1] : meta_q[0]))) begin
                        if (pending_we) begin
                            if (pending_addr[0])
                                data[pending_addr[10:1]][15:8] <= pending_din;
                            else
                                data[pending_addr[10:1]][7:0] <= pending_din;
                            meta[pending_addr[10:1]] <=
                                {tag, (dirty | byte_mask), (valid | byte_mask)};
                        end else begin
                            front_dout <= pending_addr[0] ? data[pending_addr[10:1]][15:8] :
                                data[pending_addr[10:1]][7:0];
                        end
                        state <= RESPOND;
                    end else if (tag != pending_addr[19:11] && |dirty) begin
                        partial_fill <= 0;
                        state <= WRITEBACK;
                    end else if (pending_we) begin
                        state <= ALLOCATE;
                    end else begin
                        partial_fill <= (tag == pending_addr[19:11]);
                        state <= FILL;
                    end
                end

                WRITEBACK: if (sd_req == sd_ack) begin
                    sd_addr <= {pending_meta[12:4], pending_addr[10:1], 1'b0};
                    sd_din <= data[pending_addr[10:1]];
                    sd_ds <= pending_meta[3:2];
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
                    merged = sd_dout;
                    if (partial_fill) begin
                        if (pending_meta[0])
                            merged[7:0] = data[pending_addr[10:1]][7:0];
                        if (pending_meta[1])
                            merged[15:8] = data[pending_addr[10:1]][15:8];
                    end
                    data[pending_addr[10:1]] <= merged;
                    meta[pending_addr[10:1]] <=
                        {pending_addr[19:11], partial_fill ? pending_meta[3:2] : 2'b00, 2'b11};
                    front_dout <= pending_addr[0] ? merged[15:8] : merged[7:0];
                    state <= WAIT_RESPOND;
                end

                ALLOCATE: begin
                    meta[pending_addr[10:1]] <=
                        {pending_addr[19:11], byte_mask, byte_mask};
                    data[pending_addr[10:1]] <= pending_addr[0] ?
                        {pending_din, 8'b0} : {8'b0, pending_din};
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
