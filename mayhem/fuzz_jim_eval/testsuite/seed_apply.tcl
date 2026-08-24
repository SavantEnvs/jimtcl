set sq [lambda {x} {expr {$x * $x}}]
puts [apply $sq 7]
set f [list apply {{a b} {expr {$a + $b}}}]
puts [{*}$f 3 4]
