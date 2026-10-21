module reg_bank(
    // Global clock and active-LOW asynchronous reset
    input ACLK,                         // system clock
    input ARESETN,                      // active-LOW async reset

    // SLAVE_FSM -> REG_BANK
    input [31:0] intern_waddr,          // write address captured by slave_fsm
    input [31:0] intern_raddr,          // read address captured by slave_fsm
    input read_en_pulse,                // one-cycle pulse: the read commits in this cycle
    input [31:0] intern_write_data,     // write data captured by slave_fsm
    input [3:0] write_strobe,           // byte-lane enables for the write data (bit i = byte i)
    input write_en_pulse,               // one-cycle pulse: the write commits in this cycle

    // REG_BANK -> SLAVE_FSM
    output reg [1:0] werror,            // write response code, 2'b10 = SLVERR, 2'b00 = OKAY
    output reg [31:0] intern_read_data, // data returned for the read address
    output reg read_data_ready,         // tells slave_fsm the read data is valid this cycle
    output reg [1:0] rerror,            // read response code, 2'b10 = SLVERR, 2'b00 = OKAY

    // REG_BANK -> FIFO
    input [31:0] dout,                  // FIFO word recieved
    input full,                         // FIFO is full
    input empty,                        // FIFO is empty
    output reg push,                    // write one word into the FIFO
    output reg [31:0] din,              // word to be pushed (masked by byte strobes)
    output reg soft_reset,              // one-cycle pulse that clears the FIFO
    output reg pop,                     // remove the oldest word from the FIFO

    // OUTPUT FROM REG_BANK
    output reg irq                      // interrupt: any enabled IRQ_STATUS bit is set
);

////////////////////////////////////////////////////////////////////////////////// SIGNAL DECLARATIONS //////////////////////////////////////////////////////////////////////////////////

// write-side decode signals
wire w_hi_zero, w_lo_zero, w_in_window, w_sel_ctrl, w_sel_status, w_sel_fifo, w_sel_irqen, w_sel_irqstat, w_sel_ver, w_unmapped; // hi/lo address checks, window check, one select per register, and the "no register" flag
wire [31:0]wmask;                                                   // write_strobe expanded to one bit per data bit
wire widx0, widx1, widx2, widx4, widx5, widx6;                      // intern_waddr[4:2] matches register slot 0,1,2,4,5,6

// read-side decode signals
wire r_hi_zero, r_lo_zero, r_in_window, r_sel_ctrl, r_sel_status, r_sel_fifo, r_sel_irqen, r_sel_irqstat, r_sel_ver, r_unmapped; // same set as the write side, for intern_raddr
wire ridx0, ridx1, ridx2, ridx4, ridx5, ridx6;                      // intern_raddr[4:2] matches register slot 0,1,2,4,5,6

// CTRL register
reg ctrl_we, softreset_detect, irqen_we;    // CTRL write enable, soft reset bit written flag, IRQ_EN write enable
reg ctrl_enable;                            // CTRL bit 0 storage (ENABLE)
reg [1:0]ctrl_mode;                         // CTRL bits [3:2] storage (MODE)
reg [2:0]irq_en;                            // IRQ_EN storage, one enable bit per interrupt source

// IRQ_STATUS write side
reg irqst_we, fifo_full_wr;                 // IRQ_STATUS write enable, "write to FIFO_DATA while full" flag
reg [2:0] clear;                            // per-bit write-1-to-clear request for IRQ_STATUS

// event detection
reg ev_full, ev_empty, ev_err_w, ev_err_r, ev_err;  // FIFO became full, FIFO became empty, write-on-full error, read-on-empty error, either error
reg full_prev, empty_prev;                  // last cycle's full/empty, used to detect transitions

// sticky error
reg err_set, err_sticky_detect;             // "error happened or was already set", next value of the sticky bit after soft reset
reg err_sticky;                             // STATUS.ERROR storage

// IRQ_STATUS
reg [2:0] keep, irqst_detect, irq_pend, irq_status; // bits that survive a clear, next IRQ_STATUS value, enabled-and-set bits, IRQ_STATUS storage

// read words and read mux
reg [31:0] ctrl_word, status_word, irqen_word, irqst_word, fifo_word, version_word; // 32-bit value each register returns on a read
reg [31:0] t_ctrl, t_status, t_fifo, t_irqen, t_irqst, t_ver;                       // each read word after gating with its select
reg [31:0] last_read;                       // last word popped from the FIFO, returned when reading an empty FIFO

////////////////////////////////////////////////////////////////////////////////// WRITE ADDRESS DECODE //////////////////////////////////////////////////////////////////////////////////

assign w_hi_zero = !(|intern_waddr[31:5]);          // 1 when address bits [31:5] are all 0 (inside the 32-byte window)
assign w_lo_zero = !(|intern_waddr[1:0]);           // 1 when the address is word aligned
assign w_in_window = w_hi_zero & w_lo_zero;         // address is aligned and inside the register window

// decoding address to check what type of address it is
assign widx0 = (intern_waddr[4:2] == 3'd0);         // slot 0 = offset 0x00
assign widx1 = (intern_waddr[4:2] == 3'd1);         // slot 1 = offset 0x04
assign widx2 = (intern_waddr[4:2] == 3'd2);         // slot 2 = offset 0x08
assign widx4 = (intern_waddr[4:2] == 3'd4);         // slot 4 = offset 0x10
assign widx5 = (intern_waddr[4:2] == 3'd5);         // slot 5 = offset 0x14
assign widx6 = (intern_waddr[4:2] == 3'd6);         // slot 6 = offset 0x18

assign w_sel_ctrl = w_in_window & widx0;            // write targets CTRL
assign w_sel_status = w_in_window & widx1;          // write targets STATUS (read-only)
assign w_sel_fifo = w_in_window & widx2;            // write targets FIFO_DATA
assign w_sel_irqen = w_in_window & widx4;           // write targets IRQ_EN
assign w_sel_irqstat =  w_in_window & widx5;        // write targets IRQ_STATUS
assign w_sel_ver = w_in_window & widx6;             // write targets VERSION (read-only)

assign w_unmapped = !(w_sel_ctrl | w_sel_status | w_sel_fifo | w_sel_irqen | w_sel_irqstat | w_sel_ver); // no register selected: gap, misaligned or out of window

assign wmask[7:0] = {8{write_strobe[0]}};           // byte 0 mask: all ones if strobe[0] is set
assign wmask[15:8] = {8{write_strobe[1]}};          // byte 1 mask
assign wmask[23:16] = {8{write_strobe[2]}};         // byte 2 mask
assign wmask[31:24] = {8{write_strobe[3]}};         // byte 3 mask

////////////////////////////////////////////////////////////////////////////////// READ ADDRESS DECODE //////////////////////////////////////////////////////////////////////////////////

assign r_hi_zero = !(|intern_raddr[31:5]);          // 1 when address bits [31:5] are all 0 (inside the 32-byte window)
assign r_lo_zero = !(|intern_raddr[1:0]);           // 1 when the address is word aligned
assign r_in_window = r_hi_zero & r_lo_zero;         // address is aligned and inside the register window

// decoding address to check what type of address it is
assign ridx0 = (intern_raddr[4:2] == 3'd0);         // slot 0 = offset 0x00
assign ridx1 = (intern_raddr[4:2] == 3'd1);         // slot 1 = offset 0x04
assign ridx2 = (intern_raddr[4:2] == 3'd2);         // slot 2 = offset 0x08
assign ridx4 = (intern_raddr[4:2] == 3'd4);         // slot 4 = offset 0x10
assign ridx5 = (intern_raddr[4:2] == 3'd5);         // slot 5 = offset 0x14
assign ridx6 = (intern_raddr[4:2] == 3'd6);         // slot 6 = offset 0x18

assign r_sel_ctrl = r_in_window & ridx0;            // read targets CTRL
assign r_sel_status = r_in_window & ridx1;          // read targets STATUS
assign r_sel_fifo = r_in_window & ridx2;            // read targets FIFO_DATA
assign r_sel_irqen = r_in_window & ridx4;           // read targets IRQ_EN
assign r_sel_irqstat =  r_in_window & ridx5;        // read targets IRQ_STATUS
assign r_sel_ver =r_in_window & ridx6;              // read targets VERSION

assign r_unmapped = !(r_sel_ctrl | r_sel_status | r_sel_fifo | r_sel_irqen | r_sel_irqstat | r_sel_ver); // no register selected: gap, misaligned or out of window

integer i,j,k;

always @(*)
begin
////////////////////////////////////////////////////////////////////////////////// WRITE PATH //////////////////////////////////////////////////////////////////////////////////

    // CTRL / IRQ_EN / IRQ_STATUS write enables
    ctrl_we = w_sel_ctrl & write_en_pulse & write_strobe[0];    // CTRL is written: right address, write commits, byte lane 0 enabled
    softreset_detect = ctrl_we & intern_write_data[1];          // the SOFT_RESET bit (bit 1) was written as 1
    irqen_we = w_sel_irqen & write_en_pulse & write_strobe[0];  // IRQ_EN is written (bits live in byte lane 0)

    irqst_we = w_sel_irqstat & write_en_pulse & write_strobe[0];    // IRQ_STATUS is written (write-1-to-clear)
    for (i = 0; i < 3; i = i + 1)
    begin
        clear[i] = irqst_we & intern_write_data[i];             // clear bit i only if it is written as 1
    end

    // FIFO write and write response
    push = w_sel_fifo & write_en_pulse & !full;                 // push only on a committed write to FIFO_DATA with room in the FIFO
    din = intern_write_data & wmask;                            // data to push, masked-off byte lanes become 0
    fifo_full_wr = w_sel_fifo & full;                           // write to FIFO_DATA while the FIFO is full
    werror[1] = w_sel_status | w_sel_ver | w_unmapped | fifo_full_wr;   // SLVERR for read-only register, unmapped address, or write on full
    werror[0] = 1'd0;                                           // bit 0 of the response is always 0 (OKAY=00, SLVERR=10)

////////////////////////////////////////////////////////////////////////////////// EVENT DETECTION //////////////////////////////////////////////////////////////////////////////////

    ev_full = full & !full_prev;                                // FIFO just became full (0 -> 1 transition)
    ev_empty =  empty & !empty_prev;                            // FIFO just became empty (0 -> 1 transition)
    ev_err_w = write_en_pulse & w_sel_fifo & full;              // error: a committed write to FIFO_DATA while full
    ev_err_r = read_en_pulse & r_sel_fifo & empty;              // error: a committed read of FIFO_DATA while empty
    ev_err = ev_err_r | ev_err_w;                               // either error happened this cycle

////////////////////////////////////////////////////////////////////////////////// STICKY STATUS.ERROR  //////////////////////////////////////////////////////////////////////////////////

    err_set = ev_err | err_sticky;                              // set on a new error, hold if already set
    err_sticky_detect = err_set & !soft_reset;                  // next value of STATUS.ERROR, soft reset clears it and wins

////////////////////////////////////////////////////////////////////////////////// IRQ STATUS  //////////////////////////////////////////////////////////////////////////////////

    // hold or clear each IRQ_STATUS bit    
    for(j = 0; j < 3; j = j + 1) keep[j] = irq_status[j] & !clear[j];     // bit stays set unless software wrote 1 to clear it

    // set bits on events (event wins over clear)
    irqst_detect[0] = keep [0] | ev_full;                       // bit 0: FIFO became full
    irqst_detect[1] = keep [1] | ev_empty;                      // bit 1: FIFO became empty
    irqst_detect[2] = keep [2] | ev_err;                        // bit 2: error occurred

    // interrupt output
    for(k = 0; k < 3; k = k + 1) irq_pend[k] = irq_status[k] & irq_en[k]; // a bit raises the interrupt only if it is set and enabled

    irq = |irq_pend;                                            // interrupt is high if any enabled bit is pending


////////////////////////////////////////////////////////////////////////////////// READ PATH //////////////////////////////////////////////////////////////////////////////////

    // per-register read words
    // CTRL READ WORD
    ctrl_word[31:4] = 28'd0;                // unused upper bits read 0
    ctrl_word[3:2] = ctrl_mode;             // MODE
    ctrl_word[1] = 1'd0;                    // SOFT_RESET is a command, it has no storage and reads 0
    ctrl_word[0] = ctrl_enable;             // ENABLE

    // STATUS READ WORD
    status_word[31:5] = 27'd0;              // unused upper bits read 0
    status_word[4] = err_sticky;            // ERROR (sticky)
    status_word[3:2] = 2'd0;                // reserved bits read 0
    status_word[1] = full;                  // FIFO_FULL (live)
    status_word[0] = empty;                 // FIFO_EMPTY (live)

    // IRQ_EN read word
    irqen_word = {29'd0, irq_en[2:0]};      // 3 enable bits, zero-extended to 32

    // IRQ_STATUS read word
    irqst_word = {29'd0, irq_status[2:0]};  // 3 status bits, zero-extended to 32

    // FIFO Read word
    if(empty)   fifo_word = last_read;      // FIFO empty: return the last popped word instead of garbage
    else fifo_word = dout;                  // FIFO has data: show the head word

    // FIFO POP
    pop = read_en_pulse & r_sel_fifo & !empty;  // pop only on a committed read of FIFO_DATA when there is data

    // Version read word
    version_word = 32'h0001_0000;           // constant: major 1, minor 0

    // read mux 
    t_ctrl = {32{r_sel_ctrl}} & ctrl_word;          // CTRL word passes only if CTRL is selected
    t_status = {32{r_sel_status}} & status_word;    // STATUS word passes only if STATUS is selected
    t_fifo = {32{r_sel_fifo}} & fifo_word;          // FIFO word passes only if FIFO_DATA is selected
    t_irqen = {32{r_sel_irqen}} & irqen_word;       // IRQ_EN word passes only if IRQ_EN is selected
    t_irqst = {32{r_sel_irqstat}} & irqst_word;     // IRQ_STATUS word passes only if IRQ_STATUS is selected
    t_ver = {32{r_sel_ver}} & version_word;         // VERSION word passes only if VERSION is selected

    // read data and read response
    read_data_ready = read_en_pulse;                // read completes in the same cycle, so data is ready when the pulse is high
    rerror = {r_unmapped, 1'b0};                    // SLVERR (2'b10) only for an unmapped read address
    intern_read_data = t_ctrl | t_status | t_fifo | t_irqen | t_irqst | t_ver;  // only one term is non-zero, so OR merges them
end

////////////////////////////////////////////////////////////////////////////////// REGISTERS //////////////////////////////////////////////////////////////////////////////////

always @(posedge ACLK or negedge ARESETN)
begin
    if(!ARESETN)
    begin
        ctrl_enable <= 1'd0;        // ENABLE off after reset
        ctrl_mode <= 2'd0;          // MODE 0 after reset
        soft_reset <= 1'd0;         // no soft reset pulse after reset
        irq_en <= 3'd0;             // all interrupts disabled after reset
        full_prev <= 1'd0;          // FIFO is not full at reset
        empty_prev <= 1'd1;         // FIFO is empty at reset, 1 avoids a false "became empty" event
        err_sticky <= 1'd0;         // no error after reset
        irq_status <= 3'd0;         // no pending interrupts after reset
        last_read <= 32'd0;         // empty-FIFO read returns 0 until the first pop
    end
    else
    begin
        // CTRL / IRQ_EN storage
        if(ctrl_we)
        begin
            ctrl_enable <= intern_write_data[0];        // store ENABLE
            ctrl_mode <= intern_write_data [3:2];       // store MODE
        end

        if(irqen_we)  irq_en <= intern_write_data [2:0];    // store the 3 interrupt enables

        // soft reset pulse
        soft_reset <= softreset_detect;                 // one-cycle pulse, one cycle after the CTRL write

        // previous FIFO flags
        full_prev <= full;                              // remember full for next cycle's transition check
        empty_prev <= empty;                            // remember empty for next cycle's transition check

        // sticky error and interrupt status
        err_sticky <= err_sticky_detect;                // update STATUS.ERROR

        irq_status <= irqst_detect;                     // update IRQ_STATUS (hold, clear, or set on events)

        // last popped word
        if(pop) last_read <= dout;                      // remember the popped word for empty reads
    end
end

endmodule