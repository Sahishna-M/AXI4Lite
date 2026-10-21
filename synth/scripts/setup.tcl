# Setup: names and values shared by all the synthesis scripts

# Clock
set clkname ACLK                                    

# Design
set modname axi_lite_top                            

# Reports: built-in DC variable: print 4 decimals in timing report
set report_default_significant_digits 4          

# Clock period (ns)
if {[info exists ::env(DC_CLK_PER)]} {              
    set CLK_PER $::env(DC_CLK_PER)                  
} else {
    set CLK_PER 10.0                               
}

# Log
echo "\[setup.tcl\] CLK_PER=${CLK_PER}"            