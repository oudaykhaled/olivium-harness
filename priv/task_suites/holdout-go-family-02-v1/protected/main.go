// Trusted probe; actual events and values are compared outside the process.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	utility "example.invalid/holdout/h02"
)

func main() {
	if len(os.Args) != 2 { os.Exit(47) }
	events, err := os.ReadFile(os.Args[1]); if err != nil || len(events) > 49152 { os.Exit(47) }
	digest := sha256.Sum256(events)
	values := []int{utility.CountOverlapping("aaaaa","aa"), utility.CountOverlapping("banana","ana"), utility.CountOverlapping("abababa","aba"), utility.CountOverlapping("abc","abc"), utility.CountOverlapping("abc","abcd"), utility.CountOverlapping("","a"), utility.CountOverlapping("abc",""), utility.CountOverlapping("aAaA","aA"), utility.CountOverlapping("\x00\x00\x00","\x00\x00"), utility.CountOverlapping("ééé","éé"), utility.CountOverlapping("aaaa","a"), utility.CountOverlapping("abc","z")}
	result := map[string]interface{}{
		"format": "harnessforge-holdout-go-probe-v1", "package": "example.invalid/holdout/h02",
		"values": values, "tests_run": []string{"TestH02Cases", "TestH02Invariant"},
		"test_events_sha256": hex.EncodeToString(digest[:]), "test_events": string(events),
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil { os.Exit(47) }
}
