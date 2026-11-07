Repair the behavior of YearIsLeap(year int) bool in /candidate/utility.go.

YearIsLeap reports whether an integer year is a leap year in the proleptic Gregorian calendar: a year divisible by 4 is a leap year, except a year divisible by 100 is not, unless it is also divisible by 400. Apply this divisibility rule to every Go int, including zero and negative years; do not impose a positive-year restriction.

Keep package utility and the exact existing function signature. Edit only utility.go. Implement one pure function with local arithmetic and control flow: no imports, extra functions, global declarations, I/O, concurrency, panic, compiler directives, or protected-test access. The evaluator supports ordinary local assignments and conditions. Do not change go.mod.
