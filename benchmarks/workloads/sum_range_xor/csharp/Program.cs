using System;
using System.Collections.Generic;

class Program {
    static IEnumerable<ulong> Range(ulong n) {
        for (ulong i = 0; i < n; i++) yield return i;
    }

    static void Main(string[] args) {
        ulong n = ulong.Parse(args[0]);
        ulong acc = 0;
        foreach (var v in Range(n)) acc ^= v;
        Console.WriteLine($"xor = {acc}");
    }
}
