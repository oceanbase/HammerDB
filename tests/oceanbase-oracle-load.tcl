# Standalone loader tests: no driver or database connection is used.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
source [file join [file dirname [file dirname [file normalize [info script]]]] modules oceanbaseoracleload-1.0.tm]
proc reset_loader {} {
    set ::oceanbaseoracleload::cursors {}
    set ::oceanbaseoracleload::max_rows 1000
    set ::oceanbaseoracleload::max_bytes 1048576
    set ::queries {}
    set ::affected {}
    set ::commits {}
    set ::next_cursor 0
}
proc oraopen {lda} {return c[incr ::next_cursor]}
proc orasql {cursor sql} {
    if {[info exists ::insert_error]} {error $::insert_error}
    lappend ::queries $sql
    set ::rowcount [lindex $::affected 0]
    set ::affected [lrange $::affected 1 end]
}
proc oramsg {args} {return $::rowcount}
proc oracommit {lda} {lappend ::commits [list $lda [llength $::queries]]}
proc oraclose {cursor} {}
test load-values-syntax {Values are quoted once; expressions, NULL and quoted colons survive} -setup {
    reset_loader
    set ::affected 2
} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t (a,b,d,n,s) VALUES (:id,:id2,TO_DATE(:d,'YYYYMMDD'),NULL,':literal')}
    oceanbaseoracleload::bind $c -arraydml :ID {1 2} :id2 [list {O'Reilly),(x} {back\slash $x [text]}] :d {20261019 20261020}
    oceanbaseoracleload::exec $c
    lindex $::queries 0
} -result {INSERT INTO t (a,b,d,n,s) VALUES ('1','O''Reilly),(x',TO_DATE('20261019','YYYYMMDD'),NULL,':literal'),('2','back\slash $x [text]',TO_DATE('20261020','YYYYMMDD'),NULL,':literal')}
test load-scalar-tail {Scalar inserts batch and flush the final row before commit} -setup {
    reset_loader
    set ::affected {2 1}
    set ::oceanbaseoracleload::max_rows 2
} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:v)}
    foreach value {1 2 3} {
        oceanbaseoracleload::bind $c :v $value
        oceanbaseoracleload::exec $c
    }
    set before [llength $::queries]
    oceanbaseoracleload::commit lda
    oceanbaseoracleload::close $c
    list $before $::queries $::commits [dict size $::oceanbaseoracleload::cursors]
} -result {1 {{INSERT INTO t VALUES ('1'),('2')} {INSERT INTO t VALUES ('3')}} {{lda 2}} 0}
test load-array-split {A large array is split without changing its transaction boundary} -setup {
    reset_loader
    set ::affected {2 2 1}
    set ::oceanbaseoracleload::max_rows 2
} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:v)}
    oceanbaseoracleload::bind $c -arraydml :v {1 2 3 4 5}
    oceanbaseoracleload::exec $c
    list $::queries $::commits
} -result {{{INSERT INTO t VALUES ('1'),('2')} {INSERT INTO t VALUES ('3'),('4')} {INSERT INTO t VALUES ('5')}} {}}
test load-byte-limit {Unicode batches respect the byte limit and retain their tail} -setup {
    reset_loader
    set ::affected {1 1}
    set ::oceanbaseoracleload::max_bytes 50
} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:v)}
    oceanbaseoracleload::bind $c -arraydml :v {中文中文 中文中文}
    oceanbaseoracleload::exec $c
    list [llength $::queries] [expr {[string length [encoding convertto utf-8 [lindex $::queries 0]]] <= 50}]
} -result {2 1}
test load-mismatched-arrays {Do not write an incomplete batch} -setup {reset_loader} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:a,:b)}
    oceanbaseoracleload::bind $c -arraydml :a {1 2} :b {3}
} -returnCodes error -match glob -result {*different lengths*}
test load-missing-bind {Fail before writing when a placeholder is missing} -setup {reset_loader} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:a,:b)}
    oceanbaseoracleload::bind $c :a 1
} -returnCodes error -match glob -result {*binding :B*}
test load-affected-rows {A silent partial insert prevents commit} -setup {
    reset_loader
    set ::affected 1
} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:v)}
    oceanbaseoracleload::bind $c -arraydml :v {1 2}
    set failed [catch {oceanbaseoracleload::exec $c} message]
    list $failed $message $::commits
} -result {1 {OceanBase loader inserted 1 rows; expected 2} {}}
test load-insert-error {Database errors reach the loader and no commit is issued} -setup {
    reset_loader
    set ::insert_error {OBE-test insert failed}
} -body {
    set c [oceanbaseoracleload::open lda]
    oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:v)}
    oceanbaseoracleload::bind $c -arraydml :v 1
    list [catch {oceanbaseoracleload::exec $c} message] $message $::commits
} -cleanup {unset ::insert_error} -result {1 {OBE-test insert failed} {}}
test load-independent-connections {Commit flushes only the matching connection} -setup {
    reset_loader
    set ::affected {1 1}
} -body {
    foreach lda {a b} {
        set c [oceanbaseoracleload::open $lda]
        oceanbaseoracleload::parse $c {INSERT INTO t VALUES (:v)}
        oceanbaseoracleload::bind $c :v $lda
        oceanbaseoracleload::exec $c
    }
    oceanbaseoracleload::commit a
    set before $::queries
    oceanbaseoracleload::close $c
    list $before $::queries $::commits
} -result {{{INSERT INTO t VALUES ('a')}} {{INSERT INTO t VALUES ('a')} {INSERT INTO t VALUES ('b')}} {{a 1}}}
set failed $::tcltest::numTests(Failed)
cleanupTests
if {$failed} {error "$failed Oracle loader tests failed"}
