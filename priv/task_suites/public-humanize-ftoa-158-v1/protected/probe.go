// Trusted probe. The parent evaluator compares these actual values to frozen JSON.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strconv"

	humanize "github.com/dustin/go-humanize"
)

func main() {
	if len(os.Args) != 2 || strconv.IntSize != 64 {
		os.Exit(47)
	}
	events, err := os.ReadFile(os.Args[1])
	if err != nil || len(events) > 65536 {
		os.Exit(47)
	}
	maxInt := int(^uint(0) >> 1)
	values := []string{
		humanize.FtoaWithDigits(1.25, maxInt),
		humanize.FtoaWithDigits(1.25, maxInt-1),
		humanize.FtoaWithDigits(-1.25, maxInt),
		humanize.FtoaWithDigits(-1.25, maxInt-1),
		humanize.FtoaWithDigits(1234.25, maxInt),
		humanize.FtoaWithDigits(1234.25, maxInt-1),
		humanize.FtoaWithDigits(1.25, 6),
		humanize.FtoaWithDigits(1.25, 7),
		humanize.FtoaWithDigits(1.25, 0),
		humanize.FtoaWithDigits(1.25, 1),
		humanize.FtoaWithDigits(1.25, 2),
		humanize.FtoaWithDigits(-1.25, 0),
		humanize.FtoaWithDigits(-1.25, 1),
		humanize.FtoaWithDigits(0, maxInt),
		humanize.FtoaWithDigits(200, maxInt),
		humanize.FtoaWithDigits(1.25, -1),
		humanize.FtoaWithDigits(1.02, 2),
		humanize.FtoaWithDigits(1.23456789, 6),
	}
	digest := sha256.Sum256(events)
	result := map[string]interface{}{
		"format":             "harnessforge-humanize-ftoa-probe-v1",
		"int_bits":           64,
		"values":             values,
		"tests_run":          []string{"TestFtoa", "TestFtoaWithDigits", "TestFtoaWithDigitsLargeLimit", "TestPilotFixedBoundaries"},
		"test_events_sha256": hex.EncodeToString(digest[:]),
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil {
		os.Exit(47)
	}
}
