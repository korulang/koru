# Koru Syntax

This document describes current Koru syntax as implemented by the compiler and
covered by the regression suite. Passing `.kz` tests remain the executable
source of truth.

## Event Implementations

An event declares an interface: its inputs and possible continuation branches.

```koru
~event process_payment { user_id: u32, amount: u32 }
| success []const u8
| user_not_found
| insufficient_funds
```

An event can be implemented in two different ways. Prefer a subflow
implementation when the event can be expressed by composing other events. Reach
for a `~proc` only when the implementation needs host code, external APIs,
target-specific code, or operations that are not expressible in Koru flow.

### Subflow Implementation

Use `~name = ...` when the implementation is Koru flow. This is the preferred
way to implement an event.

```koru
~process_payment = db.get_user(id: user_id)
| found u |> validate.amount(amount: amount, balance: u.balance)
    | valid |> payment.charge(user_id: u.id, amount: amount)
        | success tx |> success tx
        | failed _ |> insufficient_funds
    | insufficient |> insufficient_funds
| not_found |> user_not_found
```

A subflow implementation has access to the event input fields (`user_id`,
`amount` above) and must resolve into one of the event's declared output
branches.

### Host Proc Implementation

Use `~proc name` when the implementation is host/Zig code.

```koru
~event validate.amount { amount: u32, balance: u32 }
| valid
| insufficient

~proc validate.amount {
    if (amount <= balance) {
        return .{ .valid = .{} };
    } else {
        return .{ .insufficient = .{} };
    }
}
```

The body of `~proc` is host implementation code. It is not Koru flow space.
Do not write Koru flow syntax inside a proc body. If an event should be
implemented by composing other events, use a subflow implementation instead.

### Variant Proc Implementations

Proc variants keep one event interface while allowing multiple host-code
implementations.

```koru
~event compute { input: []f32 }
| done []f32

~proc compute|zig {
    return .{ .done = input };
}

~proc compute|gpu {
    // target-specific host/backend code
    return .{ .done = input };
}
```

This is why variants exist: the event contract remains Koru-level and stable,
while the implementation can vary by target/backend when a subflow is not the
right tool.

### Immediate Subflow Implementation

For simple branch construction, a subflow implementation can immediately return
a branch.

```koru
~event add_one { value: i32 }
| done i32

~add_one = done value + 1
```

For struct-shaped branches:

```koru
~event data { x: i32, y: i32 }
| result { x: i32, y: i32 }

~data = result { x: x, y: y }
```

## Top-Level Flows

Top-level flows invoke events and route continuation branches.

```koru
~process_payment(user_id: 42, amount: 50)
| success tx |> std.io:print.ln(tx)
| user_not_found |> std.io:print.ln("missing user")
| insufficient_funds |> std.io:print.ln("insufficient funds")
```

Inside a continuation, call the next event without a leading `~`.

```koru
~parse(input: "42")
| parsed p |> validate(value: p)
    | valid v |> transform(value: v)
```

The leading `~` starts a top-level flow, subflow implementation, event
declaration, proc declaration, import, annotation-powered form, or test/mock
form depending on context. It is not used before every event call in a pipeline
continuation.
