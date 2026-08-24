set packed [binary format "Ic2" 1234 "AB"]
binary scan $packed "Ic2" n chars
puts "n=$n chars=$chars"
