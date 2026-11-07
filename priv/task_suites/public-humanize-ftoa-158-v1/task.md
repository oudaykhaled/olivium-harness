# Repair fractional-digit limit overflow

This is a public repository repair exercise derived from dustin/go-humanize.
The supplied file and module are frozen from an actual pre-fix commit.

`FtoaWithDigits(1.25, math.MaxInt)` must return the normal decimal representation
instead of panicking when the requested number of fractional digits exceeds
those available. Preserve ordinary truncation, negative-limit and trailing-zero
behavior. Positive and negative values must both work.

Edit only the body of `stripTrailingDigits` in `ftoa.go`. Preserve its signature,
the imports, package, other functions, module and licence. Do not add files,
initializers, directives, dependencies, tests, extra functions or side effects.
The accepted function subset permits local arithmetic, comparisons, conditions,
string indexing/slicing, `len`, and `strings.Index`; no loops are needed.

Protected behavior checks run separately after the solver stops. Report the
change briefly. No historical-unseen or project-productivity claim is made.
