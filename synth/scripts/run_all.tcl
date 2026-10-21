# Run all: execute the four synthesis scripts in order in one dc_shell session

# Folder for the log of this run
file mkdir $::env(OUTPUT_DIR)/logs

# 1. names, clock period, report precision
source -echo $::env(SCRIPT_DIR)/setup.tcl

# 2. read the RTL and build the design
source -echo $::env(SCRIPT_DIR)/read.tcl

# 3. clock, I/O timing, driving cell, load, area goal
source -echo $::env(SCRIPT_DIR)/constraints.tcl

# 4. compile, reports, netlist, one-line summary
source -echo $::env(SCRIPT_DIR)/compile.tcl

exit