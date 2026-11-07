// Trusted probe; actual events and values are compared outside the process.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	utility "example.invalid/holdout/h01"
)

func main() {
	if len(os.Args) != 2 { os.Exit(47) }
	events, err := os.ReadFile(os.Args[1]); if err != nil || len(events) > 49152 { os.Exit(47) }
	digest := sha256.Sum256(events)
	values := []bool{utility.YearIsLeap(1900), utility.YearIsLeap(2000), utility.YearIsLeap(2024), utility.YearIsLeap(2023), utility.YearIsLeap(2100), utility.YearIsLeap(0), utility.YearIsLeap(-100), utility.YearIsLeap(-400), utility.YearIsLeap(-4), utility.YearIsLeap(2400), utility.YearIsLeap(1700), utility.YearIsLeap(1600)}
	result := map[string]interface{}{
		"format": "harnessforge-holdout-go-probe-v1", "package": "example.invalid/holdout/h01",
		"values": values, "tests_run": []string{"TestH01Cases", "TestH01Invariant"},
		"test_events_sha256": hex.EncodeToString(digest[:]), "test_events": string(events),
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil { os.Exit(47) }
}
