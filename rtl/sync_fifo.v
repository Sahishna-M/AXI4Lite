module sync_fifo #(
    parameter WIDTH = 32,                       // width of each stored word
    parameter DEPTH = 16)                       // number of words stored
    (input clk, rst_n, push, pop, soft_reset, // clock, active-LOW async reset, write request, read request, synchronous clear
    input [WIDTH-1:0] din,               // word to be pushed
    output [WIDTH-1:0] dout,              // oldest word in the FIFO
    output full, empty                    // status flags
);

////////////////////////////////////////////////////////////////////////////////// SIGNAL DECLARATIONS //////////////////////////////////////////////////////////////////////////////////

    reg [$clog2(DEPTH)-1:0] read_ptr, write_ptr;  // slot index of the oldest word / next free slot
    reg read_flag, write_flag;                    // phase bits: toggle each time their pointer wraps past the last slot
    reg [WIDTH-1:0] fifo [0:DEPTH-1];                 // storage array, DEPTH words of WIDTH bits, no reset

////////////////////////////////////////////////////////////////////////////////// POINTERS AND PHASE BITS //////////////////////////////////////////////////////////////////////////////////

    always @(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
        begin
            read_ptr <= 0;                         // read from slot 0 after reset
            write_ptr <= 0;                        // write to slot 0 after reset
            read_flag <= 1'd0;                      // same phase on both sides = empty
            write_flag <= 1'd0;
        end

        else
        begin
            // write side
            if(push && !full)                       // request made and there is room
            begin
                write_ptr <= write_ptr + 1'd1;      // move to the next slot
                if(write_ptr == DEPTH - 1)          // was the last slot
                begin
                    write_ptr <= 1'd0;              // wrap back to slot 0
                    write_flag <= !write_flag;      // one lap done, toggle the phase bit
                end
            end

            // read side
            if(pop && !empty)                       // request made and there is data
            begin
                read_ptr <= read_ptr + 1'd1;        // move to the next slot
                if(read_ptr == DEPTH - 1)           // was the last slot
                begin
                    read_ptr <= 1'd0;               // wrap back to slot 0
                    read_flag <= !read_flag;        // one lap done, toggle the phase bit
                end
            end

            // synchronous clear (last, so it wins over push and pop)
            if(soft_reset)
            begin
                read_ptr <= 0;                     // back to the post-reset state, FIFO is empty
                write_ptr <= 0;
                read_flag <= 0;
                write_flag <= 0;
            end
        end
    end

////////////////////////////////////////////////////////////////////////////////// MEMORY WRITE //////////////////////////////////////////////////////////////////////////////////

always @(posedge clk)
begin
    if(push && !full && !soft_reset)               
    begin
        fifo[write_ptr] <= din;                     // store the word in the slot write_ptr points at
    end
end

////////////////////////////////////////////////////////////////////////////////// FLAGS AND READ OUTPUT //////////////////////////////////////////////////////////////////////////////////

assign full = (read_ptr == write_ptr && read_flag != write_flag);   // same slot, different phase
assign empty = (read_ptr == write_ptr && read_flag == write_flag);  // same slot, same phase
assign dout = fifo[read_ptr];                       // oldest word
endmodule