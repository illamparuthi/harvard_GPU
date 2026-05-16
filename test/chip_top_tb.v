`timescale 1ns/1ps // CRITICAL FIX 1: Timing scale for standard cells

module chip_top_tb;
    // Physical Pad Signals
    reg  clk_pad;
    reg  rst_n_pad;
    reg  start_pad;
    wire done_pad;

    // --- 8-Bit Byte-Multiplexed Interface Pads ---
    reg  [7:0] host_data_in_pad;
    wire [7:0] host_data_out_pad; 
    
    reg  [9:0] host_addr_pad;
    reg        host_we_pad;
    reg        host_req_pad;
    wire       host_ack_pad;
    
    reg  [1:0] host_byte_sel_pad;

    reg [31:0] reconstructed_read = 32'd0; 
    integer k; 

initial begin 
        $sdf_annotate(
            "/home/illam/Ilam/GPU/Tapeout/PnR/Gpu_routing/Routing/C2S0284_routingfiller.sdf",
            dut, 
            ,
            "sdf.log",
            "MAXIMUM"
        );
    end

    C2S0284 dut (
        .clk_pad(clk_pad),
        .rst_n_pad(rst_n_pad),
        .start_pad(start_pad),
        .done_pad(done_pad),
        .host_data_in_pad(host_data_in_pad),     
        .host_data_out_pad(host_data_out_pad),   
        .host_addr_pad(host_addr_pad),
        .host_we_pad(host_we_pad), 
        .host_req_pad(host_req_pad), 
        .host_ack_pad(host_ack_pad),
        .host_byte_sel_pad(host_byte_sel_pad)
    );

    // Clean Clock Generation
    initial begin
        clk_pad = 0;
        forever #12.5 clk_pad = ~clk_pad; // 40MHz
    end

    // --- CRITICAL FIX 2: Added #2 stimulus delays to prevent setup/hold races ---
    task write_mem(input [9:0] addr, input [31:0] data);
        begin
            @(negedge clk_pad); #2; 
            host_addr_pad = addr; 
            host_req_pad  = 1;
            host_we_pad   = 0; // Ensure WE is completely off

            // BYTE 0
            host_byte_sel_pad = 2'b00; host_data_in_pad = data[7:0];
            @(negedge clk_pad); #2; host_we_pad = 1; // Pulse WE High
            @(negedge clk_pad); #2; host_we_pad = 0; // Drop WE Low

            // BYTE 1
            host_byte_sel_pad = 2'b01; host_data_in_pad = data[15:8];
            @(negedge clk_pad); #2; host_we_pad = 1; 
            @(negedge clk_pad); #2; host_we_pad = 0; 

            // BYTE 2
            host_byte_sel_pad = 2'b10; host_data_in_pad = data[23:16];
            @(negedge clk_pad); #2; host_we_pad = 1; 
            @(negedge clk_pad); #2; host_we_pad = 0; 

            // BYTE 3 (Triggers SRAM Write)
            host_byte_sel_pad = 2'b11; host_data_in_pad = data[31:24];
            @(negedge clk_pad); #2; host_we_pad = 1; 
            @(negedge clk_pad); #2; host_we_pad = 0; 

            host_req_pad = 0; host_data_in_pad = 8'd0; host_byte_sel_pad = 2'b00;
        end
    endtask

    // Multiplexed 32-bit Read Task 
    task read_mem(input [9:0] addr);
        begin
            @(negedge clk_pad); #2;
            host_addr_pad = addr; host_we_pad = 0; host_req_pad = 1;
            
            host_byte_sel_pad = 2'b00; @(negedge clk_pad); #2; reconstructed_read[7:0]   = host_data_out_pad;
            host_byte_sel_pad = 2'b01; @(negedge clk_pad); #2; reconstructed_read[15:8]  = host_data_out_pad;
            host_byte_sel_pad = 2'b10; @(negedge clk_pad); #2; reconstructed_read[23:16] = host_data_out_pad;
            host_byte_sel_pad = 2'b11; @(negedge clk_pad); #2; reconstructed_read[31:24] = host_data_out_pad;
            
            host_req_pad = 0; @(negedge clk_pad); #2;
            $display("Host Read Addr [%d] (Lane %2d) -> Result Data: %d", addr, addr - 200, reconstructed_read);
        end
    endtask

    initial begin
        $shm_open("waves.shm");
        $shm_probe("AS", chip_top_tb);

        // 1. Initial conditions
        rst_n_pad = 0; 
        start_pad = 0;
        host_we_pad = 0; 
        host_req_pad = 0; 
        host_addr_pad = 0;
        host_data_in_pad = 8'd0; 
        host_byte_sel_pad = 0;

        // --- CRITICAL FIX 3: Synchronous, robust reset sequence ---
        // Wait 20 clock cycles for ALL standard cell UDPs to stabilize
        repeat(20) @(negedge clk_pad);
        #2; // Delay after edge
        rst_n_pad = 1; // Release reset safely
        
        // Wait 10 cycles before firing memory writes
        repeat(10) @(negedge clk_pad);

        $display("--- Loading Data Arrays ---");
        for (k = 0; k < 16; k = k + 1) begin
            write_mem(10'd100 + k, k + 1);       
            write_mem(10'd120 + k, (k + 1) * 10); 
        end

        $display("--- Loading Instructions ---");
        write_mem(10'd0, 32'h01100064); 
        write_mem(10'd1, 32'h01200078); 
        write_mem(10'd2, 32'h03312000); 
        write_mem(10'd3, 32'h020300C8); 
        write_mem(10'd4, 32'hFF000000); 
        
        // Safe Landing Zone
        write_mem(10'd5, 32'hFF000000); 
        write_mem(10'd6, 32'hFF000000); 
        write_mem(10'd7, 32'h00000000); 
        
        $display("--- Starting 16-Core GPU ---");
        @(negedge clk_pad); #2;
        start_pad = 1;

        // CRITICAL FIX 4: Strict logic match (===) so an initial 'X' doesn't instantly trigger wait()
        wait(done_pad === 1'b1); 
        
        $display("GPU Finished! Host reclaiming bus...");
        @(negedge clk_pad); #2;
        start_pad = 0; 
        
        $display("--- Reading 16-Lane Results ---");
        for (k = 0; k < 16; k = k + 1) begin
            read_mem(10'd200 + k);
        end
        
        #100 $finish;
    end
    
    initial begin
        #100000; // Timeout
        $display("CRITICAL: Simulation Timeout! Check for X propagation.");
        $finish;
    end
endmodule
