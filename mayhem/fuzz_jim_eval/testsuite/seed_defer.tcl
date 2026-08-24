proc withdefer {} {
    defer { puts "cleanup" }
    puts "body"
}
withdefer
