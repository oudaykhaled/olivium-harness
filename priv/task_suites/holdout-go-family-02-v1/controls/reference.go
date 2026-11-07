package utility

func CountOverlapping(text, needle string) int {
	if len(needle) == 0 {
		return 0
	}
	count := 0
	for position := 0; position <= len(text)-len(needle); position++ {
		if text[position:position+len(needle)] == needle {
			count++
		}
	}
	return count
}
