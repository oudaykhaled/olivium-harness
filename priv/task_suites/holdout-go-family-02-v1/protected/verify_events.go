// Trusted evaluator. Exact retained run/pass events are required.
package main

import (
	"bufio"
	"encoding/json"
	"os"
)

func reject() { os.Stderr.WriteString("protected_test_execution_unverified\n"); os.Exit(46) }
func main() {
	if len(os.Args) != 2 { reject() }
	file, err := os.Open(os.Args[1]); if err != nil { reject() }; defer file.Close()
	expected := map[string]bool{"TestH02Cases": true, "TestH02Invariant": true}
	run, passed := map[string]int{}, map[string]int{}
	packagePass, lines := 0, 0
	scanner := bufio.NewScanner(file); scanner.Buffer(make([]byte, 4096), 65536)
	for scanner.Scan() {
		lines++; if lines > 128 { reject() }
		var event struct{ Action, Test, Package string }
		if json.Unmarshal(scanner.Bytes(), &event) != nil || event.Package != "example.invalid/holdout/h02" || event.Action == "skip" || event.Action == "fail" { reject() }
		if event.Test != "" {
			if !expected[event.Test] { reject() }
			switch event.Action {
			case "run": run[event.Test]++
			case "pass": passed[event.Test]++
			case "output":
			default: reject()
			}
		} else if event.Action == "pass" { packagePass++ }
	}
	if scanner.Err() != nil || packagePass != 1 { reject() }
	for name := range expected { if run[name] != 1 || passed[name] != 1 { reject() } }
}
