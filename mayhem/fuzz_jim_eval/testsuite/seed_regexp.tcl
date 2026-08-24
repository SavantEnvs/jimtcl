set s "The quick brown fox jumps 42 times"
if {[regexp {(\d+)} $s -> num]} {
    puts "num=$num"
}
puts [regsub -all {[aeiou]} $s "_"]
