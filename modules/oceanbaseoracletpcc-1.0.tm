# Client-side TPROC-C for OceanBase Oracle. The generated driver keeps its
# transaction mix and per-VU inputs and opens sessions with autocommit off.
namespace eval oceanbaseoracletpcc {
    proc number {value} {
        if {![regexp {^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$} $value]} {
            error "Invalid numeric TPROC-C value"
        }
        return $value
    }

    proc literal {value} {
        if {$value eq {}} {return NULL}
        if {[string first \x00 $value] >= 0} {error "NUL in TPROC-C text value"}
        return "'[string map [list ' ''] $value]'"
    }

    proc timestamp {value} {
        if {![regexp {^[0-9]{14}$} $value]} {error "Invalid TPROC-C timestamp"}
        return "TO_DATE('$value','YYYYMMDDHH24MISS')"
    }

    proc select_rows {cursor sql} {
        $cursor query $sql
        set rows {}
        while {1} {
            lassign [$cursor fetch] found row
            if {!$found} {return $rows}
            lappend rows $row
        }
    }

    proc select_one {cursor sql} {
        set rows [select_rows $cursor $sql]
        if {[llength $rows] != 1} {error "Expected one row in TPROC-C transaction"}
        return [lindex $rows 0]
    }

    proc execute {cursor procedure bindings} {
        set procedure [string tolower $procedure]
        if {$procedure ni {neword payment ostat delivery slev}} {
            error "Unknown OceanBase Oracle TPROC-C transaction: $procedure"
        }
        try {
            return [$procedure $cursor $bindings]
        } on error {message options} {
            $cursor query ROLLBACK
            # Match the procedures' rollback handlers for serialization,
            # deadlock and snapshot errors, plus duplicate keys in NEWORD.
            set code [dict get $options -errorcode]
            if {[lindex $code 0] eq "OBCLIENT" &&
                ([lindex $code 1] in {60 1555 8177} ||
                 ($procedure eq "neword" && [lindex $code 1] eq "1"))} {
                return {}
            }
            return -options $options $message
        }
    }

    proc neword {cursor bindings} {
        set w [number [dict get $bindings :NO_W_ID]]
        set warehouses [number [dict get $bindings :NO_MAX_W_ID]]
        set d [number [dict get $bindings :NO_D_ID]]
        set customer [number [dict get $bindings :NO_C_ID]]
        set count [number [dict get $bindings :NO_O_OL_CNT]]
        set date [timestamp [dict get $bindings :TIMESTAMP]]
        lassign [select_one $cursor "SELECT c_discount,c_last,c_credit,w_tax FROM customer,warehouse
            WHERE c_w_id=$w AND c_d_id=$d AND c_id=$customer AND w_id=$w"] discount last credit wtax
        set lines {}
        set all_local 1
        for {set line 1} {$line <= $count} {incr line} {
            set item [expr {round(1 + rand() * 99999)}]
            set supply $w
            if {rand() < 0.01} {
                set all_local 0
                set supply [expr {1 + ($w + round(rand() * ($warehouses - 1))) % $warehouses}]
            }
            set quantity [expr {round(1 + rand() * 9)}]
            lappend lines [list $line $item $supply $quantity]
        }
        lassign [select_one $cursor "SELECT d_next_o_id,d_tax FROM district WHERE d_w_id=$w AND d_id=$d FOR UPDATE"] order dtax
        set order [number $order]
        $cursor query "UPDATE district SET d_next_o_id=d_next_o_id+1 WHERE d_w_id=$w AND d_id=$d"
        $cursor query "INSERT INTO orders (o_id,o_d_id,o_w_id,o_c_id,o_entry_d,o_ol_cnt,o_all_local)
            VALUES ($order,$d,$w,$customer,$date,$count,$all_local)"
        $cursor query "INSERT INTO new_order (no_o_id,no_d_id,no_w_id) VALUES ($order,$d,$w)"
        set distribution [format "s_dist_%02d" $d]
        foreach row $lines {
            lassign $row line item supply quantity
            set updated [$cursor query "UPDATE stock SET s_quantity=
                (CASE WHEN s_quantity < $quantity+10 THEN s_quantity+91 ELSE s_quantity END)-$quantity
                WHERE s_w_id=$supply AND s_i_id=$item"]
            if {$updated != 1} {error "Expected one stock row for New Order"}
            set inserted [$cursor query "INSERT INTO order_line
                (ol_o_id,ol_d_id,ol_w_id,ol_number,ol_i_id,ol_supply_w_id,ol_quantity,ol_amount,ol_dist_info)
                SELECT $order,$d,$w,$line,$item,$supply,$quantity,i_price*$quantity,$distribution
                FROM stock,item WHERE s_w_id=$supply AND s_i_id=$item AND i_id=s_i_id"]
            if {$inserted != 1} {error "Expected one item for New Order"}
        }
        if {rand() < 0.01} {
            $cursor query ROLLBACK
        } else {
            $cursor query COMMIT
        }
        return [list $discount $last $credit $dtax $wtax $order]
    }

    proc customer_id {cursor w d id byname last} {
        if {!$byname} {return [number $id]}
        set last [literal $last]
        set matches [select_rows $cursor "SELECT c_id FROM customer
            WHERE c_w_id=$w AND c_d_id=$d AND c_last=$last ORDER BY c_first"]
        if {![llength $matches]} {error "No customer found by name"}
        return [number [lindex $matches [expr {([llength $matches]-1)/2}] 0]]
    }

    proc payment {cursor bindings} {
        set w [number [dict get $bindings :P_W_ID]]
        set d [number [dict get $bindings :P_D_ID]]
        set cw [number [dict get $bindings :P_C_W_ID]]
        set cd [number [dict get $bindings :P_C_D_ID]]
        set amount [number [dict get $bindings :P_H_AMOUNT]]
        set date [timestamp [dict get $bindings :TIMESTAMP]]
        set customer [customer_id $cursor $cw $cd [dict get $bindings :P_C_ID] \
            [dict get $bindings :BYNAME] [dict get $bindings :P_C_LAST]]
        set key "c_w_id=$cw AND c_d_id=$cd AND c_id=$customer"
        $cursor query "UPDATE customer SET c_balance=c_balance-($amount) WHERE $key"
        set details [select_one $cursor "SELECT c_last,c_first,c_middle,c_street_1,c_street_2,c_city,c_state,c_zip,c_phone,
            c_since,c_credit,c_credit_lim,c_discount,c_balance FROM customer WHERE $key"]
        set data { }
        if {[lindex $details 10] eq "BC"} {
            $cursor query "UPDATE customer SET c_data=SUBSTR(
                '$customer $cd $cw $d $w ' || TO_CHAR($amount,'9999.99') || ' | ' || c_data,1,500) WHERE $key"
            set data [lindex [select_one $cursor "SELECT SUBSTR(c_data,1,200) FROM customer WHERE $key"] 0]
        }
        $cursor query "UPDATE district SET d_ytd=d_ytd+($amount) WHERE d_w_id=$w AND d_id=$d"
        set district [select_one $cursor "SELECT d_street_1,d_street_2,d_city,d_state,d_zip,d_name
            FROM district WHERE d_w_id=$w AND d_id=$d"]
        $cursor query "UPDATE warehouse SET w_ytd=w_ytd+($amount) WHERE w_id=$w"
        set warehouse [select_one $cursor "SELECT w_street_1,w_street_2,w_city,w_state,w_zip,w_name
            FROM warehouse WHERE w_id=$w"]
        set history [literal "[lindex $warehouse 5] [lindex $district 5]"]
        $cursor query "INSERT INTO history (h_c_id,h_c_d_id,h_c_w_id,h_d_id,h_w_id,h_date,h_amount,h_data)
            VALUES ($customer,$cd,$cw,$d,$w,$date,$amount,$history)"
        $cursor query COMMIT
        return [list $customer [lindex $details 0] {*}[lrange $warehouse 0 4] \
            {*}[lrange $district 0 4] {*}[lrange $details 1 end] $data]
    }

    proc ostat {cursor bindings} {
        set w [number [dict get $bindings :OS_W_ID]]
        set d [number [dict get $bindings :OS_D_ID]]
        set customer [customer_id $cursor $w $d [dict get $bindings :OS_C_ID] \
            [dict get $bindings :BYNAME] [dict get $bindings :OS_C_LAST]]
        set details [select_one $cursor "SELECT c_last,c_first,c_middle,c_balance FROM customer
            WHERE c_w_id=$w AND c_d_id=$d AND c_id=$customer"]
        set orders [select_rows $cursor "SELECT o_id,o_entry_d,o_carrier_id FROM
            (SELECT o_id,o_entry_d,o_carrier_id FROM orders WHERE o_w_id=$w AND o_d_id=$d AND o_c_id=$customer
                ORDER BY o_id DESC) WHERE ROWNUM=1"]
        lassign [lindex $orders 0] order date carrier
        if {$order ne {}} {
            set order [number $order]
            select_rows $cursor "SELECT ol_i_id,ol_supply_w_id,ol_quantity,ol_amount,ol_delivery_d
                FROM order_line WHERE ol_w_id=$w AND ol_d_id=$d AND ol_o_id=$order"
        }
        $cursor query COMMIT
        return [list $customer {*}$details $order $date $carrier]
    }

    proc delivery {cursor bindings} {
        set w [number [dict get $bindings :D_W_ID]]
        set carrier [number [dict get $bindings :D_O_CARRIER_ID]]
        set date [timestamp [dict get $bindings :TIMESTAMP]]
        set delivered {}
        for {set d 1} {$d <= 10} {incr d} {
            set order [lindex [select_one $cursor "SELECT MIN(no_o_id) FROM new_order
                WHERE no_w_id=$w AND no_d_id=$d"] 0]
            if {$order eq {}} {continue}
            set order [number $order]
            set deleted [$cursor query "DELETE FROM new_order WHERE no_w_id=$w AND no_d_id=$d AND no_o_id=$order"]
            # Another worker may claim the same order before our DELETE.
            if {$deleted == 1} {lappend delivered [list $d $order]}
        }
        foreach row $delivered {
            lassign $row d order
            $cursor query "UPDATE orders SET o_carrier_id=$carrier WHERE o_w_id=$w AND o_d_id=$d AND o_id=$order"
            set customer [number [lindex [select_one $cursor "SELECT o_c_id FROM orders
                WHERE o_w_id=$w AND o_d_id=$d AND o_id=$order"] 0]]
            $cursor query "UPDATE order_line SET ol_delivery_d=$date WHERE ol_w_id=$w AND ol_d_id=$d AND ol_o_id=$order"
            set total [number [lindex [select_one $cursor "SELECT SUM(ol_amount) FROM order_line
                WHERE ol_w_id=$w AND ol_d_id=$d AND ol_o_id=$order"] 0]]
            $cursor query "UPDATE customer SET c_balance=c_balance+($total)
                WHERE c_w_id=$w AND c_d_id=$d AND c_id=$customer"
        }
        $cursor query COMMIT
        return {}
    }

    proc slev {cursor bindings} {
        set w [number [dict get $bindings :ST_W_ID]]
        set d [number [dict get $bindings :ST_D_ID]]
        set threshold [number [dict get $bindings :THRESHOLD]]
        set result [select_one $cursor "SELECT COUNT(DISTINCT (s_i_id))
            FROM district,order_line,stock WHERE d_w_id=$w AND d_id=$d
                AND d_id=ol_d_id AND d_w_id=ol_w_id AND ol_i_id=s_i_id AND ol_w_id=s_w_id
                AND s_quantity<$threshold AND ol_o_id BETWEEN d_next_o_id-20 AND d_next_o_id-1"]
        $cursor query COMMIT
        return $result
    }
}

package provide oceanbaseoracletpcc 1.0
