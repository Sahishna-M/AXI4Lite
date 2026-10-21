# Constraints: describe the environment around axi_lite_top so synthesis and timing analysis are realistic

# Top design
current_design $modname

# Applies the period to the design
create_clock -name $clkname -period $CLK_PER [get_ports $clkname]

# Margin for clock skew and jitter, subtracted from the time available to every path (ns)
set_clock_uncertainty 0.05 $clkname

# Assumptions about the flip-flops outside the block (provisional, to be calibrated from the first timing report)
# The AXI master and the logic after outputs are assumed to register their signals
# DFF_CKQ: clock-to-Q delay of the flop driving inputs (ns)
set DFF_CKQ 0.638
# DFF_SETUP: setup time of the flop capturing outputs (ns)
set DFF_SETUP 0.546
# WIRE_DELAY: estimated wire delay on each input and output (ns)
set WIRE_DELAY 0.02

# Time after the clock edge when an input arrives: the driving flop's clock-to-Q plus the wire
set IP_DELAY [expr $WIRE_DELAY + $DFF_CKQ]
# Time before the next clock edge that an output must be ready: the capturing flop's setup plus the wire
set OP_DELAY [expr $WIRE_DELAY + $DFF_SETUP]

# All input ports except the clock
set data_inputs [remove_from_collection [all_inputs] [get_ports $clkname]]

# Apply the input and output timing budgets
set_input_delay $IP_DELAY -clock $clkname $data_inputs
set_output_delay $OP_DELAY -clock $clkname [all_outputs]

# Inputs are driven by a real flip-flop (DFFR_X1, output Q), not an ideal source, so input slew is realistic
set DR_CELL_NAME DFFR_X1
set DR_CELL_PIN Q
set_driving_cell -lib_cell $DR_CELL_NAME -pin $DR_CELL_PIN $data_inputs

# Output load: FANOUT flip-flop D pins plus an estimate for the wire (library capacitance units)
set FANOUT 4
set WIRE_LOAD_EST 0.013
set PORT_LOAD [expr $WIRE_LOAD_EST + $FANOUT * [load_of NangateOpenCellLibrary_PDKv1_2_v2008_10_slow_nldm/DFFR_X1/D]]
set_load $PORT_LOAD [all_outputs]

# Area goal: 0 can't be met, so the compiler keeps minimizing area after timing is met
set_max_area 0

# Give every port its own net, with buffers on constant-driven ports, so the written netlist has no assign statements
set_fix_multiple_port_nets -all -buffer_constants [get_designs]
