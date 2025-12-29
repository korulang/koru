# Event Shapes: Carrying Data

Events aren't just signals—they carry data. This test shows how to define **shapes** for event inputs and outputs.

## The Code

```koru
~event example.write
{
    value: i32,
    note: []const u8,
}
| success {
    written: usize,
}
| failure {
    message: []const u8,
}
```

## Understanding Shapes

### The Input Shape

```koru
{
    value: i32,
    note: []const u8,
}
```

When you trigger `example.write`, you must provide:
- `value`: a 32-bit integer
- `note`: a string slice

### The Branch Shapes

The event has two possible outcomes:

```koru
| success { written: usize }
| failure { message: []const u8 }
```

- **success** returns how many bytes were written
- **failure** returns an error message

## Real-World Analogy

Think of this like an HTTP request:
- **Input**: the request body (what you're sending)
- **success**: a 200 response with data
- **failure**: an error response with a message

## Formatting Note

Notice the opening brace can be on its own line:

```koru
~event example.write
{           // <-- brace on next line is OK
    ...
}
```

This is a parser test—Koru's grammar handles this flexibility.

## What This Enables

With shapes, a proc can:
1. Receive typed, structured input
2. Return different data depending on success or failure
3. Let the caller handle each case appropriately

## What's Next

Later tests show how to write procs that use these shapes and flows that handle the different branches.
