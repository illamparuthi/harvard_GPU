module C2S0284 (
    // External Physical Pads
    input  wire clk_pad,
    input  wire rst_n_pad,   
    input  wire start_pad,   
    output wire done_pad,

    // --- 8-Bit Byte-Multiplexed Interface ---
    input  wire [7:0]  host_data_in_pad,  
    output wire [7:0]  host_data_out_pad, 
    
    input  wire [9:0]  host_addr_pad,     
    input  wire        host_we_pad,
    input  wire        host_req_pad,
    output wire        host_ack_pad,
    
    input  wire [1:0]  host_byte_sel_pad 
);

wire clk_pad_in;
wire clk;
wire rst_n;
wire start;
wire done;

wire [7:0]  host_data_in;
wire [7:0]  host_data_out;
wire [9:0]  host_addr;
wire host_we;
wire host_req;
wire host_ack;
wire [1:0]  host_byte_sel;

pc3d01 u_clk_buf (.PAD(clk_pad), .CIN(clk_pad_in));
pc3c01 u_clk_pad (.CCLK(clk_pad_in), .CP(clk)); 

pc3d01 u_rst_pad   (.PAD(rst_n_pad),        .CIN(rst_n));
pc3d01 u_start_pad (.PAD(start_pad),        .CIN(start));
pc3d01 u_we_pad    (.PAD(host_we_pad),      .CIN(host_we));
pc3d01 u_req_pad   (.PAD(host_req_pad),     .CIN(host_req));

pc3d01 u_sel_pad_0 (.PAD(host_byte_sel_pad[0]), .CIN(host_byte_sel[0]));
pc3d01 u_sel_pad_1 (.PAD(host_byte_sel_pad[1]), .CIN(host_byte_sel[1]));

pc3d01 u_host_data_inpad_0  (.PAD(host_data_in_pad[0]),  .CIN(host_data_in[0]));
pc3d01 u_host_data_inpad_1  (.PAD(host_data_in_pad[1]),  .CIN(host_data_in[1]));
pc3d01 u_host_data_inpad_2  (.PAD(host_data_in_pad[2]),  .CIN(host_data_in[2]));
pc3d01 u_host_data_inpad_3  (.PAD(host_data_in_pad[3]),  .CIN(host_data_in[3]));
pc3d01 u_host_data_inpad_4  (.PAD(host_data_in_pad[4]),  .CIN(host_data_in[4]));
pc3d01 u_host_data_inpad_5  (.PAD(host_data_in_pad[5]),  .CIN(host_data_in[5]));
pc3d01 u_host_data_inpad_6  (.PAD(host_data_in_pad[6]),  .CIN(host_data_in[6]));
pc3d01 u_host_data_inpad_7  (.PAD(host_data_in_pad[7]),  .CIN(host_data_in[7]));

pc3d01 u_host_addrpad_0 (.PAD(host_addr_pad[0]), .CIN(host_addr[0]));
pc3d01 u_host_addrpad_1 (.PAD(host_addr_pad[1]), .CIN(host_addr[1]));
pc3d01 u_host_addrpad_2 (.PAD(host_addr_pad[2]), .CIN(host_addr[2]));
pc3d01 u_host_addrpad_3 (.PAD(host_addr_pad[3]), .CIN(host_addr[3]));
pc3d01 u_host_addrpad_4 (.PAD(host_addr_pad[4]), .CIN(host_addr[4]));
pc3d01 u_host_addrpad_5 (.PAD(host_addr_pad[5]), .CIN(host_addr[5]));
pc3d01 u_host_addrpad_6 (.PAD(host_addr_pad[6]), .CIN(host_addr[6]));
pc3d01 u_host_addrpad_7 (.PAD(host_addr_pad[7]), .CIN(host_addr[7]));
pc3d01 u_host_addrpad_8 (.PAD(host_addr_pad[8]), .CIN(host_addr[8]));
pc3d01 u_host_addrpad_9 (.PAD(host_addr_pad[9]), .CIN(host_addr[9]));

pc3o05 u_done_pad (.I(done),     .PAD(done_pad));
pc3o05 u_ack_pad  (.I(host_ack), .PAD(host_ack_pad));

pc3o05 u_host_data_outpad_0 (.I(host_data_out[0]), .PAD(host_data_out_pad[0]));
pc3o05 u_host_data_outpad_1 (.I(host_data_out[1]), .PAD(host_data_out_pad[1]));
pc3o05 u_host_data_outpad_2 (.I(host_data_out[2]), .PAD(host_data_out_pad[2]));
pc3o05 u_host_data_outpad_3 (.I(host_data_out[3]), .PAD(host_data_out_pad[3]));
pc3o05 u_host_data_outpad_4 (.I(host_data_out[4]), .PAD(host_data_out_pad[4]));
pc3o05 u_host_data_outpad_5 (.I(host_data_out[5]), .PAD(host_data_out_pad[5]));
pc3o05 u_host_data_outpad_6 (.I(host_data_out[6]), .PAD(host_data_out_pad[6]));
pc3o05 u_host_data_outpad_7 (.I(host_data_out[7]), .PAD(host_data_out_pad[7]));

wire rst = ~rst_n; 

reg [23:0] write_buffer;
always @(posedge clk) begin
    if (rst) begin
        write_buffer <= 24'd0; // FIX: Prevent X-propagation in the host datapath
    end else if (host_we) begin
        if (host_byte_sel == 2'b00) write_buffer[7:0]   <= host_data_in;
        if (host_byte_sel == 2'b01) write_buffer[15:8]  <= host_data_in;
        if (host_byte_sel == 2'b10) write_buffer[23:16] <= host_data_in;
    end
end

wire [31:0] full_host_word = {host_data_in, write_buffer[23:0]};
wire        host_ram_we    = host_we && (host_byte_sel == 2'b11);

wire [9:0]  gpu_instr_addr; wire [31:0] gpu_instr_data;
wire [9:0]  gpu_data_addr;  wire [31:0] gpu_data_in; 
wire [31:0] gpu_data_out;   wire        gpu_data_we;

wire [9:0]  ram_b_addr = (start) ? gpu_data_addr : host_addr;
wire        ram_b_we   = (start) ? gpu_data_we   : host_ram_we;
wire [31:0] ram_b_din  = (start) ? gpu_data_out  : full_host_word;
wire [31:0] ram_b_dout;

assign gpu_data_in = ram_b_dout; 

assign host_data_out = (host_byte_sel == 2'b00) ? ram_b_dout[7:0]   :
                       (host_byte_sel == 2'b01) ? ram_b_dout[15:8]  :
                       (host_byte_sel == 2'b10) ? ram_b_dout[23:16] :
                                                  ram_b_dout[31:24] ;

reg ack_delay;
always @(posedge clk) begin
    if (rst) ack_delay <= 1'b0; 
    else     ack_delay <= host_req && !start;
end
assign host_ack = ack_delay;

shared_mem spram_macro (
    .clk(clk),
    .addr_a(gpu_instr_addr), .dout_a(gpu_instr_data),
    .we_b(ram_b_we), .addr_b(ram_b_addr), .din_b(ram_b_din), .dout_b(ram_b_dout)
);

gpu gpu_core (
    .clk(clk), .rst_n(rst_n), .start(start), .done(done), .cfg(6'b000000), 
    .instr_addr(gpu_instr_addr), .instr_data(gpu_instr_data),
    .mem_addr(gpu_data_addr), .mem_data_in(gpu_data_in), .mem_data_out(gpu_data_out), .mem_we(gpu_data_we),
    .warp_active(), .core_stall(), .simd_active()
);

endmodule