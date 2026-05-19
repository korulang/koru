# 810s: Expression Syntax

Tests for expression-based flow syntax (design under review).

**Range**: 810-819

## What goes here
- If expressions in flows
- While loops in flows
- Expression composition
- Inline flow expressions

## Core Concepts: Shape Checking
A **shape** in Koru is the structure of data flowing through events. The shape checking system ensures:
1. **Exhaustiveness**: Event continuations must cover all branches.
2. **Structural Equality**: Shapes must match exactly at each pipeline step.
3. **Return Validation**: Proc returns must align with event declarations.

The **Union Collector** builds these shapes from branch constructors: `done { result: x + y }`.
The **Shape Checker** validates the structural correctness before code emission.

## Status
⚠️ Many tests in this range are SKIPPED - expression syntax is under design review.

## Examples
- `810_expression_if` - If/else in flow context
- `811_expression_expr` - General expression handling
- `812_expression_while` - While loops in flows
