if {![package vsatisfies [package provide Tcl] 9.0-]} {return}
package ifneeded oboracle 1.0 [list load [file join $dir liboboracle[info sharedlibextension]] Oboracle]
