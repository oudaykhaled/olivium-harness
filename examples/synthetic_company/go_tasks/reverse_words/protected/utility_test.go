package utility
import "testing"
func TestReverseWords(t *testing.T) {
 for _, c := range []struct{name, input, want string}{
  {"empty", "", ""}, {"spaces", "  ", ""}, {"single", "hello", "hello"},
  {"normal", "hello world", "world hello"}, {"whitespace", " a\tb\nc ", "c b a"},
  {"unicode", "مرحبا 世界", "世界 مرحبا"},
 } { t.Run(c.name,func(t *testing.T){ if got := ReverseWords(c.input); got != c.want { t.Fatalf("got %q want %q",got,c.want) } }) }
}
