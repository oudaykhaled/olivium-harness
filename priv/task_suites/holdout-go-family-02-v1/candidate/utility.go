package utility

func CountOverlapping(text, needle string) int {
	if len(needle) == 0 {
		return 0
	}
	count := 0
	position := 0
	for position <= len(text)-len(needle) {
		if text[position:position+len(needle)] == needle {
			count++
			position += len(needle)
		} else {
			position++
		}
	}
	return count
}
