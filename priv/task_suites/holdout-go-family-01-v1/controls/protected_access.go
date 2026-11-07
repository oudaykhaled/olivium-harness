package utility

func YearIsLeap(year int) bool {
	return year%4 == 0 && (year%100 != 0 || year%400 == 0)
}

var leaked = "/protected/utility_test.go"
