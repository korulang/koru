import sys

def range_gen(n):
    i = 0
    while i < n:
        yield i
        i += 1

def main():
    n = int(sys.argv[1])
    s = 0
    for v in range_gen(n):
        s = (s + v) & 0xFFFFFFFFFFFFFFFF
    print(f"sum = {s}")

if __name__ == "__main__":
    main()
