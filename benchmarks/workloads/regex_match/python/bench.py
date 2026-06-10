import re
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 3_000_000

email = re.compile(r"[a-z]+@[a-z]+")
number = re.compile(r"[0-9]+")
inputs = ["foo@bar", "12345", "hello world!"]

ce = cn = cx = 0
for i in range(n):
    s = inputs[i % 3]
    if email.fullmatch(s):
        ce += 1
    elif number.fullmatch(s):
        cn += 1
    else:
        cx += 1

print(f"email = {ce} number = {cn} none = {cx}")
