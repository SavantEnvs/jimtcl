set l [list a b c d e]
lappend l f
puts [lsort -decreasing $l]
puts [lindex $l 2]
puts [llength $l]
foreach item $l { puts $item }
