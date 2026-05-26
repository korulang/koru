using System;
using System.Collections.Generic;

class Program {
    static IEnumerable<(int Kind, ulong Value)> Ticker(ulong n) {
        for (ulong i = 0; i < n; i++) {
            if (i % 2 == 0) yield return (0, i);
            else yield return (1, i);
        }
    }

    static void Main(string[] args) {
        ulong n = ulong.Parse(args[0]);
        ulong ticks = 0, tocks = 0;
        foreach (var e in Ticker(n)) {
            if (e.Kind == 0) ticks++;
            else tocks++;
        }
        Console.WriteLine($"ticks = {ticks} tocks = {tocks}");
    }
}
