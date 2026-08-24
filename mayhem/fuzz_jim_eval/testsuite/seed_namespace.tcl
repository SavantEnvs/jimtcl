namespace eval foo {
    variable counter 0
    proc bump {} {
        variable counter
        incr counter
        return $counter
    }
}
puts [foo::bump]
puts [foo::bump]
