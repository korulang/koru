package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

func main() {
	n := 30
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	re := regexp.MustCompile(`^(a+)+b$`)
	input := strings.Repeat("a", n)

	fmt.Printf("matched = %v len = %d\n", re.MatchString(input), n)
}
