array set a {x 1 y 2 z 3}
foreach name [lsort [array names a]] {
    puts "$name=$a($name)"
}
incr a(x) 10
puts $a(x)
