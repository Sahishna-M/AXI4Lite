# Simulation Makefile 
.PHONY: lib compile sim clean

# RTL files
RTL = ../rtl/sync_fifo.v ../rtl/reg_bank.v ../rtl/slave_fsm.v ../rtl/axi_lite_top.v

# Create the QuestaSim work library 
lib :
	vlib work

# Compile the RTL, then the testbench 
compile : lib
	vlog $(RTL)
	vlog -sv ../tb/top.sv

# Run headless until $finish, the whole simulation output is also saved to run.log
sim : compile
	vsim -c work.top -do "run -all; quit" -l run.log

# Remove everything the simulation generated
clean :
	rm -rf work transcript
	rm -f run.log