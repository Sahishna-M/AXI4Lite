# Read: load the RTL and build the design hierarchy (runs after setup.tcl, so $modname is already set)

# Parse the four Verilog files. RTL_FILES is an environment variable set by the Makefile.
# analyze only checks syntax and stores the modules, nothing is built yet.
analyze -format verilog $::env(RTL_FILES)

# Build the top module and everything inside it.
elaborate $modname

# Make the top module the working design for all the scripts that follow.
current_design $modname

# Connect every instance (slave_fsm, reg_bank, sync_fifo) to its module. Reports an error for any unresolved reference.
link

# Sanity check on the built design: unconnected ports, undriven inputs, multiple drivers. 
check_design

# Prints the number of latches in the design
echo "latches: [sizeof_collection [all_registers -level_sensitive]]"