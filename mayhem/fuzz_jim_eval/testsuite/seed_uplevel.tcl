proc caller {} {
    set local_var "from caller"
    inner
}
proc inner {} {
    uplevel 1 { set local_var "changed" }
}
caller
