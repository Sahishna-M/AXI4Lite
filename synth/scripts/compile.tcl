# Compile: map the RTL to library gates, meet CLK_PER, and write out the results

# Output folders for this run 
file mkdir $::env(OUTPUT_DIR)/reports
file mkdir $::env(OUTPUT_DIR)/gatelevel

# Synthesize. -no_autoungroup stops DC from merging small blocks into their parent,
# so slave_fsm, reg_bank and sync_fifo stay separate for the per-block area report.
compile_ultra -no_autoungroup

# Setup timing
report_timing -delay_type max > $::env(OUTPUT_DIR)/reports/timing_setup.rpt

# Hold timing
report_timing -delay_type min > $::env(OUTPUT_DIR)/reports/timing_hold.rpt

# Every violated constraint in one list: setup, hold, and design rules (max transition, capacitance, fanout)
report_constraint -all_violators > $::env(OUTPUT_DIR)/reports/violators.rpt

# Area per block (FSM, register bank, FIFO) plus the total
report_area -hierarchy > $::env(OUTPUT_DIR)/reports/area.rpt

# Overall summary: cell counts, worst slack, area
report_qor > $::env(OUTPUT_DIR)/reports/qor.rpt

# Gate-level netlist, hierarchy kept so the three blocks appear as separate modules
write -format verilog -hierarchy -output $::env(OUTPUT_DIR)/gatelevel/$modname.v

# Numbers for the sweep table: worst setup slack, hold and total area for this run
set slack [get_attribute [get_timing_paths -delay_type max] slack]
set hold [get_attribute [get_timing_paths -delay_type min] slack]
# Read the cell area from the area report (the area attribute is undefined without a wire load model)
set fa [open $::env(OUTPUT_DIR)/reports/area.rpt r]
set area_txt [read $fa]
close $fa
regexp {Total cell area:\s+([0-9.]+)} $area_txt -> area

# Summary
set fp [open $::env(OUTPUT_DIR)/summary.txt a]
puts $fp "$CLK_PER $slack $hold $area"
close $fp

# Printing to log
echo "SUMMARY: period=$CLK_PER setup=$slack hold=$hold area=$area"

echo "compile.tcl done"