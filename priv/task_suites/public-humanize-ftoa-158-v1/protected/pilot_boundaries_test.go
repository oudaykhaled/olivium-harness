package humanize

import "testing"

func TestPilotFixedBoundaries(t *testing.T) {
	maxInt := int(^uint(0) >> 1)
	cases := []struct {
		number float64
		digits int
		want   string
	}{
		{1.25, maxInt, "1.25"}, {1.25, maxInt - 1, "1.25"},
		{-1.25, maxInt, "-1.25"}, {-1.25, maxInt - 1, "-1.25"},
		{1234.25, maxInt, "1234.25"}, {1234.25, maxInt - 1, "1234.25"},
		{1.25, 6, "1.25"}, {1.25, 7, "1.25"},
		{1.25, 0, "1"}, {1.25, 1, "1.2"}, {1.25, 2, "1.25"},
		{-1.25, 0, "-1"}, {-1.25, 1, "-1.2"},
		{0, maxInt, "0"}, {200, maxInt, "200"}, {1.25, -1, "1"},
		{1.02, 2, "1.02"}, {1.23456789, 6, "1.234568"},
	}
	for _, test := range cases {
		if got := FtoaWithDigits(test.number, test.digits); got != test.want {
			t.Errorf("FtoaWithDigits(%v,%d)=%q; want %q", test.number, test.digits, got, test.want)
		}
	}
}
