package main

import (
 "encoding/json"
 "os"
 utility "example.invalid/synthetic/clamp"
)

func main() {
 values := []int{utility.Clamp(3,1,5),utility.Clamp(-2,1,5),utility.Clamp(8,1,5),utility.Clamp(9,4,4),utility.Clamp(-9,-5,-1)}
 if err := json.NewEncoder(os.Stdout).Encode(values); err != nil { os.Exit(2) }
}
