using System;
using System.Collections.Generic;

class Program {
    static IEnumerable<ulong> Inner(ulong k) {
        for (ulong i = 0; i < k; i++) yield return i;
    }

    static IEnumerable<ulong> Mid(ulong m, ulong k) {
        for (ulong i = 0; i < m; i++) {
            foreach (var _ in Inner(k)) yield return i;
        }
    }

    static IEnumerable<ulong> Outer(ulong n, ulong m, ulong k) {
        for (ulong i = 0; i < n; i++) {
            foreach (var _ in Mid(m, k)) yield return i;
        }
    }

    static void Main(string[] args) {
        ulong n = ulong.Parse(args[0]);
        ulong counter = 0;
        foreach (var _ in Outer(n, n, n)) counter++;
        Console.WriteLine($"counter = {counter}");
    }
}
