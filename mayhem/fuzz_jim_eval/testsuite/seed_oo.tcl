oo::class create Animal {
    variable name
    method init {n} { set name $n }
    method speak {} { return "I am $name" }
}
set a [Animal new]
$a init "Rex"
puts [$a speak]
