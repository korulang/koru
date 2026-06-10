import re
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 30

pattern = re.compile(r"(a+)+b")
input_str = "a" * n

matched = pattern.fullmatch(input_str) is not None
print(f"matched = {str(matched).lower()} len = {n}")
