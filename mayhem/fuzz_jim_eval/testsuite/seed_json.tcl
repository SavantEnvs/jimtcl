set j {{"a": 1, "b": [1,2,3], "c": {"d": true, "e": null}}}
set obj [json::decode $j]
puts $obj
