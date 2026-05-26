import sys

def range_gen(n):
    i = 0
    while i < n:
        yield i
        i += 1

def main():
    n = int(sys.argv[1])
    a = 0
    for v in range_gen(n):
        a ^= v
    print(f"xor = {a}")

if __name__ == "__main__":
    main()
