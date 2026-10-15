# Invoked by oracle-tls-wire.py against a local protocol fixture, never a real DB.
set argv {}
set ssl [list -ssl true -library $::env(HDB_TLS_LIBRARY)]
foreach {key envname} {-sslca HDB_TLS_CA -sslcapath HDB_TLS_CAPATH -sslcert HDB_TLS_CERT -sslkey HDB_TLS_KEY -sslcipher HDB_TLS_CIPHER} {
    if {[info exists ::env($envname)] && $::env($envname) ne ""} {dict set ssl $key $::env($envname)}
}
set settings [list unused $::env(HDB_TLS_HOST) $::env(HDB_TLS_PORT) {} {} {} tlsuser]
oceanbaseoraclecommon::configure $settings 10 $ssl
# Repeated worker initialization must agree with the process-wide policy.
::hdbobcitls::configure [dict remove $ssl -library]
if {![catch {::hdbobcitls::configure [dict replace [dict remove $ssl -library] -sslcipher changed-after-init]}]} {
    error {The TLS client accepted a policy change after initialization}
}
# The protocol fixture deliberately rejects authentication after inspecting TLS.
if {[info exists ::env(HDB_TLS_WORKERS)] && $::env(HDB_TLS_WORKERS) > 1} {
    set threads {}
    for {set worker 0} {$worker < $::env(HDB_TLS_WORKERS)} {incr worker} {
        lappend threads [thread::create -joinable [list apply {{paths packages settings ssl} {
            set ::auto_path $packages
            ::tcl::tm::path add {*}$paths
            if {[catch {
                package require oceanbaseoraclecommon
                oceanbaseoraclecommon::configure $settings 10 $ssl
            } message options]} {
                puts stderr "TLS_WORKER_ERROR: $message"
                return -options $options $message
            }
            if {![catch {oceanbaseoraclecommon::connect tlsuser tls-fixture-password}]} {
                error {The TLS fixture unexpectedly authenticated a worker}
            }
        }} [::tcl::tm::path list] $::auto_path $settings $ssl]]
    }
    foreach thread $threads {if {[thread::join $thread] != 0} {error {TLS worker failed}}}
} else {
    if {![catch {oceanbaseoraclecommon::connect tlsuser tls-fixture-password} message]} {
        error {The local TLS fixture unexpectedly authenticated a database user}
    }
}
puts TLS_FIXTURE_CONNECT_REJECTED
exit
