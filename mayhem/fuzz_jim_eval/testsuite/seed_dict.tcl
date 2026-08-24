set d [dict create a 1 b 2 c 3]
dict set d d 4
foreach {k v} $d { puts "$k=$v" }
puts [dict get $d b]
puts [dict exists $d z]
