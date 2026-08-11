# Domain glossary

Shared vocabulary for BetterTile's domain. Terms here name concepts, not Swift
types; code and documentation should use them consistently.

## Window mutation

An operation that changes what the user sees on screen: moving or resizing one
or more windows, or minimizing and restoring them. Multi-window mutations are
all-or-nothing in intent — if part of one fails, the rest is undone.

## Mutation outcome

The terminal meaning of one window mutation. Exactly one outcome describes
exactly one mutation, and nothing about it carries over to the next. A mutation
either **applied**, **failed** (nothing visible changed — every window that had
already moved was returned to where it started), or ended **degraded**.

## Degraded

A mutation failed *and* the attempt to undo it was itself incomplete, so at
least one window was left away from where it started. A degraded desktop is in
an unknown arrangement: automatic corrections stop until the user starts a new
transaction or asks for a repair.
