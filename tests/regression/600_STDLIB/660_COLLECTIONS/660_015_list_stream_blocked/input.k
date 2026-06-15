// RED PIN — the list instance of the root effect/obligation bug (see
// 630_002_effect_under_obligation_drops_output). Streaming into a list via
// read-lines drops all output, because read-lines is nested under the
// obligation-carrying `| list xs` (<list!>) branch — the same failure as
// nesting it under String<view!>. NOT a list-specific or capture-shaping issue:
// it is the shared defect in how the obligation/auto-discharge machinery
// composes with a nested effect. Goes green when 630_002's root is fixed; this
// then unblocks the canonical AoC "stream input into a collection" pattern.
import std/io
import std/fs
import std/list

std/list:new-i64()
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> std/io:print.ln("done") |> std/list:free(xs)
    | failed _ |> std/io:print.ln("failed") |> std/list:free(xs)
| err _ |> std/io:print.ln("err")
