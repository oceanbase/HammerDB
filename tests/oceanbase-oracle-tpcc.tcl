# Offline SQL sequence tests for the Oracle client-side transactions.
package require tcltest 2
namespace import ::tcltest::test
source [file join [file dirname [info script]] .. modules oceanbaseoracletpcc-1.0.tm]

proc mock_cursor {method args} {
    global expected pending
    switch -- $method {
        query {
            if {[llength $pending]} {error "Previous SELECT result was not drained"}
            set sql [regsub -all {\s+} [lindex $args 0] { }]
            lassign [lindex $expected 0] pattern result
            if {$pattern eq {} || ![regexp $pattern $sql]} {
                error "Expected $pattern but got $sql"
            }
            set expected [lrange $expected 1 end]
            if {[lindex $result 0] eq "error"} {
                return -code error -errorcode [list OBCLIENT [lindex $result 1]] "Mock database error"
            } elseif {[regexp {^SELECT\M} $sql]} {
                set pending $result
                return 0
            }
            return $result
        }
        fetch {
            set row [lindex $pending 0]
            set found [expr {[llength $pending] > 0}]
            set pending [lrange $pending 1 end]
            return [list $found $row]
        }
        default {error "Expected the text SQL protocol, got $method"}
    }
}

proc run_transaction {name bindings statements} {
    global expected pending
    set expected $statements
    set pending {}
    set output [oceanbaseoracletpcc::execute mock_cursor $name $bindings]
    if {[llength $expected]} {error "Missing SQL: $expected"}
    return $output
}

test oracle-client-new-order {Generate order lines and lock the district} -body {
    expr {srand(10)}
    set statements {
        {{^SELECT c_discount,c_last,c_credit,w_tax .*c_w_id=3 AND c_d_id=2 AND c_id=9} {{.01 Doe GC .02}}}
        {{^SELECT d_next_o_id,d_tax .* d_w_id=3 AND d_id=2 FOR UPDATE$} {{3001 .03}}}
        {{^UPDATE district SET d_next_o_id=d_next_o_id\+1 WHERE d_w_id=3 AND d_id=2$} 1}
        {{^INSERT INTO orders .*VALUES \(3001,2,3,9,TO_DATE\('20261116123456','YYYYMMDDHH24MISS'\),5,[01]\)$} 1}
        {{^INSERT INTO new_order .*VALUES \(3001,2,3\)$} 1}
    }
    for {set line 1} {$line <= 5} {incr line} {
        lappend statements [list {^UPDATE stock .*WHERE s_w_id=[0-9]+ AND s_i_id=[0-9]+$} 1]
        lappend statements [list [format {^INSERT INTO order_line .*SELECT 3001,2,3,%d,.*i_price\*[0-9]+,s_dist_02 FROM stock,item} $line] 1]
    }
    lappend statements {{^COMMIT$} 0}
    run_transaction NEWORD {:NO_W_ID 3 :NO_MAX_W_ID 5 :NO_D_ID 2 :NO_C_ID 9 :NO_O_OL_CNT 5 :TIMESTAMP 20261116123456} $statements
} -result {.01 Doe GC .03 .02 3001}

test oracle-client-payment {Select the remote median customer and retain bad-credit history} -body {
    run_transaction payment \
        {:P_W_ID 3 :P_D_ID 2 :P_C_W_ID 5 :P_C_D_ID 4 :P_C_ID 9 :BYNAME 1 :P_C_LAST O'Neil :P_H_AMOUNT 20 :TIMESTAMP 20261116123456} {
        {{^SELECT c_id .*c_w_id=5 AND c_d_id=4 AND c_last='O''Neil' ORDER BY c_first$} {11 12 13 14}}
        {{^UPDATE customer SET c_balance=c_balance-\(20\) WHERE c_w_id=5 AND c_d_id=4 AND c_id=12$} 1}
        {{^SELECT c_last,c_first.*FROM customer WHERE c_w_id=5 AND c_d_id=4 AND c_id=12$} {{O'Neil Jane OE cs1 cs2 city st zip phone since BC 500 .2 50}}}
        {{^UPDATE customer SET c_data=SUBSTR\( '12 4 5 2 3 ' .*WHERE c_w_id=5 AND c_d_id=4 AND c_id=12$} 1}
        {{^SELECT SUBSTR\(c_data,1,200\).*c_id=12$} {prefix}}
        {{^UPDATE district SET d_ytd=d_ytd\+\(20\) WHERE d_w_id=3 AND d_id=2$} 1}
        {{^SELECT d_street_1.*FROM district WHERE d_w_id=3 AND d_id=2$} {{ds1 ds2 dc dst dz D's}}}
        {{^UPDATE warehouse SET w_ytd=w_ytd\+\(20\) WHERE w_id=3$} 1}
        {{^SELECT w_street_1.*FROM warehouse WHERE w_id=3$} {{ws1 ws2 wc wst wz W's}}}
        {{^INSERT INTO history .*VALUES \(12,4,5,2,3,TO_DATE\('20261116123456','YYYYMMDDHH24MISS'\),20,'W''s D''s'\)$} 1}
        {{^COMMIT$} 0}
    }
} -result {12 O'Neil ws1 ws2 wc wst wz ds1 ds2 dc dst dz Jane OE cs1 cs2 city st zip phone since BC 500 .2 50 prefix}

test oracle-client-order-status {Return blank order fields if no order exists} -body {
    run_transaction ostat {:OS_W_ID 3 :OS_D_ID 2 :OS_C_ID 9 :BYNAME 0 :OS_C_LAST {}} {
        {{^SELECT c_last,c_first,c_middle,c_balance .*c_w_id=3 AND c_d_id=2 AND c_id=9$} {{Doe Jane OE 50}}}
        {{^SELECT o_id,o_entry_d,o_carrier_id .*WHERE o_w_id=3 AND o_d_id=2 AND o_c_id=9 ORDER BY o_id DESC\) WHERE ROWNUM=1$} {}}
        {{^COMMIT$} 0}
    }
} -result {9 Doe Jane OE 50 {} {} {}}

test oracle-client-delivery {Deliver only claimed orders and continue past empty districts} -body {
    set statements {
        {{^SELECT MIN\(no_o_id\) FROM new_order WHERE no_w_id=3 AND no_d_id=1$} {{{}}}}
        {{^SELECT MIN\(no_o_id\) FROM new_order WHERE no_w_id=3 AND no_d_id=2$} {3001}}
        {{^DELETE FROM new_order WHERE no_w_id=3 AND no_d_id=2 AND no_o_id=3001$} 1}
        {{^SELECT MIN\(no_o_id\) FROM new_order WHERE no_w_id=3 AND no_d_id=3$} {3002}}
        {{^DELETE FROM new_order WHERE no_w_id=3 AND no_d_id=3 AND no_o_id=3002$} 0}
    }
    for {set district 4} {$district <= 10} {incr district} {
        lappend statements [list [format {^SELECT MIN\(no_o_id\) FROM new_order WHERE no_w_id=3 AND no_d_id=%d$} $district] {{{}}}]
    }
    lappend statements {*}{
        {{^UPDATE orders SET o_carrier_id=7 WHERE o_w_id=3 AND o_d_id=2 AND o_id=3001$} 1}
        {{^SELECT o_c_id FROM orders WHERE o_w_id=3 AND o_d_id=2 AND o_id=3001$} {9}}
        {{^UPDATE order_line SET ol_delivery_d=TO_DATE\('20261116123456','YYYYMMDDHH24MISS'\) WHERE ol_w_id=3 AND ol_d_id=2 AND ol_o_id=3001$} 5}
        {{^SELECT SUM\(ol_amount\) FROM order_line WHERE ol_w_id=3 AND ol_d_id=2 AND ol_o_id=3001$} {52.42}}
        {{^UPDATE customer SET c_balance=c_balance\+\(52.42\) WHERE c_w_id=3 AND c_d_id=2 AND c_id=9$} 1}
        {{^COMMIT$} 0}
    }
    run_transaction delivery {:D_W_ID 3 :D_O_CARRIER_ID 7 :TIMESTAMP 20261116123456} $statements
} -result {}

test oracle-client-stock-level {Send concrete warehouse predicates and commit the read} -body {
    run_transaction slev {:ST_W_ID 3 :ST_D_ID 2 :THRESHOLD 11} {
        {{^SELECT COUNT.*FROM district,order_line,stock WHERE d_w_id=3 AND d_id=2.*s_quantity<11 .*d_next_o_id-20 AND d_next_o_id-1$} {15}}
        {{^COMMIT$} 0}
    }
} -result 15

test oracle-client-rollback {Roll back both recoverable and unexpected transaction errors} -body {
    set bindings {:ST_W_ID 3 :ST_D_ID 2 :THRESHOLD 11}
    set transient [run_transaction slev $bindings {{{^SELECT COUNT} {error 60}} {{^ROLLBACK$} 0}}]
    catch {run_transaction slev $bindings {{{^SELECT COUNT} {error 942}} {{^ROLLBACK$} 0}}} message options
    list $transient $message [dict get $options -errorcode] $expected
} -result {{} {Mock database error} {OBCLIENT 942} {}}

::tcltest::cleanupTests
