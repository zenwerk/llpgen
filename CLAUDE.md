# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

llpgen is an LL(1) Push Parser Generator written in Odin. It reads a `.llp` grammar DSL file and generates Push Parser code in Odin. The generated parser uses an event-driven architecture where parse events are emitted for AST construction via user-implemented callbacks.

## Build & Test Commands

```bash
# Build the tool
odin build .

# Run all tests (~70 test procedures)
odin test .

# Run a single test by name
odin test . -test-name:<test_name>

# Run the tool
odin run . -- <input.llp> [-o <output.odin>]
```

Output behavior: without `-o`, both parser and token code go to stdout with separator comments. With `-o foo.odin`, generates `foo.odin` (parser) and `foo_token.odin` (token types).

## Architecture

Single Odin package (`llpgen`) with a 4-phase compiler pipeline:

```
.llp file → Lexer → Parser → Analysis → Code Generation → Odin source
```

### Phase 1: Lexer (`lex.odin`, `token.odin`)
Tokenizes the `.llp` DSL input. Handles directives (`%token`, `%left`, `%right`, etc.), grammar symbols (`:`, `|`, `;`), identifiers, and `%%` section separators.

### Phase 2: Parser (`parse.odin`)
Recursive descent parser for the `.llp` format. Produces a `Grammar` struct (defined in `grammar.odin`) containing tokens, precedence declarations, and production rules.

### Phase 3: Analysis (`analysis.odin`)
- `grammar_build_indices()` — builds token_set and rule_map, resolves symbol kinds
- `detect_operator_loops()` — identifies `A : A op B | ... | B` left-recursive patterns and marks them for iterative transformation
- `check_left_recursion()` — detects unhandled direct left recursion (fatal error)
- `compute_first_sets()` / `compute_follow_sets()` — standard LL(1) set computation with fixed-point iteration
- `check_ll1_conflicts()` — detects parse table conflicts (warning, not fatal)
- `generate_states()` — creates `Gen_State` for each parser position (rule × production × dot position)

### Phase 4: Code Generation (`codegen.odin`)
Generates two files:
1. **Parser file** — `Parse_State_Kind` enum, `Parse_Event` enum, parser struct, `parser_push_token()` dispatch loop, per-rule handler procs
2. **Token file** — token type enum for the target package

Key design: operator loop rules (`A : A op B | B`) are automatically transformed from left recursion into iterative `for` loops in the generated parser code.

### Data Flow Through main.odin
`parse_llp()` → `grammar_build_indices()` → `detect_operator_loops()` → `check_left_recursion()` → `compute_first_sets()` → `compute_follow_sets()` → `check_ll1_conflicts()` → `generate_states()` → `codegen()` / `codegen_token()`

## DSL Format (`.llp`)

```
%package <name>
%token_type <type>
%node_type <type>
%token <token1> <token2> ...
%left <op_tokens>        // left-associative operators (lower line = lower precedence)
%right <op_tokens>       // right-associative operators
%nonassoc <op_tokens>
%term <tokens>           // terminal-only tokens
%%
rule : sym1 sym2 | sym3 ;
%%
```

Working example: `examples/calc/` contains a calculator grammar with generated parser and test harness.

## Conventions

- Language: Odin (zero external dependencies, standard library only)
- Naming: snake_case for procs/variables, PascalCase for types
- Comments: Japanese for inline comments, English acceptable for documentation
- Tests: `*_test.odin` files using `core:testing`, organized by module (lex, parse, analysis, codegen)
- Private helpers: marked with `@(private = "file")`
- `_done/` directory: archived design documents (IMPL_PLAN.md, AST_BUILDER_TODO.md, etc.)
