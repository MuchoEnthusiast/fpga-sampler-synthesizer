
# Post-route pin audit for the FPGA live sampler (Vivado Tcl, not XDC).
# Run after open_run impl_1:
# source vivado/check_pin_mapping.tcl
#
# Pin assignments from the Digilent Nexys 4 DDR Rev C master XDC.

set expected_pins {
    {CLK100MHZ} E3

    {SW0} J15
    {SW1} L16
    {SW2} M13
    {SW3} R15
    {SW4} R17
    {SW5} T18

    {LED[0]} H17
    {LED[1]} K15
    {LED[2]} J13
    {LED[3]} N14
    {LED[4]} R18
    {LED[5]} V17
    {LED[6]} U17
    {LED[7]} U16
    {LED[8]} V16
    {LED[9]} T15
    {LED[10]} U14
    {LED[11]} T16
    {LED[12]} V15
    {LED[13]} V14
    {LED[14]} V12
    {LED[15]} V11

    {CPU_RESETN} C12
    {BTNC} N17
    {BTNU} M18
    {BTNL} P17
    {BTND} P18

    {M_CLK} J5
    {M_DATA} H5
    {M_LRSEL} F5

    {AUD_PWM} A11
    {AUD_SD} D12

    {UART_TXD_IN} C4
}

set problems {}

# Verify the number of top-level logical ports.
set actual_port_count [llength [get_ports -quiet *]]

if {$actual_port_count != 34} {
    lappend problems \
        "Expected 34 top-level ports; found $actual_port_count"
}

# Verify every package pin and I/O standard.
foreach {port pin} $expected_pins {

    set ports [get_ports -quiet [list $port]]

    if {[llength $ports] != 1} {
        lappend problems "Missing or ambiguous port: $port"
    } else {

        set actual_pin [get_property PACKAGE_PIN $ports]
        set standard [get_property IOSTANDARD $ports]

        if {$actual_pin ne $pin} {
            lappend problems \
                "$port: PACKAGE_PIN=$actual_pin, expected $pin"
        }

        if {$standard ne "LVCMOS33"} {
            lappend problems \
                "$port: IOSTANDARD=$standard, expected LVCMOS33"
        }
    }
}

# Report the complete audit.
if {[llength $problems] != 0} {
    error "FAIL: board I/O constraints:\n[join $problems \n]"
}

puts "PASS: all 34 board ports match the expected package pins and LVCMOS33 standards."
