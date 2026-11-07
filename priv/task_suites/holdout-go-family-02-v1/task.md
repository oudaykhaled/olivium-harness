Repair the behavior of CountOverlapping(text, needle string) int in /candidate/utility.go.

CountOverlapping returns the number of starting byte offsets in text at which the complete literal byte sequence needle occurs. Matches may overlap, so every matching starting offset counts. Return zero for an empty needle, an empty text, or a needle longer than text. Matching is exact and case sensitive; treat Go strings as byte sequences, without Unicode normalization or rune conversion. The result must work for arbitrary string bytes, including zero bytes and UTF-8 strings.

Keep package utility and the exact existing function signature. Edit only utility.go. Implement one pure function with local variables, len, string indexing or slicing, arithmetic, conditions and ordinary for loops: no imports, extra functions, global declarations, I/O, concurrency, panic, compiler directives, or protected-test access. Do not change go.mod.
