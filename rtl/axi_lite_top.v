module axi_lite_top(
    input ACLK,
    input ARESETN,

    // MASTER -> AXI SLAVE
    input [31:0]AWADDR,     // Write address
    input [31:0]WDATA,      // Write data 
    input [3:0]WSTRB,       // Write strobe

    // SIGNALS
    input AWVALID,  // master says the write address on AWADDR is valid
    input WVALID,   // master says the write data on WDATA/WSTRB is valid
    output BVALID, // slave says the write response on BRESP is valid

    output AWREADY, // slave is ready to accept the address
    output WREADY,  // Slave is ready to accept the data

    input BREADY,   //master is ready to accept the write response

    output [1:0]BRESP,  // Write response code (OKAY/SLVERR)

    input [31:0]ARADDR,     // address the master wants to read from
    input ARVALID,      // master says ARADDR is valid
    input RREADY,       // master is ready to accept the read data

    output ARREADY,     // slave is ready to accept a read address
    output RVALID,      // slave says RDATA/RRESP are valid
    output [31:0]RDATA,     // read data returned to the master
    output [1:0]RRESP,      // read response code

    output irq
);

// SLAVE -> REG_BANK
wire [31:0] intern_waddr, intern_write_data, intern_raddr;
wire [3:0] write_strobe;
wire write_en_pulse, read_en_pulse;

// REG_BANK -> SLAVE
wire [31:0] intern_read_data;
wire [1:0] werror, rerror;
wire read_data_ready;

// REG_BANK -> SYNC_FIFO
wire [31:0] din;
wire push, pop, soft_reset;

// SYNC_FIFO -> REG_BANK
wire [31:0] dout;
wire full, empty;

slave_fsm slave_fsm_inst (
    // global
    .ACLK(ACLK),
    .ARESETN(ARESETN),
    // AXI write channels
    .AWADDR(AWADDR),
    .AWVALID(AWVALID),
    .AWREADY(AWREADY),
    .WDATA(WDATA),
    .WSTRB(WSTRB),
    .WVALID(WVALID),
    .WREADY(WREADY),
    .BRESP(BRESP),
    .BVALID(BVALID),
    .BREADY(BREADY),
    // AXI read channels
    .ARADDR(ARADDR),
    .ARVALID(ARVALID),
    .ARREADY(ARREADY),
    .RDATA(RDATA),
    .RRESP(RRESP),
    .RVALID(RVALID),
    .RREADY(RREADY),
    // slave_fsm -> reg_bank
    .intern_waddr(intern_waddr),
    .intern_raddr(intern_raddr),
    .intern_write_data(intern_write_data),
    .write_strobe(write_strobe),
    .write_en_pulse(write_en_pulse),
    .read_en_pulse(read_en_pulse),
    // reg_bank -> slave_fsm
    .intern_read_data(intern_read_data),
    .read_data_ready(read_data_ready),
    .werror(werror),
    .rerror(rerror)
);

reg_bank reg_bank_inst (
    // global
    .ACLK(ACLK),
    .ARESETN(ARESETN),
    // slave_fsm -> reg_bank
    .intern_waddr(intern_waddr),
    .intern_raddr(intern_raddr),
    .intern_write_data(intern_write_data),
    .write_strobe(write_strobe),
    .write_en_pulse(write_en_pulse),
    .read_en_pulse(read_en_pulse),
    // reg_bank -> slave_fsm
    .intern_read_data(intern_read_data),
    .read_data_ready(read_data_ready),
    .werror(werror),
    .rerror(rerror),
    // reg_bank -> sync_fifo
    .push(push),
    .pop(pop),
    .din(din),
    .soft_reset(soft_reset),
    // sync_fifo -> reg_bank
    .dout(dout),
    .full(full),
    .empty(empty),
    // top-level output
    .irq(irq)
);

sync_fifo #(
    .WIDTH(32),
    .DEPTH(16)
) sync_fifo_inst (
    .clk(ACLK),
    .rst_n(ARESETN),
    .push(push),
    .pop(pop),
    .soft_reset(soft_reset),
    .din(din),
    .dout(dout),
    .full(full),
    .empty(empty)
);

endmodule