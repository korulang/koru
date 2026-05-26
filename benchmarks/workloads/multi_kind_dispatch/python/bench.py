import sys

def ticker(n):
    i = 0
    while i < n:
        if i % 2 == 0:
            yield ('tick', i)
        else:
            yield ('tock', i)
        i += 1

def main():
    n = int(sys.argv[1])
    ticks = 0
    tocks = 0
    for kind, _v in ticker(n):
        if kind == 'tick':
            ticks += 1
        else:
            tocks += 1
    print(f"ticks = {ticks} tocks = {tocks}")

if __name__ == "__main__":
    main()
