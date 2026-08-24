set total 0
for {set i 0} {$i < 20} {incr i} {
    if {$i % 2 == 0} { incr total $i }
}
switch $total {
    default { puts "total=$total" }
}
