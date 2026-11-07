package utility
import "testing"
func TestClamp(t *testing.T) {
 for _, c := range []struct{name string; value, lo, hi, want int}{
  {"inside", 3, 1, 5, 3}, {"below", -2, 1, 5, 1},
  {"above", 8, 1, 5, 5}, {"equal bounds", 9, 4, 4, 4},
  {"negative", -9, -5, -1, -5},
 } { t.Run(c.name, func(t *testing.T) { if got := Clamp(c.value,c.lo,c.hi); got != c.want { t.Fatalf("got %d want %d",got,c.want) } }) }
}
