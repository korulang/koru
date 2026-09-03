// A terminal declared in an imported module is visible to compounds declared
// in the entry file. This is the declaration-layer half of module-spaced
// identity: the program scanner finds the terminal across the merged program
// whether it is still live or already erased to its marker.
import std/proto

std/proto:float(Health)
