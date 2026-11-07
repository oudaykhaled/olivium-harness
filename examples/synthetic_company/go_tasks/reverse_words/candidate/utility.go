package utility

import "strings"

// ReverseWords reverses whitespace-delimited words and joins them with single spaces.
func ReverseWords(input string) string { return strings.Join(strings.Fields(input), " ") }
