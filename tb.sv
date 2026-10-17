module Cpu #(
    // CACHE_LINE_SIZE = 2 ** OFFSET_LEN
    // CACHE_SET_COUNT = 2 ** INDEX_LEN
    // CACHE_LINE_COUNT = CACHE_SET_COUNT * CACHE_WAY
    // CACHE_SIZE = CACHE_LINE_COUNT * CACHE_LINE_SIZE
    // MEMORY_SIZE = 2 ** ADDRESS_LEN
    // ADDR1_BUS_LEN = max(TAG_LEN + INDEX_LEN, OFFSET_LEN)
    // ADDR2_BUS_LEN = TAG_LEN + INDEX_LEN
    parameter ADDRESS_LEN = 17,
    parameter TAG_LEN = 7,
    parameter INDEX_LEN = 4,
    parameter OFFSET_LEN = 6,
    parameter CACHE_SIZE = 4096,
    parameter CACHE_LINE_SIZE = 64,
    parameter CACHE_LINE_COUNT = 64,
    parameter CACHE_SET_COUNT = 16,
    parameter CACHE_WAY = 4,
    parameter MEMORY_SIZE = 131072,
    parameter ADDR1_BUS_LEN = (TAG_LEN + INDEX_LEN > OFFSET_LEN) ? (TAG_LEN + INDEX_LEN) : OFFSET_LEN,
    parameter ADDR2_BUS_LEN = TAG_LEN + INDEX_LEN,
    parameter CTR1_BUS_LEN = 4,
    parameter CTR2_BUS_LEN = 2
) (
    input logic clk,
    input logic reset,
    input logic start,
    output logic done,
    inout wire [ADDR1_BUS_LEN-1:0] A1,
    inout wire [15:0] D1,
    inout wire [CTR1_BUS_LEN-1:0] C1
);
    localparam logic [CTR1_BUS_LEN-1:0] C1_NOP = 4'd0;
    localparam logic [CTR1_BUS_LEN-1:0] C1_INVALIDATE = 4'd1;
    localparam logic [CTR1_BUS_LEN-1:0] C1_READ_8 = 4'd2;
    localparam logic [CTR1_BUS_LEN-1:0] C1_WRITE_8 = 4'd3;
    localparam logic [CTR1_BUS_LEN-1:0] C1_READ_16 = 4'd4;
    localparam logic [CTR1_BUS_LEN-1:0] C1_WRITE_16 = 4'd5;
    localparam logic [CTR1_BUS_LEN-1:0] C1_READ_32 = 4'd6;
    localparam logic [CTR1_BUS_LEN-1:0] C1_WRITE_32 = 4'd7;
    localparam logic [CTR1_BUS_LEN-1:0] C1_RESPONSE = 4'd8;
    localparam int M_COUNT = 64;
    localparam int N_COUNT = 60;
    localparam int K_COUNT = 32;
    localparam int A_BASE = 17'h00128;
    localparam int B_BASE = 17'h00928;
    localparam int C_BASE = 17'h01828;
    localparam logic [1:0] PHASE_A = 2'd0;
    localparam logic [1:0] PHASE_B = 2'd1;
    localparam logic [1:0] PHASE_C = 2'd2;
    localparam logic [2:0] CPU_IDLE = 3'd0;
    localparam logic [2:0] CPU_SEND_HEADER = 3'd1;
    localparam logic [2:0] CPU_SEND_OFFSET = 3'd2;
    localparam logic [2:0] CPU_SEND_UPPER = 3'd3;
    localparam logic [2:0] CPU_WAIT = 3'd4;
    localparam logic [2:0] CPU_READ_UPPER = 3'd5;
    localparam logic [2:0] CPU_FINISH = 3'd6;

    logic [2:0] state;
    logic [1:0] phase;

    int y;
    int x;
    int k;

    logic signed [7:0] a_value;
    logic signed [31:0] sum;
    logic [15:0] read_low;

    logic [CTR1_BUS_LEN-1:0] request_command;
    logic [ADDRESS_LEN-1:0] request_address;
    logic [31:0] request_data;

    logic cpu_owns_bus1;
    logic [ADDR1_BUS_LEN-1:0] cpu_a1_out;
    logic [15:0] cpu_d1_out;
    logic [CTR1_BUS_LEN-1:0] cpu_c1_out;

    assign A1 = cpu_owns_bus1 ? cpu_a1_out : 'bz;
    assign D1 = cpu_owns_bus1 ? cpu_d1_out : 'bz;
    assign C1 = cpu_owns_bus1 ? cpu_c1_out : 'bz;

    function automatic [31:0] product_sum;
        input logic signed [31:0] old_sum;
        input logic signed [7:0] left;
        input logic [15:0] right;
        logic signed [31:0] left_full;
        logic signed [31:0] right_full;
        begin
            left_full = {{24{left[7]}}, left};
            right_full = {{16{right[15]}}, right};
            product_sum = old_sum + left_full * right_full;
        end
    endfunction

    always @* begin
        cpu_owns_bus1 = 1'b1;
        cpu_a1_out = '0;
        cpu_d1_out = '0;
        cpu_c1_out = C1_NOP;

        case (state)
            CPU_SEND_HEADER: begin
                cpu_c1_out = request_command;
                cpu_a1_out = request_address[ADDRESS_LEN-1:OFFSET_LEN];
            end
            CPU_SEND_OFFSET: begin
                cpu_c1_out = request_command;
                cpu_a1_out = request_address[OFFSET_LEN-1:0];
                if (request_command == C1_WRITE_8 ||
                    request_command == C1_WRITE_16 ||
                    request_command == C1_WRITE_32) begin
                    cpu_d1_out = request_data[15:0];
                end
            end
            CPU_SEND_UPPER: begin
                cpu_c1_out = request_command;
                cpu_a1_out = request_address[OFFSET_LEN-1:0];
                cpu_d1_out = request_data[31:16];
            end
            CPU_WAIT,
            CPU_READ_UPPER: begin
                cpu_owns_bus1 = 1'b0;
            end
            default: begin
                cpu_c1_out = C1_NOP;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= CPU_IDLE;
            done <= 1'b0;
            phase <= PHASE_A;
            y <= 0;
            x <= 0;
            k <= 0;
            a_value <= '0;
            sum <= '0;
            read_low <= '0;
            request_command <= C1_READ_8;
            request_address <= A_BASE;
            request_data <= '0;
        end else begin
            case (state)
                CPU_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        phase <= PHASE_A;
                        y <= 0;
                        x <= 0;
                        k <= 0;
                        sum <= '0;
                        request_command <= C1_READ_8;
                        request_address <= A_BASE;
                        request_data <= '0;
                        state <= CPU_SEND_HEADER;
                    end
                end

                CPU_SEND_HEADER: begin
                    state <= CPU_SEND_OFFSET;
                end

                CPU_SEND_OFFSET: begin
                    if (request_command == C1_WRITE_32) begin
                        state <= CPU_SEND_UPPER;
                    end else begin
                        state <= CPU_WAIT;
                    end
                end

                CPU_SEND_UPPER: begin
                    state <= CPU_WAIT;
                end

                CPU_WAIT: begin
                    if (C1 == C1_RESPONSE) begin
                        read_low <= D1;

                        if (request_command == C1_READ_32) begin
                            state <= CPU_READ_UPPER;
                        end else if (phase == PHASE_A) begin
                            a_value <= $signed(D1[7:0]);
                            phase <= PHASE_B;
                            request_command <= C1_READ_16;
                            request_address <= B_BASE + ((k * N_COUNT + x) * 2);
                            state <= CPU_SEND_HEADER;
                        end else if (phase == PHASE_B) begin
                            sum <= product_sum(sum, a_value, D1);

                            if (k == K_COUNT - 1) begin
                                phase <= PHASE_C;
                                request_command <= C1_WRITE_32;
                                request_address <= C_BASE + ((y * N_COUNT + x) * 4);
                                request_data <= product_sum(sum, a_value, D1);
                                state <= CPU_SEND_HEADER;
                            end else begin
                                k <= k + 1;
                                phase <= PHASE_A;
                                request_command <= C1_READ_8;
                                request_address <= A_BASE + y * K_COUNT + (k + 1);
                                state <= CPU_SEND_HEADER;
                            end
                        end else begin
                            sum <= '0;
                            k <= 0;
                            phase <= PHASE_A;

                            if (x == N_COUNT - 1) begin
                                x <= 0;
                                if (y == M_COUNT - 1) begin
                                    done <= 1'b1;
                                    state <= CPU_FINISH;
                                end else begin
                                    y <= y + 1;
                                    request_command <= C1_READ_8;
                                    request_address <= A_BASE + (y + 1) * K_COUNT;
                                    request_data <= '0;
                                    state <= CPU_SEND_HEADER;
                                end
                            end else begin
                                x <= x + 1;
                                request_command <= C1_READ_8;
                                request_address <= A_BASE + y * K_COUNT;
                                request_data <= '0;
                                state <= CPU_SEND_HEADER;
                            end
                        end
                    end
                end

                CPU_READ_UPPER: begin
                    if (C1 == C1_RESPONSE) begin
                        read_low <= D1;
                        state <= CPU_SEND_HEADER;
                    end
                end

                CPU_FINISH: begin
                    done <= 1'b1;
                end

                default: begin
                    state <= CPU_IDLE;
                end
            endcase
        end
    end
endmodule

module Cache #(
    parameter ADDRESS_LEN = 17,
    parameter TAG_LEN = 7,
    parameter INDEX_LEN = 4,
    parameter OFFSET_LEN = 6,
    parameter CACHE_SIZE = 4096,
    parameter CACHE_LINE_SIZE = 64,
    parameter CACHE_LINE_COUNT = 64,
    parameter CACHE_SET_COUNT = 16,
    parameter CACHE_WAY = 4,
    parameter MEMORY_SIZE = 131072,
    parameter ADDR1_BUS_LEN = (TAG_LEN + INDEX_LEN > OFFSET_LEN) ? (TAG_LEN + INDEX_LEN) : OFFSET_LEN,
    parameter ADDR2_BUS_LEN = TAG_LEN + INDEX_LEN,
    parameter CTR1_BUS_LEN = 4,
    parameter CTR2_BUS_LEN = 2
) (
    input logic clk,
    input logic reset,
    input logic policy,
    output logic [31:0] hits,
    output logic [31:0] accesses,
    inout wire [ADDR1_BUS_LEN-1:0] A1,
    inout wire [15:0] D1,
    inout wire [CTR1_BUS_LEN-1:0] C1,
    inout wire [ADDR2_BUS_LEN-1:0] A2,
    inout wire [15:0] D2,
    inout wire [CTR2_BUS_LEN-1:0] C2
);
    localparam logic POLICY_LRU = 1'b0;
    localparam logic POLICY_BPLRU = 1'b1;
    localparam logic [CTR1_BUS_LEN-1:0] C1_NOP = 4'd0;
    localparam logic [CTR1_BUS_LEN-1:0] C1_INVALIDATE = 4'd1;
    localparam logic [CTR1_BUS_LEN-1:0] C1_READ_8 = 4'd2;
    localparam logic [CTR1_BUS_LEN-1:0] C1_WRITE_8 = 4'd3;
    localparam logic [CTR1_BUS_LEN-1:0] C1_READ_16 = 4'd4;
    localparam logic [CTR1_BUS_LEN-1:0] C1_WRITE_16 = 4'd5;
    localparam logic [CTR1_BUS_LEN-1:0] C1_READ_32 = 4'd6;
    localparam logic [CTR1_BUS_LEN-1:0] C1_WRITE_32 = 4'd7;
    localparam logic [CTR1_BUS_LEN-1:0] C1_RESPONSE = 4'd8;
    localparam logic [CTR2_BUS_LEN-1:0] C2_NOP = 2'd0;
    localparam logic [CTR2_BUS_LEN-1:0] C2_READ = 2'd1;
    localparam logic [CTR2_BUS_LEN-1:0] C2_WRITE = 2'd2;
    localparam logic [CTR2_BUS_LEN-1:0] C2_RESPONSE = 2'd3;
    localparam logic [4:0] CACHE_IDLE = 5'd0;
    localparam logic [4:0] CACHE_GET_OFFSET = 5'd1;
    localparam logic [4:0] CACHE_GET_UPPER = 5'd2;
    localparam logic [4:0] CACHE_ACCESS = 5'd3;
    localparam logic [4:0] CACHE_RESPOND_LOW = 5'd4;
    localparam logic [4:0] CACHE_RESPOND_HIGH = 5'd5;
    localparam logic [4:0] CACHE_RESPOND_DONE = 5'd6;
    localparam logic [4:0] CACHE_WRITE_COMMAND = 5'd7;
    localparam logic [4:0] CACHE_WRITE_DATA = 5'd8;
    localparam logic [4:0] CACHE_WAIT_WRITE = 5'd9;
    localparam logic [4:0] CACHE_READ_COMMAND = 5'd10;
    localparam logic [4:0] CACHE_WAIT_READ = 5'd11;
    localparam logic [4:0] CACHE_READ_DATA = 5'd12;
    localparam logic [4:0] CACHE_AFTER_FILL = 5'd13;

    logic valid [CACHE_SET_COUNT][CACHE_WAY];
    logic dirty [CACHE_SET_COUNT][CACHE_WAY];
    logic [TAG_LEN-1:0] tag_store [CACHE_SET_COUNT][CACHE_WAY];
    logic [7:0] data_store [CACHE_SET_COUNT][CACHE_WAY][CACHE_LINE_SIZE];

    logic [31:0] global_timer;
    logic [31:0] timestamp [CACHE_SET_COUNT][CACHE_WAY];
    logic mru [CACHE_SET_COUNT][CACHE_WAY];

    logic [4:0] state;
    logic [CTR1_BUS_LEN-1:0] request_command;
    logic [TAG_LEN+INDEX_LEN-1:0] request_line;
    logic [OFFSET_LEN-1:0] request_offset;
    logic [31:0] request_data;
    logic [31:0] response_data;

    logic [INDEX_LEN-1:0] active_index;
    logic [TAG_LEN-1:0] active_tag;
    int active_way;
    logic [ADDR2_BUS_LEN-1:0] memory_line;
    logic [ADDR2_BUS_LEN-1:0] victim_line;
    int word;

    logic cache_owns_bus1;
    logic [ADDR1_BUS_LEN-1:0] cache_a1_out;
    logic [15:0] cache_d1_out;
    logic [CTR1_BUS_LEN-1:0] cache_c1_out;

    logic cache_owns_bus2;
    logic [ADDR2_BUS_LEN-1:0] cache_a2_out;
    logic [15:0] cache_d2_out;
    logic [CTR2_BUS_LEN-1:0] cache_c2_out;

    assign A1 = cache_owns_bus1 ? cache_a1_out : 'bz;
    assign D1 = cache_owns_bus1 ? cache_d1_out : 'bz;
    assign C1 = cache_owns_bus1 ? cache_c1_out : 'bz;

    assign A2 = cache_owns_bus2 ? cache_a2_out : 'bz;
    assign D2 = cache_owns_bus2 ? cache_d2_out : 'bz;
    assign C2 = cache_owns_bus2 ? cache_c2_out : 'bz;

    function automatic bit is_read;
        input logic [CTR1_BUS_LEN-1:0] command;
        begin
            is_read = command == C1_READ_8 ||
                      command == C1_READ_16 ||
                      command == C1_READ_32;
        end
    endfunction

    function automatic bit is_write;
        input logic [CTR1_BUS_LEN-1:0] command;
        begin
            is_write = command == C1_WRITE_8 ||
                       command == C1_WRITE_16 ||
                       command == C1_WRITE_32;
        end
    endfunction

    function automatic int find_hit;
        input logic [INDEX_LEN-1:0] set;
        input logic [TAG_LEN-1:0] tag;
        int way;
        begin
            find_hit = -1;
            for (way = 0; way < CACHE_WAY; way = way + 1) begin
                if (valid[set][way] && tag_store[set][way] == tag) begin
                    find_hit = way;
                end
            end
        end
    endfunction

    function automatic int choose_victim;
        input logic [INDEX_LEN-1:0] set;
        input logic selected;
        int way;
        int victim;
        logic [31:0] oldest;
        begin
            victim = 0;
            choose_victim = -1;

            for (way = 0; way < CACHE_WAY; way = way + 1) begin
                if (!valid[set][way] && choose_victim == -1) begin
                    choose_victim = way;
                end
            end

            if (choose_victim == -1) begin
                if (selected == POLICY_LRU) begin
                    oldest = timestamp[set][0];
                    victim = 0;
                    for (way = 1; way < CACHE_WAY; way = way + 1) begin
                        if (timestamp[set][way] < oldest) begin
                            oldest = timestamp[set][way];
                            victim = way;
                        end
                    end
                    choose_victim = victim;
                end else begin
                    for (way = 0; way < CACHE_WAY; way = way + 1) begin
                        if (!mru[set][way] && choose_victim == -1) begin
                            choose_victim = way;
                        end
                    end
                end
            end
        end
    endfunction

    function automatic [31:0] read_from_line;
        input logic [INDEX_LEN-1:0] set;
        input int way;
        input logic [OFFSET_LEN-1:0] offset;
        input logic [CTR1_BUS_LEN-1:0] command;
        begin
            read_from_line = '0;
            if (command == C1_READ_8) begin
                read_from_line = {24'd0, data_store[set][way][offset]};
            end else if (command == C1_READ_16) begin
                read_from_line = {16'd0,
                                  data_store[set][way][offset + 1],
                                  data_store[set][way][offset]};
            end else begin
                read_from_line = {data_store[set][way][offset + 3],
                                  data_store[set][way][offset + 2],
                                  data_store[set][way][offset + 1],
                                  data_store[set][way][offset]};
            end
        end
    endfunction

    task automatic update_policy;
        input logic [INDEX_LEN-1:0] set;
        input int way;
        int other;
        bit all_after;
        begin
            if (policy == POLICY_LRU) begin
                timestamp[set][way] <= global_timer;
                global_timer <= global_timer + 1;
            end else begin
                all_after = 1'b1;
                for (other = 0; other < CACHE_WAY; other = other + 1) begin
                    if (other != way && !mru[set][other]) begin
                        all_after = 1'b0;
                    end
                end

                for (other = 0; other < CACHE_WAY; other = other + 1) begin
                    if (other == way) begin
                        mru[set][other] <= 1'b1;
                    end else if (all_after) begin
                        mru[set][other] <= 1'b0;
                    end
                end
            end
        end
    endtask

    task automatic write_to_line;
        input logic [INDEX_LEN-1:0] set;
        input int way;
        input logic [OFFSET_LEN-1:0] offset;
        input logic [CTR1_BUS_LEN-1:0] command;
        input logic [31:0] value;
        begin
            if (command == C1_WRITE_8) begin
                data_store[set][way][offset] <= value[7:0];
            end else if (command == C1_WRITE_16) begin
                data_store[set][way][offset] <= value[7:0];
                data_store[set][way][offset + 1] <= value[15:8];
            end else begin
                data_store[set][way][offset] <= value[7:0];
                data_store[set][way][offset + 1] <= value[15:8];
                data_store[set][way][offset + 2] <= value[23:16];
                data_store[set][way][offset + 3] <= value[31:24];
            end
            dirty[set][way] <= 1'b1;
        end
    endtask

    always @* begin
        cache_owns_bus1 = 1'b0;
        cache_a1_out = '0;
        cache_d1_out = '0;
        cache_c1_out = C1_NOP;

        if (state == CACHE_RESPOND_LOW) begin
            cache_owns_bus1 = 1'b1;
            cache_c1_out = C1_RESPONSE;
            cache_d1_out = response_data[15:0];
        end else if (state == CACHE_RESPOND_HIGH) begin
            cache_owns_bus1 = 1'b1;
            cache_c1_out = C1_RESPONSE;
            cache_d1_out = response_data[31:16];
        end else if (state == CACHE_RESPOND_DONE) begin
            cache_owns_bus1 = 1'b1;
            cache_c1_out = C1_RESPONSE;
        end
        cache_owns_bus2 = 1'b1;
        cache_a2_out = '0;
        cache_d2_out = '0;
        cache_c2_out = C2_NOP;

        case (state)
            CACHE_WRITE_COMMAND: begin
                cache_c2_out = C2_WRITE;
                cache_a2_out = victim_line;
            end
            CACHE_WRITE_DATA: begin
                cache_c2_out = C2_WRITE;
                cache_a2_out = victim_line;
                cache_d2_out = {data_store[active_index][active_way][word * 2 + 1],
                                data_store[active_index][active_way][word * 2]};
            end
            CACHE_READ_COMMAND: begin
                cache_c2_out = C2_READ;
                cache_a2_out = memory_line;
            end
            CACHE_WAIT_WRITE,
            CACHE_WAIT_READ,
            CACHE_READ_DATA: begin
                cache_owns_bus2 = 1'b0;
            end
            default: begin
                cache_c2_out = C2_NOP;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        int set_index;
        int way;
        int byte_index;
        int hit_way;
        int victim_way;

        if (reset) begin
            state <= CACHE_IDLE;
            hits <= '0;
            accesses <= '0;
            global_timer <= '0;
            request_command <= C1_NOP;
            request_line <= '0;
            request_offset <= '0;
            request_data <= '0;
            response_data <= '0;
            active_index <= '0;
            active_tag <= '0;
            active_way <= 0;
            memory_line <= '0;
            victim_line <= '0;
            word <= 0;

            for (set_index = 0; set_index < CACHE_SET_COUNT; set_index = set_index + 1) begin
                for (way = 0; way < CACHE_WAY; way = way + 1) begin
                    valid[set_index][way] <= 1'b0;
                    dirty[set_index][way] <= 1'b0;
                    tag_store[set_index][way] <= '0;
                    timestamp[set_index][way] <= '0;
                    mru[set_index][way] <= 1'b0;
                    for (byte_index = 0; byte_index < CACHE_LINE_SIZE; byte_index = byte_index + 1) begin
                        data_store[set_index][way][byte_index] <= '0;
                    end
                end
            end
        end else begin
            case (state)
                CACHE_IDLE: begin
                    if (C1 != C1_NOP && C1 !== 'bz) begin
                        request_command <= C1;
                        request_line <= A1[TAG_LEN+INDEX_LEN-1:0];
                        state <= CACHE_GET_OFFSET;
                    end
                end

                CACHE_GET_OFFSET: begin
                    request_offset <= A1[OFFSET_LEN-1:0];
                    request_data[15:0] <= D1;
                    if (request_command == C1_WRITE_32) begin
                        state <= CACHE_GET_UPPER;
                    end else begin
                        state <= CACHE_ACCESS;
                    end
                end

                CACHE_GET_UPPER: begin
                    request_data[31:16] <= D1;
                    state <= CACHE_ACCESS;
                end

                CACHE_ACCESS: begin
                    active_tag <= request_line[TAG_LEN+INDEX_LEN-1:INDEX_LEN];
                    active_index <= request_line[INDEX_LEN-1:0];
                    memory_line <= request_line;
                    accesses <= accesses + 1;

                    hit_way = find_hit(request_line[INDEX_LEN-1:0],
                                       request_line[TAG_LEN+INDEX_LEN-1:INDEX_LEN]);

                    if (hit_way != -1) begin
                        hits <= hits + 1;
                        active_way <= hit_way;
                        update_policy(request_line[INDEX_LEN-1:0], hit_way);

                        if (is_read(request_command)) begin
                            response_data <= read_from_line(request_line[INDEX_LEN-1:0],
                                                            hit_way,
                                                            request_offset,
                                                            request_command);
                            state <= CACHE_RESPOND_LOW;
                        end else if (is_write(request_command)) begin
                            write_to_line(request_line[INDEX_LEN-1:0],
                                          hit_way,
                                          request_offset,
                                          request_command,
                                          request_data);
                            state <= CACHE_RESPOND_DONE;
                        end else begin
                            valid[request_line[INDEX_LEN-1:0]][hit_way] <= 1'b0;
                            dirty[request_line[INDEX_LEN-1:0]][hit_way] <= 1'b0;
                            state <= CACHE_RESPOND_DONE;
                        end
                    end else if (request_command == C1_INVALIDATE) begin
                        state <= CACHE_RESPOND_DONE;
                    end else begin
                        victim_way = choose_victim(request_line[INDEX_LEN-1:0], policy);
                        active_way <= victim_way;
                        victim_line <= {tag_store[request_line[INDEX_LEN-1:0]][victim_way],
                                        request_line[INDEX_LEN-1:0]};
                        word <= 0;

                        if (valid[request_line[INDEX_LEN-1:0]][victim_way] &&
                            dirty[request_line[INDEX_LEN-1:0]][victim_way]) begin
                            state <= CACHE_WRITE_COMMAND;
                        end else begin
                            state <= CACHE_READ_COMMAND;
                        end
                    end
                end

                CACHE_RESPOND_LOW: begin
                    if (request_command == C1_READ_32) begin
                        state <= CACHE_RESPOND_HIGH;
                    end else begin
                        state <= CACHE_IDLE;
                    end
                end

                CACHE_RESPOND_HIGH: begin
                    state <= CACHE_IDLE;
                end

                CACHE_RESPOND_DONE: begin
                    state <= CACHE_IDLE;
                end

                CACHE_WRITE_COMMAND: begin
                    word <= 0;
                    state <= CACHE_WRITE_DATA;
                end

                CACHE_WRITE_DATA: begin
                    if (word == CACHE_LINE_SIZE / 2 - 1) begin
                        word <= 0;
                        state <= CACHE_WAIT_WRITE;
                    end else begin
                        word <= word + 1;
                    end
                end

                CACHE_WAIT_WRITE: begin
                    if (C2 == C2_RESPONSE) begin
                        dirty[active_index][active_way] <= 1'b0;
                        state <= CACHE_READ_COMMAND;
                    end
                end

                CACHE_READ_COMMAND: begin
                    word <= 0;
                    state <= CACHE_WAIT_READ;
                end

                CACHE_WAIT_READ: begin
                    if (C2 == C2_RESPONSE) begin
                        data_store[active_index][active_way][0] <= D2[7:0];
                        data_store[active_index][active_way][1] <= D2[15:8];
                        word <= 1;
                        state <= CACHE_READ_DATA;
                    end
                end

                CACHE_READ_DATA: begin
                    data_store[active_index][active_way][word * 2] <= D2[7:0];
                    data_store[active_index][active_way][word * 2 + 1] <= D2[15:8];

                    if (word == CACHE_LINE_SIZE / 2 - 1) begin
                        word <= 0;
                        state <= CACHE_AFTER_FILL;
                    end else begin
                        word <= word + 1;
                    end
                end

                CACHE_AFTER_FILL: begin
                    valid[active_index][active_way] <= 1'b1;
                    tag_store[active_index][active_way] <= active_tag;
                    dirty[active_index][active_way] <= 1'b0;
                    update_policy(active_index, active_way);

                    if (is_write(request_command)) begin
                        write_to_line(active_index,
                                      active_way,
                                      request_offset,
                                      request_command,
                                      request_data);
                        state <= CACHE_RESPOND_DONE;
                    end else begin
                        response_data <= read_from_line(active_index,
                                                        active_way,
                                                        request_offset,
                                                        request_command);
                        state <= CACHE_RESPOND_LOW;
                    end
                end

                default: begin
                    state <= CACHE_IDLE;
                end
            endcase
        end
    end
endmodule

module Controller #(
    parameter ADDRESS_LEN = 17,
    parameter TAG_LEN = 7,
    parameter INDEX_LEN = 4,
    parameter OFFSET_LEN = 6,
    parameter CACHE_SIZE = 4096,
    parameter CACHE_LINE_SIZE = 64,
    parameter CACHE_LINE_COUNT = 64,
    parameter CACHE_SET_COUNT = 16,
    parameter CACHE_WAY = 4,
    parameter MEMORY_SIZE = 131072,
    parameter ADDR1_BUS_LEN = (TAG_LEN + INDEX_LEN > OFFSET_LEN) ? (TAG_LEN + INDEX_LEN) : OFFSET_LEN,
    parameter ADDR2_BUS_LEN = TAG_LEN + INDEX_LEN,
    parameter CTR1_BUS_LEN = 4,
    parameter CTR2_BUS_LEN = 2
) (
    input logic clk,
    input logic reset,
    inout wire [ADDR2_BUS_LEN-1:0] A2,
    inout wire [15:0] D2,
    inout wire [CTR2_BUS_LEN-1:0] C2
);
    localparam logic [CTR2_BUS_LEN-1:0] C2_NOP = 2'd0;
    localparam logic [CTR2_BUS_LEN-1:0] C2_READ = 2'd1;
    localparam logic [CTR2_BUS_LEN-1:0] C2_WRITE = 2'd2;
    localparam logic [CTR2_BUS_LEN-1:0] C2_RESPONSE = 2'd3;
    localparam logic [1:0] MEM_IDLE = 2'd0;
    localparam logic [1:0] MEM_READ_RESPONSE = 2'd1;
    localparam logic [1:0] MEM_WRITE_RECEIVE = 2'd2;
    localparam logic [1:0] MEM_WRITE_RESPONSE = 2'd3;
    logic [7:0] memory [MEMORY_SIZE];
    logic [1:0] state;
    logic [ADDRESS_LEN-1:0] base_address;
    logic [15:0] response_word;
    int word;

    logic mem_owns_bus2;
    logic [ADDR2_BUS_LEN-1:0] mem_a2_out;
    logic [15:0] mem_d2_out;
    logic [CTR2_BUS_LEN-1:0] mem_c2_out;

    assign A2 = mem_owns_bus2 ? mem_a2_out : 'bz;
    assign D2 = mem_owns_bus2 ? mem_d2_out : 'bz;
    assign C2 = mem_owns_bus2 ? mem_c2_out : 'bz;

    always @* begin
        mem_owns_bus2 = 1'b0;
        mem_a2_out = '0;
        mem_d2_out = '0;
        mem_c2_out = C2_NOP;

        if (state == MEM_READ_RESPONSE) begin
            mem_owns_bus2 = 1'b1;
            mem_c2_out = C2_RESPONSE;
            mem_d2_out = response_word;
        end else if (state == MEM_WRITE_RESPONSE) begin
            mem_owns_bus2 = 1'b1;
            mem_c2_out = C2_RESPONSE;
        end
    end

    always_ff @(posedge clk) begin
        int index;

        if (reset) begin
            state <= MEM_IDLE;
            base_address <= '0;
            response_word <= '0;
            word <= 0;
            for (index = 0; index < MEMORY_SIZE; index = index + 1) begin
                memory[index] <= index[7:0];
            end
        end else begin
            case (state)
                MEM_IDLE: begin
                    if (C2 == C2_READ) begin
                        base_address <= {A2, {OFFSET_LEN{1'b0}}};
                        response_word <= {memory[{A2, {OFFSET_LEN{1'b0}}} + 1],
                                          memory[{A2, {OFFSET_LEN{1'b0}}}]};
                        word <= 0;
                        state <= MEM_READ_RESPONSE;
                    end else if (C2 == C2_WRITE) begin
                        base_address <= {A2, {OFFSET_LEN{1'b0}}};
                        word <= 0;
                        state <= MEM_WRITE_RECEIVE;
                    end
                end

                MEM_READ_RESPONSE: begin
                    if (word == CACHE_LINE_SIZE / 2 - 1) begin
                        word <= 0;
                        state <= MEM_IDLE;
                    end else begin
                        response_word <= {memory[base_address + (word + 1) * 2 + 1],
                                          memory[base_address + (word + 1) * 2]};
                        word <= word + 1;
                    end
                end

                MEM_WRITE_RECEIVE: begin
                    memory[base_address + word * 2] <= D2[7:0];
                    memory[base_address + word * 2 + 1] <= D2[15:8];

                    if (word == CACHE_LINE_SIZE / 2 - 1) begin
                        word <= 0;
                        state <= MEM_WRITE_RESPONSE;
                    end else begin
                        word <= word + 1;
                    end
                end

                MEM_WRITE_RESPONSE: begin
                    state <= MEM_IDLE;
                end

                default: begin
                    state <= MEM_IDLE;
                end
            endcase
        end
    end
endmodule

module testbench;
    parameter ADDRESS_LEN = 17;
    parameter TAG_LEN = 7;
    parameter INDEX_LEN = 4;
    parameter OFFSET_LEN = 6;
    parameter CACHE_SIZE = 4096;
    parameter CACHE_LINE_SIZE = 64;
    parameter CACHE_LINE_COUNT = 64;
    parameter CACHE_SET_COUNT = 16;
    parameter CACHE_WAY = 4;
    parameter MEMORY_SIZE = 131072;
    parameter ADDR1_BUS_LEN = (TAG_LEN + INDEX_LEN > OFFSET_LEN) ? (TAG_LEN + INDEX_LEN) : OFFSET_LEN;
    parameter ADDR2_BUS_LEN = TAG_LEN + INDEX_LEN;
    parameter CTR1_BUS_LEN = 4;
    parameter CTR2_BUS_LEN = 2;

    logic clk;
    logic reset;
    logic start;
    logic policy;
    logic done;
    logic [31:0] hits;
    logic [31:0] accesses;
    logic [31:0] lru_hits;
    logic [31:0] lru_accesses;
    logic [31:0] bplru_hits;
    logic [31:0] bplru_accesses;

    tri [ADDR1_BUS_LEN-1:0] A1;
    tri [15:0] D1;
    tri [CTR1_BUS_LEN-1:0] C1;
    tri [ADDR2_BUS_LEN-1:0] A2;
    tri [15:0] D2;
    tri [CTR2_BUS_LEN-1:0] C2;

    Cpu cpu (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .A1(A1),
        .D1(D1),
        .C1(C1)
    );

    Cache cache (
        .clk(clk),
        .reset(reset),
        .policy(policy),
        .hits(hits),
        .accesses(accesses),
        .A1(A1),
        .D1(D1),
        .C1(C1),
        .A2(A2),
        .D2(D2),
        .C2(C2)
    );

    Controller mem (
        .clk(clk),
        .reset(reset),
        .A2(A2),
        .D2(D2),
        .C2(C2)
    );

    initial begin
        clk = 1'b0;
        forever #1 clk = ~clk;
    end

    task automatic run_once;
        input logic selected;
        output logic [31:0] run_hits;
        output logic [31:0] run_accesses;
        begin
            policy = selected;
            start = 1'b0;
            reset = 1'b1;
            repeat (3) @(posedge clk);
            reset = 1'b0;
            @(posedge clk);
            start = 1'b1;
            wait (done == 1'b1);
            @(posedge clk);
            run_hits = hits;
            run_accesses = accesses;
            start = 1'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        start = 1'b0;
        policy = 1'b0;
        lru_hits = '0;
        lru_accesses = '0;
        bplru_hits = '0;
        bplru_accesses = '0;

        run_once(1'b0, lru_hits, lru_accesses);
        run_once(1'b1, bplru_hits, bplru_accesses);

        $display("| replacement |  hitrate  |    hits    |  accesses  |");
        $display("| :---------- | --------: | ---------: | ----------: |");
        $display("| LRU         |  %3.4f%% | %10d | %10d |", (100.0 * lru_hits) / lru_accesses, lru_hits, lru_accesses);
        $display("| bpLRU       |  %3.4f%% | %10d | %10d |", (100.0 * bplru_hits) / bplru_accesses, bplru_hits, bplru_accesses);

        $finish(0);
    end
endmodule
