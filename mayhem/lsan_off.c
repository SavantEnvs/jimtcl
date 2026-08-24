/* Build-time LeakSanitizer off-switch (SPEC rule 15): ASan and UBSan stay fully active. */
int __lsan_is_turned_off(void) { return 1; }
