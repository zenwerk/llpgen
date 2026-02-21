# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

llpgen is an LL(1) Push Parser Generator written in Odin. It reads a `.llp` grammar DSL file and generates Push Parser code in Odin. The generated parser uses an event-driven architecture where `Parse_Event` callbacks separate parsing mechanics from user AST construction. Users implement `on_parse_event()` to build their own AST.

## Build & Test Commands

```bash
# Build the tool
odin build .

# Run all tests (90 test procedures)
odin test .

# Run a single test by name
odin test . -test-name:<test_name>

# Run the tool
odin run . -- <input.llp> [-o <output.odin>]
```

Output behavior: without `-o`, both parser and token code go to stdout with separator comments. With `-o foo.odin`, generates `foo.odin` (parser) and `foo_token.odin` (token types).

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `grammar.odin` | 108 | Core data structures: `Grammar`, `Rule`, `Production`, `Symbol` |
| `token.odin` | 32 | Token definitions for .llp lexer |
| `lex.odin` | 213 | Lexer for .llp DSL input |
| `parse.odin` | 315 | Recursive descent parser for .llp format |
| `analysis.odin` | 957 | Grammar analysis: indices, FIRST/FOLLOW, conflict detection, state generation |
| `codegen.odin` | 1,246 | Code generation: parser file + token file emission |
| `main.odin` | 224 | CLI entry point, orchestrates the full pipeline |
| `*_test.odin` | 2,590 | 90 tests (lex:13, parse:16, analysis:31, codegen:30) |
| **Total** | **5,685** | |

## Architecture

Single Odin package (`llpgen`) with a 4-phase compiler pipeline:

```
.llp file → Lexer → Parser → Analysis → Code Generation → Odin source
```

### Phase 1: Lexer (`lex.odin`, `token.odin`)
Tokenizes the `.llp` DSL input. Handles directives (`%token`, `%left`, `%right`, `%term`, `%expect_conflict`, `%max_iterations`, etc.), grammar symbols (`:`, `|`, `;`), identifiers, and `%%` section separators.

### Phase 2: Parser (`parse.odin`)
Recursive descent parser for the `.llp` format. Produces a `Grammar` struct (defined in `grammar.odin`) containing tokens, precedence declarations, production rules, and configuration directives.

### Phase 3: Analysis (`analysis.odin`)
- `grammar_build_indices()` — builds `token_set` and `rule_map`, resolves `Symbol_Kind` (Terminal/Nonterminal/Epsilon)
- `check_undefined_symbols()` — detects references to undeclared tokens/rules (fatal error)
- `detect_passthrough_rules()` — finds single-nonterminal delegation rules (e.g., `A : B ;`) for inlining optimization
- `detect_operator_loops()` — identifies `A : A op B | ... | B` left-recursive patterns and marks them for iterative transformation
- `check_left_recursion()` — detects unhandled direct left recursion (fatal error)
- `check_indirect_left_recursion()` — detects cyclic rule dependencies like A→B→C→A (fatal error)
- `compute_first_sets()` / `compute_follow_sets()` — standard LL(1) set computation with fixed-point iteration
- `check_ll1_conflicts()` — detects parse table conflicts (warning, not fatal; suppressible with `%expect_conflict`)
- `check_empty_first_follow()` — warns when FIRST+FOLLOW is empty for a rule
- `generate_states()` — creates `Gen_State` for each parser position (rule × production × dot position)

### Phase 4: Code Generation (`codegen.odin`)
Generates two files:
1. **Parser file** — `Parse_State_Kind` enum, `Parse_Event` enum, `Parse_State` struct (with `user_data: rawptr`), `Parser` struct, `parser_push_token()` dispatch loop, per-rule handler procs
2. **Token file** — `Token_Type` enum, `Pos` struct, `Token` struct, `consumed()` helper, and optionally `is_term()` / `consume_term()` (when `%term` is used)

Key design features:
- **Operator loop transformation**: `A : A op B | B` patterns are automatically converted from left recursion into iterative `for` loops
- **Delegation inlining**: Single-nonterminal rules (e.g., `lambda_expr : pipe_expr ;`) are inlined to reduce state transitions
- **Nonassoc chain detection**: Prevents chaining of `%nonassoc` operators (e.g., `a < b < c` is rejected)
- **Panic mode recovery**: When `%term` tokens are declared, the generated Error state skips tokens until a `%term` token is found

### Pipeline (main.odin)
```
parse_llp()
→ grammar_build_indices()
→ check_undefined_symbols()
→ detect_passthrough_rules()
→ detect_operator_loops()
→ check_left_recursion()
→ check_indirect_left_recursion()
→ compute_first_sets()
→ compute_follow_sets()
→ check_ll1_conflicts()      // with %expect_conflict filtering
→ check_empty_first_follow()
→ generate_states()
→ codegen() / codegen_token()
```

## DSL Format (`.llp`)

```
%package <name>             // output package name
%token_type <type>          // custom token type (default: Token)
%node_type <type>           // custom AST node type (default: Node)
%token <token1> <token2>    // declare terminal tokens
%left <op_tokens>           // left-associative operators (lower line = lower precedence)
%right <op_tokens>          // right-associative operators
%nonassoc <op_tokens>       // non-associative operators
%term <tokens>              // statement separator tokens (enables panic mode error recovery)
%expect_conflict <rule> <n> // suppress up to n LL(1) conflict warnings for rule
%max_iterations <n>         // max iterations in parser_push_token loop (default: 1000)
%%
rule_name : sym1 sym2 sym3
          | sym4 sym5
          |                 // epsilon production (empty alternative)
          ;
%%
```

## Generated Code Structure

**Parser file** (`*_parse.odin`):
- `Parse_State_Kind` enum — all parser states
- `Parse_Event` enum — events for AST construction callbacks
- `Parse_State` struct — state kind, node pointer, `user_data: rawptr`
- `Parser` struct — state stack, root node, error handling, max_iterations
- `parser_new()`, `parser_destroy()`, `parser_begin()`, `parser_end()`
- `parser_push_token()` — main dispatch loop (called per token)
- `parse_<rule>()` — per-rule state machine procs
- `on_parse_event()` — **user must implement** this callback

**Token file** (`*_token.odin`):
- `Token_Type` enum — all declared tokens + `EOF` + `Error`
- `Pos` struct — line/col position
- `Token` struct — type, consumed flag, lexeme, position
- `consumed()` — check and mark token consumed
- `is_term()` / `consume_term()` — only generated when `%term` is declared

## Examples

- **`examples/calc/`** — Simple calculator grammar with `+`, `-`, `*`, `/` and parentheses. Demonstrates basic operator loop transformation and AST building.
- **`examples/streem/`** — Complex real-world grammar with multiple operator precedence levels, control flow, and function definitions.

## Error Handling

**Fatal errors** (exit 1): file read failure, parse failure, undefined symbols, direct left recursion (not transformable to operator loop), indirect left recursion (cyclic rules).

**Warnings** (continue): LL(1) conflicts (suppressible with `%expect_conflict`), empty FIRST+FOLLOW sets.

**Info**: passthrough rule detection, operator loop detection.

## Conventions

- Language: Odin (zero external dependencies, standard library only)
- Naming: `snake_case` for procs/variables, `PascalCase` for types
- Comments: Japanese for inline comments, English acceptable for documentation
- Tests: `*_test.odin` files using `core:testing`, organized by module (lex, parse, analysis, codegen)
- Private helpers: marked with `@(private = "file")`
- `_done/` directory: archived design documents (IMPL_PLAN.md, AST_BUILDER_TODO.md, KAIZEN_PLAN.md, etc.)
