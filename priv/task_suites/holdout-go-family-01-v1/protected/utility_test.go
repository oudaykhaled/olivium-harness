package utility_test

import (
	"testing"
	utility "example.invalid/holdout/h01"
)

func TestH01Cases(t *testing.T) {
	cases := []struct{ year int; want bool }{
		{1900,false},{2000,true},{2024,true},{2023,false},{2100,false},
		{0,true},{-100,false},{-400,true},{-4,true},{2400,true},{1700,false},{1600,true},
		{1,false},{4,true},{100,false},{400,true},{-1,false},{-200,false},{-800,true},
	}
	for _, item := range cases {
		if got := utility.YearIsLeap(item.year); got != item.want { t.Fatalf("case %d: got %v want %v", item.year,got,item.want) }
	}
}

func TestH01Invariant(t *testing.T) {
	for year := -5000; year <= 5000; year++ {
		want := year%400 == 0 || year%100 != 0 && year%4 == 0
		if got := utility.YearIsLeap(year); got != want { t.Fatalf("year %d: got %v want %v",year,got,want) }
		if utility.YearIsLeap(year) != utility.YearIsLeap(year+400) { t.Fatalf("period mismatch at %d",year) }
	}
	max := int(^uint(0)>>1)
	for _, year := range []int{max,max-1,max-2,max-3,-max-1,-max,-max+1,-max+2} {
		want := year%400 == 0 || year%100 != 0 && year%4 == 0
		if utility.YearIsLeap(year) != want { t.Fatalf("integer boundary mismatch") }
	}
}
