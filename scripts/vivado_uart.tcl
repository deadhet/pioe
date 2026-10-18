# =============================================================================
# vivado_uart.tcl — (re)build the Vivado simulation project for the UART
#
# Usage (from anywhere, after sourcing Vivado's settings64.sh):
#   vivado -mode batch -source pioe/scripts/vivado_uart.tcl                 # build project
#   vivado -mode batch -source pioe/scripts/vivado_uart.tcl -tclargs sim    # build + run all 3 sims
#   vivado -mode batch -source pioe/scripts/vivado_uart.tcl -tclargs sim_rx # build + run one sim set
#   vivado -source pioe/scripts/vivado_uart.tcl                             # build + open GUI
#
# Simulation sets (one testbench each; pick one in the GUI with "Make Active"):
#   sim_1  : tb_uart     (TX -> RX loopback / system test)
#   sim_tx : tb_uart_tx  (uart_tx alone, judged by the reference receiver)
#   sim_rx : tb_uart_rx  (uart_rx alone, fed by the reference transmitter)
#
# The project lives OUTSIDE the git repo (<PIOE>/vivado/uart). Sources are added
# by reference, so edits made in Vivado land in the repo files.
# Re-running the script deletes and recreates the project (sources untouched).
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set proj_dir   [file normalize [file join $repo_dir .. vivado uart]]
set proj_name  uart

# Part is only a placeholder: behavioural simulation does not depend on it.
set part       xc7a35tcpg236-1

set design_srcs [list \
    [file join $repo_dir src uart_tx.v] \
    [file join $repo_dir src uart_rx.v] ]
set ref_srcs [list \
    [file join $repo_dir test ref ref_uart_tx.v] \
    [file join $repo_dir test ref ref_uart_rx.v] ]

# simset -> {testbench file, top module, extra sim-only sources}
set simsets [dict create \
    sim_1  [list [file join $repo_dir test tb_uart.sv]    tb_uart    {}] \
    sim_tx [list [file join $repo_dir test tb_uart_tx.sv] tb_uart_tx $ref_srcs] \
    sim_rx [list [file join $repo_dir test tb_uart_rx.sv] tb_uart_rx $ref_srcs] ]

create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
# Compile order stays automatic, but the top of each sim set is ours.
set_property source_mgmt_mode DisplayOnly [current_project]

# Design sources (by reference: no -copy_to / import_files)
add_files -norecurse -fileset sources_1 $design_srcs
update_compile_order -fileset sources_1

dict for {simset info} $simsets {
    lassign $info tb_src tb_top extra_srcs
    if {[llength [get_filesets -quiet $simset]] == 0} {
        create_fileset -simset $simset
    }
    set fs [get_filesets $simset]
    add_files -norecurse -fileset $fs [concat [list $tb_src] $extra_srcs]
    set_property file_type SystemVerilog [get_files -of_objects $fs $tb_src]
    set_property top     $tb_top        $fs
    set_property top_lib xil_defaultlib $fs
    set_property -name {xsim.simulate.runtime} -value {all} -objects $fs
    # Record every signal from time 0, so any signal dragged into the wave
    # window later already has its full history (no restart needed).
    set_property -name {xsim.simulate.log_all_signals} -value {true} -objects $fs
    update_compile_order -fileset $fs
}
current_fileset -simset [get_filesets sim_1]

puts "INFO: project created at $proj_dir/$proj_name.xpr"

# Optional: run behavioural simulation(s) in batch mode
set to_run {}
if {[lsearch -exact $argv sim] >= 0} { set to_run [dict keys $simsets] }
foreach s [dict keys $simsets] {
    if {[lsearch -exact $argv $s] >= 0} { lappend to_run $s }
}
foreach s $to_run {
    puts "INFO: ===== running $s"
    launch_simulation -simset $s -mode behavioral
    close_sim
}
