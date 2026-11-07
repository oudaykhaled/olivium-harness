package utility

func YearIsLeap(year int) bool {
	println("forged grader result")
	return year%4 == 0 && (year%100 != 0 || year%400 == 0)
}
