module slave_fsm(
    // Global clock and active-LOW asynchronous reset
    input ACLK,
    input ARESETN,

    // MASTER -> AXI SLAVE
    input [31:0]AWADDR,     // Write address
    input [31:0]WDATA,      // Write data 
    input [3:0]WSTRB,       // Write strobe

    // FSM -> REGBANK
    output reg [31:0]intern_waddr,     // Registered copy of AWADDR
    output reg [31:0]intern_write_data, // Registered copy of WDATA
    output reg [3:0]write_strobe,   // Registered copy of WSTRB

    // asserted HIGH for exactly ONE ACLK cycle (the cycle the transaction commits)
    output wire write_en_pulse,
    output wire read_en_pulse,

    // REGBANK -> FSM
    input [31:0]intern_read_data, // Value read from the register selected by intern_raddr
    input [1:0]rerror, werror, // Response code from reg_bank: 2'b00 = OKAY, 2'b10 = SLVERR

    // SIGNALS
    input AWVALID,  // master says the write address on AWADDR is valid
    input WVALID,   // master says the write data on WDATA/WSTRB is valid
    output reg BVALID, // slave says the write response on BRESP is valid

    output reg AWREADY, // slave is ready to accept the address
    output reg WREADY,  // Slave is ready to accept the data

    input BREADY,   //master is ready to accept the write response

    output reg [1:0]BRESP,  // Write response code (OKAY/SLVERR)

    output reg[31:0]intern_raddr,   // Registered copy of ARADDR

    input [31:0]ARADDR,     // address the master wants to read from
    input ARVALID,      // master says ARADDR is valid
    input RREADY,       // master is ready to accept the read data

    output reg ARREADY,     // slave is ready to accept a read address
    output reg RVALID,      // slave says RDATA/RRESP are valid
    output reg [31:0]RDATA,     // registered read data returned to the master
    output reg [1:0]RRESP,      // registered read response code

    input read_data_ready        // One-cycle pulse from reg_bank: intern_read_data and rerror are valid now
);

// aw_done: write address already accepted for the current write
// w_done : write data already accepted for the current write
reg aw_done, w_done;

// ar_done        : read address already accepted for the current read
// read_data_valid: read data has been captured from reg_bank and is waiting for the master (RREADY)
reg ar_done, read_data_valid;

//   WRITE_IDLE: accept AW and W (in any order), commit when both are done
//   WRITE_RESP: present the write response (BVALID) until BREADY
localparam [1:0] WRITE_IDLE = 2'd0;
localparam [1:0] WRITE_RESP = 2'd1;
reg [1:0] write_current, write_next;

// Read FSM states.
//   READ_IDLE: accept the read address (AR); go to READ_DATA when ar_done
//   READ_DATA: wait for reg_bank data, then present RVALID until RREADY
localparam [1:0] READ_IDLE = 2'd0;
localparam [1:0] READ_DATA = 2'd1;
reg [1:0] read_current, read_next;

always @(posedge ACLK or negedge ARESETN)
begin
    if (!ARESETN)
    begin
        write_current <= WRITE_IDLE;
        aw_done <= 1'b0;
        w_done <= 1'b0;
        intern_waddr <= 32'b0;
        intern_write_data <= 32'b0;
        write_strobe <= 4'b0;
        BRESP <= 2'b0;
        read_current <= READ_IDLE;
        ar_done <= 1'b0;
        read_data_valid <= 1'b0;
        RDATA <= 32'b0;
        RRESP <= 2'b0;
        intern_raddr <= 32'b0;
    end
    else
    begin
//////////////////////////////////////////////////////////////////////// WRITE SEQ ////////////////////////////////////////////////////////////////////////
        
        // State register: move to the next state chosen by the write FSM
        write_current <= write_next;
        // aw_done / w_done: clear when the write response handshake finishes
        // (BVALID && BREADY in WRITE_RESP). CLEAR HAS PRIORITY over set
        // Otherwise SET on the handshake (VALID && READY) or HOLD the value
        if(write_current == WRITE_RESP && BVALID && BREADY)
        begin
            aw_done <= 1'b0;
            w_done <= 1'b0;
        end
        else
        begin
            aw_done <= (AWVALID && AWREADY) ? 1'b1 : aw_done;
            w_done <= (WVALID && WREADY) ? 1'b1 : w_done;
        end

        // Capture the write address on the AW handshake (the only cycle the master guarantees AWADDR is valid)
        if(AWVALID && AWREADY) intern_waddr <= AWADDR;

        // Capture write data and strobe together on the W handshake so they always stay paired
        if(WVALID && WREADY)
        begin
            intern_write_data <= WDATA;
            write_strobe <= WSTRB;
        end

        // Capture the response code on the write_en_pulse cycle
        if(write_en_pulse) BRESP <= werror;

//////////////////////////////////////////////////////////////////////// READ SEQ ////////////////////////////////////////////////////////////////////////
        
        // State register: move to the next state chosen by the read FSM
        read_current <= read_next;
        // ar_done: clear when the R handshake finishes (RVALID && RREADY in READ_DATA); clear has priority
        // Otherwise SET on the AR handshake
        // (ARVALID && ARREADY) or HOLD
        if(read_current == READ_DATA && RVALID && RREADY)  ar_done <= 1'b0;
        else      ar_done <= (ARVALID && ARREADY) ? 1'b1 : ar_done;

        // Capture the read address on the AR handshake
        if(ARVALID && ARREADY) intern_raddr <= ARADDR;

        // read_data_valid: CLEAR when the master takes the data (RVALID && RREADY)
        // Otherwise SET when reg_bank pulses read_data_ready, or HOLD
        if(RVALID && RREADY)   read_data_valid <= 1'b0;
        else read_data_valid <= read_data_ready ? 1'b1 : read_data_valid;

        // Capture the read data and response from reg_bank on read_data_ready, so RDATA/RRESP stay stable while RVALID waits for RREADY
        if(read_data_ready)
        begin
            RDATA <= intern_read_data;
            RRESP <= rerror;
        end
    end
end

//////////////////////////////////////////////////////////////////////// WRITE FSM ////////////////////////////////////////////////////////////////////////

always @(*)
begin
    BVALID = 1'b0;               
    AWREADY = 1'b0;             
    WREADY = 1'b0;              
    write_next = write_current; 
    case(write_current)
        // Accept AW and W independently: each READY is high until its half has been captured (flag set). Move on once BOTH halves are done
        WRITE_IDLE: begin
                        AWREADY = !aw_done;
                        WREADY = !w_done;
                        if(aw_done && w_done) write_next = WRITE_RESP;
                        else write_next = WRITE_IDLE;
                    end

        // Offer the response; hold BVALID until the master asserts BREADY
        WRITE_RESP: begin
                        BVALID = 1'b1;
                        if(BVALID && BREADY) write_next = WRITE_IDLE;
                        else write_next = WRITE_RESP;
                    end
    endcase
end

//////////////////////////////////////////////////////////////////////// READ FSM ////////////////////////////////////////////////////////////////////////

always @(*)
begin
    RVALID = 1'b0;              
    ARREADY = 1'b0;             
    read_next = read_current;   
    case(read_current)
        // Accept the read address (ARREADY high until captured). Once the address is held (ar_done), read_en_pulse fires and we move on
        READ_IDLE: begin
                        ARREADY = !ar_done;
                        if(ar_done) read_next = READ_DATA;
                        else read_next = READ_IDLE;
                    end

        // Wait for reg_bank's data. RVALID follows the held flag, so it stays low until data is captured, then high until RREADY completes the handshake
        READ_DATA: begin
                        RVALID = read_data_valid;
                        if(RVALID && RREADY) read_next = READ_IDLE;
                        else read_next = READ_DATA;
                    end
    endcase
end

assign write_en_pulse = (write_current == WRITE_IDLE) && aw_done && w_done; // write_en_pulse: high for exactly one cycle, in the last WRITE_IDLE cycle when (aw_done && w_done)
assign read_en_pulse = (read_current == READ_IDLE) && ar_done; // read_en_pulse: high for exactly one cycle, in the last READ_IDLE cycle when (ar_done)

endmodule