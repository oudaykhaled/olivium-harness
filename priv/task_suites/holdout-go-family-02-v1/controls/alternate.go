package utility

func CountOverlapping(text, needle string) int {
	if len(needle) == 0 || len(needle) > len(text) {
		return 0
	}
	count := 0
	for start := 0; start <= len(text)-len(needle); start++ {
		matched := true
		for offset := 0; offset < len(needle); offset++ {
			if text[start+offset] != needle[offset] {
				matched = false
			}
		}
		if matched {
			count++
		}
	}
	return count
}
