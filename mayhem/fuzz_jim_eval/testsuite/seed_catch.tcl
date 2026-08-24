if {[catch {expr {1/0}} err]} {
    puts "caught: $err"
}
catch {error "custom error" info extra} rc
puts "rc=$rc"
