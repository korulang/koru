import std/io
import std/num

// gcd
std/num:nt-gcd(a: "48", b: "36")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad")

// gcd of huge ints
std/num:nt-gcd(a: "123456789012345678901234567890", b: "98765432109876543210")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad")

// extgcd: 240*(-9) + 46*47 = 6
std/num:nt-extgcd(a: "240", b: "46")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad")

// extgcd negative input
std/num:nt-extgcd(a: "-240", b: "46")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad")

// Euclidean divmod: -7 = 3*(-3) + 2
std/num:nt-divmod(a: "-7", b: "3")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| div-by-zero |> std/io:print.ln("dbz")
| bad |> std/io:print.ln("bad")

// Euclidean divmod negative divisor: 7 = (-3)*(-2) + 1
std/num:nt-divmod(a: "7", b: "-3")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| div-by-zero |> std/io:print.ln("dbz")
| bad |> std/io:print.ln("bad")

// div by zero
std/num:nt-divmod(a: "7", b: "0")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| div-by-zero |> std/io:print.ln("dbz")
| bad |> std/io:print.ln("bad")

// mod: -7 mod 3 = 2
std/num:nt-mod(a: "-7", m: "3")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad-modulus |> std/io:print.ln("bm")
| bad |> std/io:print.ln("bad")

// modmul: (7*11) mod 13 = 77 mod 13 = 12
std/num:nt-modmul(a: "7", b: "11", m: "13")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad-modulus |> std/io:print.ln("bm")
| bad |> std/io:print.ln("bad")

// modpow: 3^4 mod 5 = 81 mod 5 = 1
std/num:nt-modpow(a: "3", e: "4", m: "5")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad-modulus |> std/io:print.ln("bm")
| bad |> std/io:print.ln("bad")

// modpow big: 7^128 mod 1000000007
std/num:nt-modpow(a: "7", e: "128", m: "1000000007")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad-modulus |> std/io:print.ln("bm")
| bad |> std/io:print.ln("bad")

// modinv: 3^-1 mod 11 = 4
std/num:nt-modinv(a: "3", m: "11")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| no-inverse g |> std/io:print.ln("ni:{{ g:s }}") |> std/io:free(content: g)
| bad-modulus |> std/io:print.ln("bm")
| bad |> std/io:print.ln("bad")

// modinv non-coprime: 6^-1 mod 10 -> gcd 2
std/num:nt-modinv(a: "6", m: "10")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| no-inverse g |> std/io:print.ln("ni:{{ g:s }}") |> std/io:free(content: g)
| bad-modulus |> std/io:print.ln("bm")
| bad |> std/io:print.ln("bad")

// pow: 2^64
std/num:nt-pow(a: "2", n: 64)
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad")

// pow negative base: (-3)^3
std/num:nt-pow(a: "-3", n: 3)
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad")

// isqrt exact: sqrt(144) = 12
std/num:nt-isqrt(a: "144")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| negative |> std/io:print.ln("neg")
| bad |> std/io:print.ln("bad")

// isqrt inexact: floor(sqrt(145)) = 12
std/num:nt-isqrt(a: "145")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| negative |> std/io:print.ln("neg")
| bad |> std/io:print.ln("bad")

// isqrt negative
std/num:nt-isqrt(a: "-4")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| negative |> std/io:print.ln("neg")
| bad |> std/io:print.ln("bad")

// primality: 97 prime
std/num:nt-is-prime(n: "97")
| prime |> std/io:print.ln("prime")
| probable-prime |> std/io:print.ln("probable")
| composite |> std/io:print.ln("composite")
| bad |> std/io:print.ln("bad")

// 91 = 7*13 composite
std/num:nt-is-prime(n: "91")
| prime |> std/io:print.ln("prime")
| probable-prime |> std/io:print.ln("probable")
| composite |> std/io:print.ln("composite")
| bad |> std/io:print.ln("bad")

// Carmichael 561 -> must say composite (MR catches)
std/num:nt-is-prime(n: "561")
| prime |> std/io:print.ln("prime")
| probable-prime |> std/io:print.ln("probable")
| composite |> std/io:print.ln("composite")
| bad |> std/io:print.ln("bad")

// large prime 2^61-1 (Mersenne, < Jaeschke bound -> deterministic prime)
std/num:nt-is-prime(n: "2305843009213693951")
| prime |> std/io:print.ln("prime")
| probable-prime |> std/io:print.ln("probable")
| composite |> std/io:print.ln("composite")
| bad |> std/io:print.ln("bad")

// large composite: (2^61-1)*(2^31-1)
std/num:nt-is-prime(n: "4951760157141521099596496897")
| prime |> std/io:print.ln("prime")
| probable-prime |> std/io:print.ln("probable")
| composite |> std/io:print.ln("composite")
| bad |> std/io:print.ln("bad")

// factor: 91 -> 7
std/num:nt-factor(n: "91")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| prime |> std/io:print.ln("prime")
| open |> std/io:print.ln("open")
| bad |> std/io:print.ln("bad")

// factor semiprime: 8051 = 83*97 -> small-prime lane hits 83
std/num:nt-factor(n: "8051")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| prime |> std/io:print.ln("prime")
| open |> std/io:print.ln("open")
| bad |> std/io:print.ln("bad")

// factor of a prime -> prime arm
std/num:nt-factor(n: "7919")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| prime |> std/io:print.ln("prime")
| open |> std/io:print.ln("open")
| bad |> std/io:print.ln("bad")

// factor larger semiprime via rho: 1000003*1000033 = 1000036000099
std/num:nt-factor(n: "1000036000099")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| prime |> std/io:print.ln("prime")
| open |> std/io:print.ln("open")
| bad |> std/io:print.ln("bad")

// bad input
std/num:nt-gcd(a: "abc", b: "3")
| exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
| bad |> std/io:print.ln("bad-input")
