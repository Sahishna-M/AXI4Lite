# Synthesis Makefile: runs Design Compiler for axi_lite_top at one or many clock periods
# Targets: synth (one period), sweep (all periods + results table), clean
.PHONY: synth sweep clean

# RTL files with absolute paths
RTL_DIR = $(abspath ../rtl)
RTL = $(RTL_DIR)/sync_fifo.v $(RTL_DIR)/reg_bank.v $(RTL_DIR)/slave_fsm.v $(RTL_DIR)/axi_lite_top.v

# Folder with the Tcl scripts 
SCRIPT_DIR = $(abspath scripts)

# Clock period in ns for a single run, override with: make synth PERIOD=4
PERIOD ?= 10.0

# Each period gets its own folder so runs never overwrite each other
RUN_DIR = runs/p$(PERIOD)

# Clock periods (ns) tried by the sweep
PERIODS = 10 8 6 5 4 3.5 3 2.5 2

# One synthesis run at PERIOD:
#  1. create the run folder and its logs folder
#  2. copy the DC startup file (library setup) into the folder dc_shell starts from
#  3. start dc_shell there with the four environment variables the Tcl scripts read:
#     DC_CLK_PER (clock period), OUTPUT_DIR (where reports go), RTL_FILES, SCRIPT_DIR
synth:
	mkdir -p $(RUN_DIR)/logs
	cp scripts/.synopsys_dc.setup $(RUN_DIR)/
	cd $(RUN_DIR) && DC_CLK_PER=$(PERIOD) OUTPUT_DIR=$(abspath $(RUN_DIR)) RTL_FILES="$(RTL)" SCRIPT_DIR=$(SCRIPT_DIR) dc_shell -no_gui -x "source $(SCRIPT_DIR)/run_all.tcl" < /dev/null | tee logs/dc.log

# Run every period in PERIODS, then collect each run's "period setup hold area" line into one table sorted by period
sweep:
	for p in $(PERIODS); do $(MAKE) synth PERIOD=$$p; done
	echo "period_ns  setup_slack_ns  hold_slack_ns  total_area_um2" > sweep_results.txt
	cat runs/p*/summary.txt | sort -n >> sweep_results.txt

# Remove all runs and the results table
clean:
	rm -rf runs sweep_results.txt