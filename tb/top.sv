`timescale 1ns / 10ps

module top();

////////////////////////////////////////////////////////////////////////////////// SIGNAL DECLARATIONS //////////////////////////////////////////////////////////////////////////////////

    // signals driven by the testbench (master side)
    logic ACLK, ARESETN;                    // clock, active-LOW async reset
    logic [31:0]AWADDR;                     // write address
    logic AWVALID;                          // write address valid
    logic [31:0]WDATA;                      // write data
    logic [3:0]WSTRB;                       // write byte strobes
    logic WVALID;                           // write data valid
    logic BREADY;                           // master ready to accept the write response
    logic [31:0]ARADDR;                     // read address
    logic ARVALID;                          // read address valid
    logic RREADY;                           // master ready to accept the read data

    // signals driven by the DUT (slave side)
    logic AWREADY;                          // slave ready for the write address
    logic WREADY;                           // slave ready for the write data
    logic BVALID;                           // write response valid
    logic [1:0]BRESP;                       // write response (OKAY / SLVERR)
    logic ARREADY;                          // slave ready for the read address
    logic RVALID;                           // read data valid
    logic [31:0]RDATA;                      // read data
    logic [1:0]RRESP;                       // read response (OKAY / SLVERR)
    logic irq;                              // interrupt output

    // register addresses and response codes
    localparam CTRL = 32'h00;               // control register
    localparam STATUS = 32'h04;             // status register (read only)
    localparam FIFO_DATA = 32'h08;          // write = push, read = pop
    localparam IRQ_EN = 32'h10;             // interrupt enable
    localparam IRQ_STATUS = 32'h14;         // interrupt status (write 1 to clear)
    localparam VERSION = 32'h18;            // version register (read only)
    localparam OKAY = 2'b00;                // normal response
    localparam SLVERR = 2'b10;              // slave error response

    integer pass_count, fail_count;         // Total pass and fails
    logic test_ok;

////////////////////////////////////////////////////////////////////////////////// CLOCK, COUNTERS, DUT //////////////////////////////////////////////////////////////////////////////////

    initial begin: clk_gen
        ACLK = 0;                           
        forever
        # 5 ACLK = ~ACLK;                   
    end: clk_gen

    initial begin: counter_reset
        pass_count = 0;                     
        fail_count = 0;
        test_ok = 1;
        $timeformat(-9, 0, " ns", 0);       // print %t in whole nanoseconds
    end:counter_reset

    axi_lite_top dut(
        .ACLK(ACLK), .ARESETN(ARESETN),
        .AWADDR(AWADDR), .AWVALID(AWVALID),
        .WDATA(WDATA), .WSTRB(WSTRB), .WVALID(WVALID),
        .BREADY(BREADY),
        .ARADDR(ARADDR), .ARVALID(ARVALID),
        .RREADY(RREADY),
        .AWREADY(AWREADY),
        .WREADY(WREADY),
        .BVALID(BVALID),
        .BRESP(BRESP),
        .ARREADY(ARREADY),
        .RVALID(RVALID),
        .RDATA(RDATA),
        .RRESP(RRESP),
        .irq(irq)
    );

////////////////////////////////////////////////////////////////////////////////// BASIC TASKS //////////////////////////////////////////////////////////////////////////////////

    // Purpose: Task where every comparison is made and counted.
    task check(input string name, input [31:0]got, input [31:0]expected);
    begin
        if(got === expected)                
        begin                  
            $display("PASS: %s", name);
        end
        else
        begin                   
            $display("FAIL: Name: %s, Received: %h, Expected: %h, Time: %0t", name, got, expected, $time);
            test_ok = 0;
        end
    end
    endtask

    task pass_fail_count(input integer id);
    begin
        if(test_ok) 
        begin
            pass_count++;
            $display("Test %0d passed", id);
        end
        else
        begin
            fail_count++;
            $display("Test %0d failed", id);
        end
        test_ok = 1;
    end
    endtask

    // Purpose: put the DUT into a known state at the start of every test.
    // Reset is asserted at any time (async) but released 1 ns after a clock edge, so the DUT sees a clean recovery time.
    task reset_dut();
    begin
        ARESETN  = 0;                       
        AWADDR = 0;                         
        AWVALID = 0;
        ARADDR = 0;
        ARVALID = 0;
        WDATA = 0;
        WSTRB = 0;
        WVALID = 0;
        BREADY = 0;
        RREADY = 0;

        @(posedge ACLK);                    // hold reset for 3 clock edges
        @(posedge ACLK);
        @(posedge ACLK);
        # 1 ARESETN = 1;                    // release just after an edge

        @(posedge ACLK);                    // let the DUT settle for 2 edges before the first transaction
        @(posedge ACLK);
    end
    endtask

////////////////////////////////////////////////////////////////////////////////// AXI TRANSACTION TASKS //////////////////////////////////////////////////////////////////////////////////

    // Purpose: one complete AXI4-Lite write (AW + W + B).
    // aw_delay / w_delay = clocks to wait before presenting AW / W, b_delay = clocks to wait before accepting the response.
    task automatic axi_write(input [31:0]addr, input [31:0]data, input [3:0]strb, input integer aw_delay, input integer w_delay, input integer b_delay, output [1:0] resp);
    begin
        fork
        begin
           // AW channel
           repeat (aw_delay) @(posedge ACLK);   
           AWADDR <= addr;                      
           AWVALID <= 1;
           @(posedge ACLK);                     // let the DUT see VALID for at least one edge
           while(AWREADY !== 1'b1) @(posedge ACLK);   // wait for the handshake 
           AWVALID <= 0;                        // handshake done, drop VALID
        end
        begin
           // W channel (runs in parallel with AW)
           repeat (w_delay) @(posedge ACLK);    
           WDATA <=data;                        // present data and strobes
           WSTRB <= strb;
           WVALID <= 1;
           @(posedge ACLK);
           while(WREADY !== 1'b1) @(posedge ACLK);    // wait for the handshake
           WVALID <= 0;
        end
        join                                    // both channels must finish before the response phase

        // B channel
        repeat (b_delay) @(posedge ACLK);       
        BREADY <= 1;
        @(posedge ACLK);
        while(BVALID !== 1'b1) @(posedge ACLK); // wait for the response
        resp = BRESP;                           // capture it 
        BREADY <= 0;
    end
    endtask

    // Purpose: one complete AXI4-Lite read (AR + R). 
    // r_delay = clocks to wait before accepting the data.
    task automatic axi_read(input [31:0]addr, input integer r_delay, output [31:0]data, output [1:0]resp);
    begin
        // AR channel
        ARADDR <= addr;                         // present the address
        ARVALID <= 1;
        @(posedge ACLK);
        while(ARREADY !== 1'b1) @(posedge ACLK);    // wait for the handshake
        ARVALID <= 0;

        // R channel
        repeat (r_delay) @(posedge ACLK);       
        RREADY <= 1;
        @(posedge ACLK);
        while(RVALID !== 1'b1) @(posedge ACLK); // wait for the data
        data = RDATA;                           // capture data and response
        resp = RRESP;
        RREADY <= 0;
    end
    endtask

////////////////////////////////////////////////////////////////////////////////// WRAPPER AND HELPER TASKS //////////////////////////////////////////////////////////////////////////////////

    // Purpose: normal write that must succeed. Checks the response is OKAY.
    task write(input [31:0]addr, input [31:0]data);
    begin
        logic [1:0]resp;
        axi_write(addr, data, 4'hF, 0, 0, 0, resp);
        check($sformatf("write to %h", addr), resp, OKAY);
    end
    endtask

    // Purpose: write that must be rejected (read-only, unmapped, misaligned, FIFO full). Checks the response is SLVERR.
    task write_error(input [31:0]addr, input [31:0]data);
    begin
        logic [1:0]resp;
        axi_write(addr, data, 4'hF, 0, 0, 0, resp);
        check($sformatf("write error %h", addr), resp, SLVERR);
    end
    endtask

    // Purpose: read that must succeed. Checks both the returned data and that the response is OKAY.
    task read_check(input [31:0]addr, input [31:0]expected);
    begin
        logic [31:0]rdata;
        logic [1:0]resp;
        axi_read(addr, 0, rdata, resp);
        check($sformatf("read data %h", addr), rdata, expected);
        check($sformatf("read response %h", addr), resp, OKAY);
    end
    endtask

    // Purpose: read that must be rejected (unmapped or misaligned). Checks the data is 0 and the response is SLVERR.
    task read_error(input [31:0]addr);
    begin
        logic [31:0]rdata;
        logic [1:0]resp;
        axi_read(addr, 0, rdata, resp);
        check($sformatf("read data error %h", addr), rdata, 0);
        check($sformatf("read response error %h", addr), resp, SLVERR);
    end
    endtask

    // Purpose: push n consecutive words into the FIFO and check that every write was accepted.
    // Used wherever a test needs the FIFO filled to a known level without repeating a loop.
    task push_n(input [31:0] base, input integer n);
    begin
        integer i, bad;
        logic [1:0] resp;
        bad = 0;                                // number of rejected pushes
        for (i = 0; i < n; i++)
        begin
            axi_write(FIFO_DATA, base + i, 4'hF, 0, 0, 0, resp);
            if (resp !== OKAY) bad++;           // any non-OKAY response is a failure
        end
        check("push_n resp", bad, 0);           // one check for the whole batch
    end
    endtask

    // Purpose: pop n words and check they come out in order.
    task pop_n(input [31:0] base, input integer n);
    begin
        integer i;
        for (i = 0; i < n; i++)
            read_check(FIFO_DATA, base + i);    // each pop must return the next expected word
    end
    endtask

////////////////////////////////////////////////////////////////////////////////// DIRECTED TESTS //////////////////////////////////////////////////////////////////////////////////

    // TEST 1: reset values.
    // Purpose: after reset, every handshake signal is idle and every register holds its documented reset value.
    // Catches a missing reset on any flop, or a wrong reset value.
    task test_1();
    begin
        $display("////////////////////////// TEST 1 //////////////////////////");
        reset_dut();

        check("AWREADY idle", AWREADY, 1);          // slave is ready to accept
        check("WREADY idle", WREADY, 1);
        check("ARREADY idle", ARREADY, 1);
        check("BVALID idle", BVALID, 0);            // nothing to respond to yet
        check("RVALID idle", RVALID, 0);

        read_check(CTRL, 0);
        read_check(STATUS, 1);                      // FIFO empty
        read_check(IRQ_EN, 0);
        read_check(IRQ_STATUS, 0);
        read_check(VERSION, 32'h0001_0000);

        check("irq idle", irq, 0);
    end
    endtask

    // TEST 2: read/write of the writable registers and unused bits.
    // Purpose: CTRL keeps only the bits it implements and SOFT_RESET (bit 1) reads back 0. IRQ_EN keeps only its 3 bits.
    // Catches wrong bit masks and a command bit that is stored instead of acting as a pulse.
    task test_2();
    begin
        $display("////////////////////////// TEST 2 //////////////////////////");
        reset_dut();

        write(CTRL, 32'hF);
        read_check(CTRL, 32'hD);                    // bit 1 is a command, reads 0
        write(IRQ_EN, 32'hFFFF_FFFF);
        read_check(IRQ_EN, 32'h7);                  // only 3 bits exist
    end
    endtask

    // TEST 3: writes to read-only registers.
    // Purpose: STATUS and VERSION must answer SLVERR and must not change.
    // Catches a read-only register that can be overwritten, or an error response that is missing.
    task test_3();
    begin
        $display("////////////////////////// TEST 3 //////////////////////////");
        reset_dut();

        write_error(STATUS, 32'hFFFF_FFFF);
        write_error(VERSION, 32'h1234_5678);
        read_check(STATUS, 1);                      // unchanged
        read_check(VERSION, 32'h0001_0000);
    end
    endtask

    // TEST 4: bad addresses.
    // Purpose: unmapped (0x0C), misaligned (0x01) and out-of-window (0x20, 0x100) addresses give SLVERR on both read and write and do not disturb any real register.     
    task test_4();
    begin
        $display("////////////////////////// TEST 4 //////////////////////////");
        reset_dut();

        write_error(32'h0C, 32'hDEAD_BEEF);
        write_error(32'h01, 32'hDEAD_BEEF);
        write_error(32'h20, 32'hDEAD_BEEF);
        write_error(32'h100, 32'hDEAD_BEEF);
        read_error(32'h0C);
        read_error(32'h01);
        read_error(32'h20);
        read_error(32'h100);
        read_check(CTRL, 0);                        // nothing leaked into real registers
        read_check(IRQ_EN, 0);
    end
    endtask

    // TEST 5: write strobes on CTRL.
    // Purpose: only the byte lanes with WSTRB set may be written. Strobe 0 writes nothing.
    task test_5();
    begin
        logic [1:0]resp;
        $display("////////////////////////// TEST 5 //////////////////////////");
        reset_dut();

        axi_write(CTRL, 32'hF, 4'b0000, 0, 0, 0, resp);
        check("strobe 0 resp", resp, OKAY);         // still a valid transaction
        read_check(CTRL, 0);                        // but nothing written

        axi_write(CTRL, 32'h5, 4'b0001, 0, 0, 0, resp);
        check("strobe 0001 resp", resp, OKAY);
        read_check(CTRL, 32'h5);                    // byte 0 written

        axi_write(CTRL, 32'hF, 4'b1110, 0, 0, 0, resp);
        check("strobe 1110 resp", resp, OKAY);
        read_check(CTRL, 32'h5);                    // byte 0 not strobed, so unchanged
    end
    endtask

    // TEST 6: write strobes on FIFO_DATA.
    // Purpose: the FIFO word is assembled byte by byte, strobe 0101 writes bytes 0 and 2 only, the others are zero.
    task test_6();
    begin
        logic [1:0]resp;
        $display("////////////////////////// TEST 6 //////////////////////////");
        reset_dut();

        axi_write(FIFO_DATA, 32'hFFFF_FFFF, 4'b0101, 0, 0, 0, resp);
        check("fifo strobe resp", resp, OKAY);
        read_check(FIFO_DATA, 32'h00FF_00FF);       // only bytes 0 and 2 came through

        read_check(STATUS, 1);                      // FIFO empty again
    end
    endtask

    // TEST 7: AW and W arrive in different orders.
    // Purpose: AXI allows address first, data first, or both together. The slave must complete the write in every case.
    task test_7();
    begin
        logic [1:0]resp;
        $display("////////////////////////// TEST 7 //////////////////////////");
        reset_dut();

        axi_write(IRQ_EN, 32'h1, 4'hF, 0, 5, 0, resp);      // address first, data 5 clocks later
        check("order N resp", resp, OKAY);
        read_check(IRQ_EN, 1);

        axi_write(IRQ_EN, 32'h2, 4'hF, 7, 0, 0, resp);      // data first, address 7 clocks later
        check("order N resp", resp, OKAY);
        read_check(IRQ_EN, 2);

        axi_write(IRQ_EN, 32'h4, 4'hF, 0, 0, 0, resp);      // both together
        check("order N resp", resp, OKAY);
        read_check(IRQ_EN, 4);

        axi_write(IRQ_EN, 32'h5, 4'hF, 3, 3, 0, resp);      // both late, same time
        check("order N resp", resp, OKAY);
        read_check(IRQ_EN, 5);
    end
    endtask

    // TEST 8: back-pressure and stall.
    // Purpose: if the master delays BREADY / RREADY, the slave must hold BVALID / RVALID and the response / data stable,
    // and must not accept a new write while the response is pending (AWREADY, WREADY low in WRITE_RESP).
    task test_8();
    begin
        logic [1:0] resp, resp2, first_resp;
        logic [31:0] rdata, first_data;
        $display("////////////////////////// TEST 8 //////////////////////////");
        reset_dut();
        fork
        begin
            axi_write(IRQ_EN, 32'h3, 4'hF, 0, 0, 8, resp);          // master waits 8 clocks before BREADY
        end

        begin
            wait(BVALID === 1'b1);                                  // monitor: response is now pending
            @(posedge ACLK);
            first_resp = BRESP;                                     
            repeat (3) @(posedge ACLK);
            check("BVALID held", BVALID, 1);                        // still waiting, must not have dropped
            check("BRESP stable", BRESP, first_resp);               // and must not have changed
            check("AWREADY low in RESP", AWREADY, 0);               // slave is busy with the response
            check("WREADY low in RESP", WREADY, 0);
            axi_write(CTRL, 32'h5, 4'hF, 0, 0, 0, resp2);           // second write, must wait until the first one finishes
        end
        join

        check("bp write resp", resp, OKAY);
        check("stall write resp", resp2, OKAY);
        read_check(IRQ_EN, 3);                                      // both writes landed
        read_check(CTRL, 32'h5);

        @(posedge ACLK);
        fork
        begin
            axi_read(VERSION, 8, rdata, resp);                      // master waits 8 clocks before RREADY
        end

        begin
            wait (RVALID === 1'b1);                                 // monitor: data is now pending
            @(posedge ACLK);
            first_data = RDATA;
            repeat (3) @(posedge ACLK);
            check("RVALID held", RVALID, 1);
            check("RDATA stable", RDATA, first_data);
        end
        join

        check("bp read data", rdata, 32'h0001_0000);
        check("bp read resp", resp, OKAY);
    end
    endtask

    // TEST 9: back-to-back transactions.
    // Purpose: many accesses in a row with no idle gap and mixed registers, the FSMs must return to idle cleanly every time.
    task test_9();
    begin
        $display("////////////////////////// TEST 9 //////////////////////////");
        reset_dut();

        write(CTRL, 32'h5);
        write(IRQ_EN, 32'h3);
        write(CTRL, 32'h9);                         // overwrite, last value must win
        write(IRQ_EN, 32'h6);

        read_check(CTRL, 32'h9);
        read_check(STATUS, 1);
        read_check(IRQ_EN, 32'h6);
        read_check(VERSION, 32'h0001_0000);

        write(FIFO_DATA, 32'h11);
        write(FIFO_DATA, 32'h22);
        write(FIFO_DATA, 32'h33);

        read_check(FIFO_DATA, 32'h11);              // first in, first out
        read_check(FIFO_DATA, 32'h22);
        read_check(FIFO_DATA, 32'h33);

        read_check(STATUS, 1);                      // empty again
    end
    endtask

    // TEST 10: fill the FIFO, overflow it, drain it.
    // Purpose: FULL must assert exactly after 16 pushes, a 17th push is rejected with SLVERR and sets ERROR,
    // the 16 stored words come out in order, and the IRQ_STATUS events (full, error, empty) are recorded.
    task test_10();
    begin
        integer count, i;
        logic [31:0] rdata;
        logic [1:0] resp;

        $display("////////////////////////// TEST 10 //////////////////////////");
        reset_dut();

        count = 0;
        rdata = 0;
        while (rdata[1] !== 1'b1 && count < 40)     // push until STATUS.FULL
        begin
            axi_write(FIFO_DATA, 32'h100 + count, 4'hF, 0, 0, 0, resp);
            count++;
            axi_read(STATUS, 0, rdata, resp);
        end

        check("pushes until full", count, 16);      // depth is exactly 16
        read_check(STATUS, 32'h2);                  // full, no error yet
        read_check(IRQ_STATUS, 32'h1);              // full event
        write_error(FIFO_DATA, 32'hBAD0_BAD0);      // overflow
        read_check(STATUS, 32'h12);                 // full + sticky error
        read_check(IRQ_STATUS, 32'h5);              // full + error events

        for (i = 0; i < 16; i++)
            read_check(FIFO_DATA, 32'h100 + i);     // overflow word must not have overwritten anything

        read_check(STATUS, 32'h11);                 // empty + error still set
        read_check(IRQ_STATUS, 32'h7);              // full + empty + error events
    end
    endtask

    // TEST 11: read from an empty FIFO.
    // Purpose: an empty read returns the last value read, answers OKAY, and sets the sticky ERROR bit and IRQ error event.
    task test_11();
    begin
        $display("////////////////////////// TEST 11 //////////////////////////");
        reset_dut();

        read_check(STATUS, 32'h1);
        read_check(FIFO_DATA, 0);                   // empty read, nothing read before so 0
        read_check(STATUS, 32'h11);                 // error is now set
        read_check(IRQ_STATUS, 32'h4);
        write(FIFO_DATA, 32'hCAFE_0001);
        read_check(STATUS, 32'h10);                 // not empty, error still sticky
        read_check(FIFO_DATA, 32'hCAFE_0001);
        read_check(STATUS, 32'h11);
        read_check(FIFO_DATA, 32'hCAFE_0001);       // empty again, returns the last value read
        write(FIFO_DATA, 32'hCAFE_0002);
        read_check(FIFO_DATA, 32'hCAFE_0002);
        read_check(STATUS, 32'h11);
        read_check(IRQ_STATUS, 32'h6);              // error + empty events
    end
    endtask

    // TEST 12: pointer wraparound.
    // Purpose: push/pop patterns that move the read and write pointers past slot 15 several times, in every combination
    // of empty, partly full and full. 
    task test_12();
    begin
        $display("////////////////////////// TEST 12 //////////////////////////");
        reset_dut();

        push_n(32'hA00, 10);
        pop_n(32'hA00, 10);                         // pointers now at slot 10
        read_check(STATUS, 32'h1);

        push_n(32'hB00, 16);                        // write pointer wraps, FIFO full
        read_check(STATUS, 32'h2);

        pop_n(32'hB00, 16);                         // read pointer wraps, FIFO empty
        read_check(STATUS, 32'h1);

        push_n(32'hC00, 5);
        pop_n(32'hC00, 3);                          // 2 words left
        read_check(STATUS, 32'h0);                  // partly full

        push_n(32'hD00, 14);                        // 2 + 14 = 16, full again with the pointers mid-array
        read_check(STATUS, 32'h2);

        pop_n(32'hC03, 2);                          // old words first
        pop_n(32'hD00, 14);                         // then the new ones
        read_check(STATUS, 32'h1);

    end
    endtask

    // TEST 13: interrupt masking and write-1-to-clear.
    // Purpose: irq = |(IRQ_STATUS & IRQ_EN). A pending event must not raise irq unless enabled, and writing 1 to an
    // IRQ_STATUS bit clears only that bit.
    task test_13();
    begin
        $display("////////////////////////// TEST 13 //////////////////////////");
        reset_dut();

        push_n(32'h100, 16);                        // full event
        write_error(FIFO_DATA, 32'hBAD0_BAD0);      // error event
        read_check(IRQ_STATUS, 32'h5);

        check("irq masked", irq, 0);                // events pending but nothing enabled

        write(IRQ_EN, 32'h1);
        check("irq bit0 en", irq, 1);               // full event enabled

        write(IRQ_EN, 32'h2);
        check("irq bit1 not pending", irq, 0);      // empty event enabled but not pending

        write(IRQ_EN, 32'h4);
        check("irq bit2 en", irq, 1);               // error event enabled

        write(IRQ_EN, 32'h5);

        write(IRQ_STATUS, 32'h1);                   // clear the full event only
        read_check(IRQ_STATUS, 32'h4);
        check("irq still high", irq, 1);            // error event keeps irq high

        write(IRQ_STATUS, 32'h4);                   // clear the error event
        read_check(IRQ_STATUS, 0);
        check("irq low", irq, 0);

        read_check(STATUS, 32'h12);                 // clearing the event must not clear the STATUS flags
    end
    endtask

    // TEST 14: concurrent read and write.
    // Purpose: the read and write FSMs are independent, so a read and a write started in the same clock must both complete
    // correctly. Part A uses different registers, part B pushes and pops the FIFO at the same moment, part C does the same
    // on an empty FIFO. 
    task test_14();
    begin
        logic [1:0] wresp, rresp;
        logic [31:0] rdata;
        $display("////////////////////////// TEST 14 //////////////////////////");
        reset_dut();

        // part A: different registers
        fork
        begin
            axi_write(IRQ_EN, 32'h5, 4'hF, 0, 0, 0, wresp);
        end

        begin
            axi_read(VERSION, 0, rdata, rresp);
        end
        join

        check("conc write resp", wresp, OKAY);
        check("conc read data", rdata, 32'h0001_0000);
        check("conc read resp", rresp, OKAY);

        fork
        begin
            axi_write(CTRL, 32'h9, 4'hF, 2, 2, 0, wresp);       // write starts 2 clocks later than the read
        end

        begin
            axi_read(IRQ_EN, 0, rdata, rresp);                  // read sees the value written just before
        end
        join

        check("conc2 read data", rdata, 32'h5);
        check("conc2 write resp", wresp, OKAY);
        read_check(CTRL, 32'h9);

        // part B: simultaneous push and pop, FIFO has data
        push_n(32'h100, 4);

        fork
        begin
            axi_write(FIFO_DATA, 32'h200, 4'hF, 0, 0, 0, wresp);    // push
        end

        begin
            axi_read(FIFO_DATA, 0, rdata, rresp);                   // pop
        end
        join

        check("pp write resp", wresp, OKAY);
        check("pp read data", rdata, 32'h100);                      // oldest word
        check("pp read resp", rresp, OKAY);

        read_check(STATUS, 32'h0);                                  // 4 - 1 + 1 = 4 words, partly full
        pop_n(32'h101, 3);
        pop_n(32'h200, 1);                                          // the simultaneous push was kept, at the back
        read_check(STATUS, 32'h1);

        // part C: simultaneous push and pop, FIFO empty
        fork
        begin
            axi_write(FIFO_DATA, 32'h300, 4'hF, 0, 0, 0, wresp);    // push
        end

        begin
            axi_read(FIFO_DATA, 0, rdata, rresp);                   // pop on empty
        end
        join

        check("empty pp read data", rdata, 32'h200);                // empty read returns the last value read
        check("empty pp read resp", rresp, OKAY);
        check("empty pp write resp", wresp, OKAY);

        read_check(STATUS, 32'h10);                                 // the push was kept (not empty), the empty read set ERROR
        read_check(FIFO_DATA, 32'h300);
    end
    endtask

    // TEST 15: reset in the middle of a transaction.
    // Purpose: after a reset that interrupts a half-finished write and a half-finished read, the slave returns to a clean
    // idle: READY signals high, VALID signals low, registers and FIFO at reset values, and nothing from the abandoned
    // transactions survives.
    task test_15();
    begin
        $display("////////////////////////// TEST 15 //////////////////////////");
        reset_dut();

        // part A: write interrupted after AW, W never sent
        write(IRQ_EN, 32'h7);                       // put the DUT in a non-reset state
        write(CTRL, 32'h5);
        push_n(32'h100, 3);

        AWADDR <= CTRL; AWVALID <= 1;               // AW handshake
        @(posedge ACLK);                            // let the DUT see VALID
        while (AWREADY !== 1'b1) @(posedge ACLK);   // wait for the handshake
        AWVALID <= 0;
        repeat (2) @(posedge ACLK);

        check("AWREADY low mid-write", AWREADY, 0); // proves that dut is in the middle of a write

        reset_dut();                                // reset hits the half-finished write

        check("AWREADY after reset", AWREADY, 1);
        check("WREADY after reset", WREADY, 1);
        check("BVALID after reset", BVALID, 0);

        read_check(CTRL, 0);                        // everything back to reset values
        read_check(IRQ_EN, 0);
        read_check(STATUS, 1);                      // FIFO emptied

        write(IRQ_EN, 32'h3);                       // a fresh write works normally
        read_check(IRQ_EN, 3);
        read_check(CTRL, 0);                        // the abandoned write to CTRL never committed

        // part B: read interrupted while the response is pending
        ARADDR <= VERSION;                          // AR handshake, RREADY stays 0
        ARVALID <= 1;
        @(posedge ACLK);                            // let the DUT see VALID
        while(ARREADY !== 1'b1) @(posedge ACLK);    // wait for the handshake
        ARVALID <= 0;
        wait (RVALID === 1'b1);                     // data is waiting for the master
        check("RVALID pending", RVALID, 1);

        reset_dut();                                // reset hits the pending read

        check("RVALID after reset", RVALID, 0);
        check("ARREADY after reset", ARREADY, 1);

        read_check(CTRL, 0);                        // would return VERSION if the old read had survived

        read_check(VERSION, 32'h0001_0000);
    end
    endtask

    // TEST 16: soft reset.
    // Purpose: writing CTRL.SOFT_RESET clears the FIFO (pointers) and the sticky ERROR bit, reads back as 0, and does NOT clear IRQ_STATUS. 
    task test_16();
    begin
        $display("////////////////////////// TEST 16 //////////////////////////");
        reset_dut();

        read_check(FIFO_DATA, 0);                   // empty read to set the ERROR bit
        read_check(STATUS, 32'h11);

        push_n(32'h500, 5);                         // put data in the FIFO
        read_check(STATUS, 32'h10);                 // not empty, error set

        write(CTRL, 32'h2);                         // SOFT_RESET command
        repeat (3) @(posedge ACLK);                 // the reset pulse is registered

        read_check(STATUS, 32'h1);                  // empty and error cleared
        read_check(CTRL, 0);                        // command bit reads 0
        read_check(IRQ_STATUS, 32'h6);              // error event kept, empty event added by the FIFO clear

        write(FIFO_DATA, 32'h600);                  // FIFO works from a clean state
        read_check(FIFO_DATA, 32'h600);             // old data (0x500) must be gone
        read_check(STATUS, 32'h1);
    end
    endtask

////////////////////////////////////////////////////////////////////////////////// TEST SEQUENCE AND WATCHDOG //////////////////////////////////////////////////////////////////////////////////

    initial begin:tests
        test_1();
        pass_fail_count(1);
        test_2();
        pass_fail_count(2);
        test_3();
        pass_fail_count(3);
        test_4();
        pass_fail_count(4);
        test_5();
        pass_fail_count(5);
        test_6();
        pass_fail_count(6);
        test_7();
        pass_fail_count(7);
        test_8();
        pass_fail_count(8);
        test_9();
        pass_fail_count(9);
        test_10();
        pass_fail_count(10);
        test_11();
        pass_fail_count(11);
        test_12();
        pass_fail_count(12);
        test_13();
        pass_fail_count(13);
        test_14();
        pass_fail_count(14);
        test_15();
        pass_fail_count(15);
        test_16();
        pass_fail_count(16);
        $display("TESTS PASSED : %0d, TESTS FAILED : %0d", pass_count, fail_count);
        $finish;
    end:tests


    initial begin:watch_dog
        #1000000;                                   // 1 ms: if the tests are not done, something hung
        $display("TIMEOUT: simulation hung");
        $finish;
    end:watch_dog


endmodule