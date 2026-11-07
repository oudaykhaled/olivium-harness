package main

import (
 "encoding/json"
 "os"
 utility "example.invalid/synthetic/reverse_words"
)

func main() {
 values := []string{utility.ReverseWords(""),utility.ReverseWords("  "),utility.ReverseWords("hello"),utility.ReverseWords("hello world"),utility.ReverseWords(" a\tb\nc "),utility.ReverseWords("مرحبا 世界")}
 if err := json.NewEncoder(os.Stdout).Encode(values); err != nil { os.Exit(2) }
}
