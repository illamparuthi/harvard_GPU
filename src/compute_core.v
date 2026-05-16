module compute_core (
    input clk,
    input rst,
    input start,
    output reg done,

    // Port A: Instruction Fetch
    output wire [9:0] instr_addr,
    input  wire [31:0] instr_data,

    // Port B: Data Load/Store
    output reg  [9:0] mem_addr,
    input  wire [31:0] mem_data_in,
    output reg  [31:0] mem_data_out,
    output reg  mem_we,

    // Debug Ports
    output reg [1:0] warp_id, 
    output wire core_stall,
    output wire simd_active
);

reg [9:0] pc [0:3];
integer i;

assign instr_addr = pc[warp_id]; 

reg [31:0] instr;
wire [7:0] opcode = instr[31:24];
wire [3:0] rd     = instr[23:20];
wire [3:0] rs1    = instr[19:16];
wire [3:0] rs2    = instr[15:12];
wire [9:0] addr   = instr[9:0];  

wire is_load  = (opcode == 8'h01);
wire is_store = (opcode == 8'h02);
wire is_add   = (opcode == 8'h03);
wire is_halt  = (opcode == 8'hFF);

reg [2:0] state;
localparam IDLE           = 0,
           WAIT_FETCH     = 1,
           EXECUTE        = 2,  
           WAIT_MEM_LOAD  = 3,
           WAIT_MEM_STORE = 4;

reg [3:0] lane_ctr; 

wire sb_set   = (state == EXECUTE) && is_load && !core_stall;
wire sb_clear = (state == WAIT_MEM_LOAD) && (lane_ctr == 15);

scoreboard warp_scoreboard (
    .clk(clk),
    .rst(rst),
    .warp_id(warp_id),
    .rs1(rs1),
    .rs2(rs2),
    .stall(core_stall),
    .set_busy(sb_set),
    .dest_reg_set(rd),
    .clear_busy(sb_clear),
    .dest_reg_clear(rd)
);

wire [31:0] lane_rd1 [0:15];
wire [31:0] lane_rd2 [0:15];
reg  [15:0] rf_we_bus; 
wire [31:0] rf_wd    [0:15];

wire [511:0] simd_a, simd_b, simd_out;

genvar lane;
generate
    for (lane = 0; lane < 16; lane = lane + 1) begin : vector_lanes
        regfile rf (
            .clk(clk), .rst(rst), .rs1(rs1), .rs2(rs2), .rd(rd),
            .wd(rf_wd[lane]), .we(rf_we_bus[lane]),
            .rd1(lane_rd1[lane]), .rd2(lane_rd2[lane])
        );
        assign simd_a[lane*32 + 31 : lane*32] = lane_rd1[lane];
        assign simd_b[lane*32 + 31 : lane*32] = lane_rd2[lane];
        
        assign rf_wd[lane] = (is_load) ? mem_data_in : simd_out[lane*32 + 31 : lane*32];
    end
endgenerate

simd_wrapper execution_unit (
    .a(simd_a), .b(simd_b), .opcode(3'b000), .mask(16'hFFFF), .result(simd_out)
);

assign simd_active = (state == EXECUTE && is_add && !core_stall);

reg [31:0] next_store_data;
always @(*) begin
    case (lane_ctr)
        4'd0:  next_store_data = lane_rd1[1];
        4'd1:  next_store_data = lane_rd1[2];
        4'd2:  next_store_data = lane_rd1[3];
        4'd3:  next_store_data = lane_rd1[4];
        4'd4:  next_store_data = lane_rd1[5];
        4'd5:  next_store_data = lane_rd1[6];
        4'd6:  next_store_data = lane_rd1[7];
        4'd7:  next_store_data = lane_rd1[8];
        4'd8:  next_store_data = lane_rd1[9];
        4'd9:  next_store_data = lane_rd1[10];
        4'd10: next_store_data = lane_rd1[11];
        4'd11: next_store_data = lane_rd1[12];
        4'd12: next_store_data = lane_rd1[13];
        4'd13: next_store_data = lane_rd1[14];
        4'd14: next_store_data = lane_rd1[15];
        default: next_store_data = 32'd0;
    endcase
end

// --- FSM ---
always @(posedge clk) begin
    if (rst) begin
        state    <= IDLE;
        warp_id  <= 2'b00;
        done     <= 0;
        mem_we   <= 0;
        mem_addr <= 0;
        mem_data_out <= 32'd0;
        rf_we_bus <= 16'h0000;
        lane_ctr <= 0;
        instr    <= 32'd0; // FIX: Protect against X-propagation during init
        for (i = 0; i < 4; i = i + 1) pc[i] <= 0;
    end else begin
        case (state)
            IDLE: begin
                done <= 0;
                rf_we_bus <= 16'h0000;
                if (start) state <= WAIT_FETCH;
            end

            WAIT_FETCH: begin
                rf_we_bus <= 16'h0000;
                instr <= instr_data; 
                state <= EXECUTE;
            end

            EXECUTE: begin
                if (core_stall) begin
                    state <= EXECUTE; 
                end
                else if (is_halt) begin          
                    done <= 1;      
                    state <= IDLE;  
                end
                else if (is_add) begin
                    rf_we_bus <= 16'hFFFF; 
                    pc[warp_id] <= pc[warp_id] + 1;
                    warp_id <= warp_id + 1; 
                    state <= WAIT_FETCH; 
                end
                else if (is_load) begin
                    mem_addr <= addr;      
                    mem_we   <= 0;
                    lane_ctr <= 0;
                    rf_we_bus <= 16'h0000;
                    state <= WAIT_MEM_LOAD;
                end
                else if (is_store) begin
                    mem_addr <= addr;      
                    mem_we   <= 1;
                    mem_data_out <= lane_rd1[0]; 
                    lane_ctr <= 0;
                    rf_we_bus <= 16'h0000;
                    state <= WAIT_MEM_STORE;
                end
            end

            WAIT_MEM_LOAD: begin
                rf_we_bus <= (16'b1 << lane_ctr); 

                if (lane_ctr == 15) begin
                    state <= WAIT_FETCH;
                    pc[warp_id] <= pc[warp_id] + 1;
                    warp_id <= warp_id + 1; 
                end else begin
                    lane_ctr <= lane_ctr + 1;
                    mem_addr <= addr + lane_ctr + 1; 
                end
            end
            
            WAIT_MEM_STORE: begin
                rf_we_bus <= 16'h0000;
                
                if (lane_ctr == 15) begin
                    mem_we  <= 0;
                    state <= WAIT_FETCH;
                    pc[warp_id] <= pc[warp_id] + 1;
                    warp_id <= warp_id + 1; 
                end else begin
                    lane_ctr <= lane_ctr + 1;
                    mem_addr <= addr + lane_ctr + 1; 
                    mem_we   <= 1;
                    mem_data_out <= next_store_data; 
                end
            end
        endcase
    end
end
endmodule