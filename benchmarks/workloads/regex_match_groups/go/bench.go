package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
)

func main() {
	n := 3000000
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	// Named capture groups (Go spells them (?P<name>...)), anchored full-match.
	re := regexp.MustCompile(`^(?P<l>[0-9]+)x(?P<w>[0-9]+)x(?P<h>[0-9]+)$`)
	inputs := []string{"2x3x4", "20x3x11", "hello world!"}

	var matched, none, total uint64
	for i := 0; i < n; i++ {
		s := inputs[i%3]
		m := re.FindStringSubmatch(s)
		if m != nil {
			l, _ := strconv.ParseUint(m[1], 10, 64)
			w, _ := strconv.ParseUint(m[2], 10, 64)
			h, _ := strconv.ParseUint(m[3], 10, 64)
			total += l * w * h
			matched++
		} else {
			none++
		}
	}
	fmt.Printf("matched = %d none = %d total = %d\n", matched, none, total)
}
