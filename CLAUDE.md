# airdb — API Design & Naming Rules

All code in this repo (new code and refactors) must follow these rules. They govern how we name and shape every public and internal declaration. When an existing name violates a rule, prefer fixing it over matching it.

## Fundamentals

1. **Clarity at the point of use is the top goal.** Judge a name by how a call site reads, not by how the declaration looks. Write the call site first if unsure.
2. **Clarity over brevity.** Never shorten a name at the cost of ambiguity. Terse code is a non-goal; readable code is the goal.
3. **Every public declaration gets a doc comment (`///`).** Start with a single sentence fragment summarizing what the declaration *does* (functions), *is* (types, fields), or *returns* (getters). If a declaration is hard to describe in one sentence, that is a design smell — reconsider the API before documenting around it.
4. **Document complexity when it isn't obvious.** Any function or getter that is not O(1) or that does I/O says so in its doc comment.

## Naming — promote clear usage

5. **Include all the words needed to avoid ambiguity at the call site.** `removeAt(index)` and `remove(member)` mean different things; the name must say which one it is.
6. **Omit needless words.** Don't restate what the parameter or return type already says: `remove(member)` not `removeElement(member)`; `append(node)` not `appendNode(node)`.
7. **Name variables, parameters, and fields by their role, not their type.** `greeting` not `string`; `root` not `node`; `capacity` not `size_u32`. The type already appears in the signature.
8. **Compensate for weak type information.** When a parameter type is `u64`, `[]u8`, `usize`, `anytype`, or `*anyopaque`, the parameter name (and often the function name) must carry the role: `seekToRow(rowId)` not `seek(x)`; `hash(bytes)` not `hash(a)`.

## Naming — strive for fluent usage

9. **Function names form grammatical phrases with their arguments.** Read the call aloud: `list.insert(element, atIndex)` reads; `list.insert(element, positionIndexAfter)` doesn't.
10. **Name functions by their side effects.**
    - Mutating operations read as imperative verbs: `sort()`, `append()`, `compact()`, `free()`.
    - Side-effect-free queries read as nouns or noun phrases: `distance(to)`, `rowCount()`, `header()`.
    - When an operation exists in both forms, pair them: verb for mutating, past/gerund participle for the value-returning form (`sort()`/`sorted()`), or `form`-prefixed verb when the noun form is entrenched (`union()`/`formUnion()`).
11. **Boolean functions and fields read as assertions about the receiver:** `isEmpty`, `isPoisoned`, `contains(key)`, `hasFreeSlot`. Never `empty()`, `checkPoison()`, `getValid()`.
12. **Factory functions that build something other than the receiver's own type start with `make`:** `makeIterator()`, `makeCursor()`. Constructors of a type itself keep Zig's `init` convention.
13. **Types read as nouns** (`Catalog`, `WriteTransaction`, `FreeList`). Non-boolean values and constants read as nouns too.

## Naming — use terminology well

14. **Prefer common words to obscure ones.** Use the ordinary word unless the obscure one is the established term of art.
15. **Use terms of art with their established meaning, and only then.** If the field calls it a "B-tree split", don't call it a "node divide" — and don't call something a "split" if it isn't one.
16. **No abbreviated or single-letter identifiers — spell out full words.** Every variable, parameter, field, function, type, and constant uses complete words that say exactly what it is for: `transaction` not `txn`, `database` not `db`, `primaryKey` not `pk`, `property` not `prop`, `buffer` not `buf`, `allocator` not `al`, `index` not `i`/`idx`, `version` not `ver`. This applies to locals and loop variables too. The only exceptions are things we cannot rename: Zig's builtin slice fields (`.len`, `.ptr`), the frozen C ABI symbols (`airdb_*`, `AIRDB_*`), and industry acronyms that are themselves the term of art (`FFI`, `ABI`, `ID`, `UTF-8`).
17. **Follow precedent over novelty.** If every database calls it a `cursor`, don't invent `walker`.

## Shape & conventions

18. **Prefer namespaced methods to free functions.** A function that conceptually operates on a value of type `T` lives in `T`'s namespace and takes `self`. Free functions are reserved for operations with no obvious receiver or established notation (`min(a, b)`, `hash(bytes)`).
19. **Parameter names are documentation.** Choose them so the doc comment and signature read well together, even for internal functions.
20. **One responsibility per file, one behavior per test.** Files are named after the single abstraction they define.
21. **camelCase everywhere except type names.** Types are `TitleCase`; functions, variables, fields, constants, parameters, file names, and folder names are `camelCase`. No snake_case and no SCREAMING_CASE anywhere in our own code. (Zig's standard library and builtins remain snake_case — `std.mem`, `.len`, `.ptr` — that divergence at interop points is expected and accepted.)
22. **File and folder names spell out full words too.** Rule 16 applies to the file system: `writeTransaction.zig` not `write_txn.zig`, `coordination.zig` not `coord.zig`, `typeDirectory.zig` not `typedir.zig`. Where it clarifies the architecture, group source files into subsystem folders named in full words — don't force a folder on a file that stands alone.
23. **Interfaces are named for the capability they promise, as verb forms.** A type that exists to be implemented and injected (a vtable struct, an `anytype` constraint) takes a verb-derived name — `-ing`/`-able` forms like `Syncing`, `Reporting`, `Comparable`. Concrete types remain nouns (rule 13): the interface says what an implementer *can do*, the concrete type says what it *is*.

## Structure & architecture

24. **Single responsibility, enforced at every level.** A function does one thing; a type has one reason to change; a file holds one abstraction. If describing a unit needs the word "and", split it.
25. **Size limits are review triggers, not style preferences.** A function over ~40 lines gets a hard look; over ~60 it must be decomposed unless it is one irreducible algorithm (say so in its doc comment). A file over ~400 lines of non-test code gets a hard look; over ~600 it must be split into a folder of focused files.
26. **Inline tests stay small; suites move out.** A file may keep a handful of tests for its own invariants. When tests dominate a file's line count, move them to `tests/` mirroring the source path — the abstraction should be readable without scrolling through its test suite.
27. **The dependency rule: inner layers never import outer ones.** Layering, innermost first: platform/storage primitives → indexes & records → transactions & schema → database facade → edges (C API, query surface). An inner file importing an outer one is an architecture bug, not a style issue.
28. **Depend on capabilities, not concretions.** Anything that touches the OS, the file system, or timing goes behind an injected interface (rule 23) — the `Syncing` injection is the model. Business logic must be testable with fakes and no real I/O.
29. **Keep interfaces client-sized.** An interface exposes only what its callers use. If one consumer needs one function, give it a one-function interface rather than the whole surface of a large type.
30. **Extend by adding, not by editing.** Prefer designs where new behavior arrives as a new file/type wired in at the edge (new index kind, new syncing strategy) over growing `switch` ladders inside core files. When a `switch` over kinds appears in more than one place, that's the signal to introduce an interface.
