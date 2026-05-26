import sys

def range_gen(n):
    i = 0
    while i < n:
        yield i
        i += 1

def main():
    n = int(sys.argv[1])
    MASK = (1 << 64) - 1
    acc = 0
    for v in range_gen(n):
        if v % 2 == 0:
            acc = (acc + v * v) & MASK
    print(f"result = {acc}")

if __name__ == "__main__":
    main()
