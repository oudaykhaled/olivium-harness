package utility_test

import (
	"testing"
	utility "example.invalid/holdout/h02"
)

func TestH02Cases(t *testing.T) {
	cases := []struct{ text, needle string; want int }{
		{"aaaaa","aa",4},{"banana","ana",2},{"abababa","aba",3},{"abc","abc",1},
		{"abc","abcd",0},{"","a",0},{"abc","",0},{"","",0},{"aAaA","aA",2},
		{"\x00\x00\x00","\x00\x00",2},{"ééé","éé",2},{"aaaa","a",4},{"abc","z",0},
		{"aaaa","aaa",2},{"aaa","aaaa",0},{"\xff\xff\xff","\xff\xff",2},
		{"éé","\xa9\xc3",1},{"AaaA","aa",1},
	}
	for index, item := range cases {
		if got := utility.CountOverlapping(item.text,item.needle); got != item.want { t.Fatalf("case %d: got %d want %d",index,got,item.want) }
	}
}

func TestH02Invariant(t *testing.T) {
	words := []string{""}
	level := []string{""}
	for size := 1; size <= 5; size++ {
		next := []string{}
		for _, prefix := range level { next = append(next,prefix+"a",prefix+"b") }
		words = append(words,next...)
		level = next
	}
	for _, text := range words {
		for _, needle := range words {
			want := 0
			if len(needle) != 0 {
				for start := 0; start <= len(text)-len(needle); start++ {
					matches := true
					for offset := 0; offset < len(needle); offset++ { if text[start+offset] != needle[offset] { matches = false } }
					if matches { want++ }
				}
			}
			if got := utility.CountOverlapping(text,needle); got != want { t.Fatalf("enumerated mismatch lengths %d/%d: got %d want %d",len(text),len(needle),got,want) }
		}
	}
}
