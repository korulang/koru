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

	email := regexp.MustCompile(`^[a-z]+@[a-z]+$`)
	number := regexp.MustCompile(`^[0-9]+$`)
	inputs := []string{"foo@bar", "12345", "hello world!"}

	var ce, cn, cx uint64
	for i := 0; i < n; i++ {
		s := inputs[i%3]
		if email.MatchString(s) {
			ce++
		} else if number.MatchString(s) {
			cn++
		} else {
			cx++
		}
	}
	fmt.Printf("email = %d number = %d none = %d\n", ce, cn, cx)
}
