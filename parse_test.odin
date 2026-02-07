package llpgen

import "core:testing"

@(test)
parse_minimal_grammar_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Plus
%%
expr : Number ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success, got error")

	// tokens
	testing.expectf(t, len(g.tokens) == 3, "Expected 3 tokens, got %d", len(g.tokens))
	testing.expectf(t, g.tokens[0] == "Eof", "Expected 'Eof', got '%s'", g.tokens[0])
	testing.expectf(t, g.tokens[1] == "Number", "Expected 'Number', got '%s'", g.tokens[1])
	testing.expectf(t, g.tokens[2] == "Plus", "Expected 'Plus', got '%s'", g.tokens[2])

	// rules
	testing.expectf(t, len(g.rules) == 1, "Expected 1 rule, got %d", len(g.rules))
	testing.expectf(t, g.rules[0].name == "expr", "Expected rule name 'expr', got '%s'", g.rules[0].name)
	testing.expectf(t, len(g.rules[0].productions) == 1, "Expected 1 production, got %d", len(g.rules[0].productions))
	testing.expectf(t, len(g.rules[0].productions[0].symbols) == 1, "Expected 1 symbol, got %d", len(g.rules[0].productions[0].symbols))
	testing.expectf(t, g.rules[0].productions[0].symbols[0].name == "Number",
		"Expected symbol 'Number', got '%s'", g.rules[0].productions[0].symbols[0].name)

	// start_rule
	testing.expectf(t, g.start_rule == "expr", "Expected start_rule 'expr', got '%s'", g.start_rule)
}

@(test)
parse_multiple_alternatives_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Plus Minus
%left Plus Minus
%%
expr : expr Plus expr
     | expr Minus expr
     | Number
     ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")

	// tokens
	testing.expectf(t, len(g.tokens) == 4, "Expected 4 tokens, got %d", len(g.tokens))

	// precedence
	testing.expectf(t, len(g.precedence) == 1, "Expected 1 precedence entry, got %d", len(g.precedence))
	testing.expectf(t, g.precedence[0].assoc == .Left, "Expected Left assoc, got %v", g.precedence[0].assoc)
	testing.expectf(t, g.precedence[0].level == 1, "Expected level 1, got %d", g.precedence[0].level)
	testing.expectf(t, len(g.precedence[0].tokens) == 2, "Expected 2 prec tokens, got %d", len(g.precedence[0].tokens))
	testing.expectf(t, g.precedence[0].tokens[0] == "Plus", "Expected 'Plus', got '%s'", g.precedence[0].tokens[0])
	testing.expectf(t, g.precedence[0].tokens[1] == "Minus", "Expected 'Minus', got '%s'", g.precedence[0].tokens[1])

	// rules
	testing.expectf(t, len(g.rules) == 1, "Expected 1 rule, got %d", len(g.rules))
	testing.expectf(t, g.rules[0].name == "expr", "Expected rule name 'expr'")
	testing.expectf(t, len(g.rules[0].productions) == 3, "Expected 3 productions, got %d", len(g.rules[0].productions))

	// production 0: expr Plus expr
	p0 := g.rules[0].productions[0]
	testing.expectf(t, len(p0.symbols) == 3, "Prod 0: expected 3 symbols, got %d", len(p0.symbols))
	testing.expectf(t, p0.symbols[0].name == "expr", "Prod 0[0]: expected 'expr', got '%s'", p0.symbols[0].name)
	testing.expectf(t, p0.symbols[1].name == "Plus", "Prod 0[1]: expected 'Plus', got '%s'", p0.symbols[1].name)
	testing.expectf(t, p0.symbols[2].name == "expr", "Prod 0[2]: expected 'expr', got '%s'", p0.symbols[2].name)

	// production 1: expr Minus expr
	p1 := g.rules[0].productions[1]
	testing.expectf(t, len(p1.symbols) == 3, "Prod 1: expected 3 symbols, got %d", len(p1.symbols))
	testing.expectf(t, p1.symbols[1].name == "Minus", "Prod 1[1]: expected 'Minus', got '%s'", p1.symbols[1].name)

	// production 2: Number
	p2 := g.rules[0].productions[2]
	testing.expectf(t, len(p2.symbols) == 1, "Prod 2: expected 1 symbol, got %d", len(p2.symbols))
	testing.expectf(t, p2.symbols[0].name == "Number", "Prod 2[0]: expected 'Number', got '%s'", p2.symbols[0].name)
}

@(test)
parse_multiple_rules_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Plus Minus Asterisk Slash Left_Paren Right_Paren
%left Plus Minus
%left Asterisk Slash
%%
expr : expr Plus term
     | expr Minus term
     | term
     ;
term : term Asterisk factor
     | term Slash factor
     | factor
     ;
factor : Number
       | Left_Paren expr Right_Paren
       ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")

	// tokens
	testing.expectf(t, len(g.tokens) == 8, "Expected 8 tokens, got %d", len(g.tokens))

	// precedence
	testing.expectf(t, len(g.precedence) == 2, "Expected 2 precedence entries, got %d", len(g.precedence))
	testing.expectf(t, g.precedence[0].level == 1, "Expected level 1 for Plus/Minus")
	testing.expectf(t, g.precedence[1].level == 2, "Expected level 2 for Asterisk/Slash")

	// rules
	testing.expectf(t, len(g.rules) == 3, "Expected 3 rules, got %d", len(g.rules))
	testing.expectf(t, g.rules[0].name == "expr", "Expected rule 0 'expr', got '%s'", g.rules[0].name)
	testing.expectf(t, g.rules[1].name == "term", "Expected rule 1 'term', got '%s'", g.rules[1].name)
	testing.expectf(t, g.rules[2].name == "factor", "Expected rule 2 'factor', got '%s'", g.rules[2].name)

	// start_rule
	testing.expectf(t, g.start_rule == "expr", "Expected start_rule 'expr', got '%s'", g.start_rule)

	// expr: 3 productions
	testing.expectf(t, len(g.rules[0].productions) == 3, "expr: expected 3 productions, got %d", len(g.rules[0].productions))

	// term: 3 productions
	testing.expectf(t, len(g.rules[1].productions) == 3, "term: expected 3 productions, got %d", len(g.rules[1].productions))

	// factor: 2 productions
	testing.expectf(t, len(g.rules[2].productions) == 2, "factor: expected 2 productions, got %d", len(g.rules[2].productions))

	// factor production 1: Left_Paren expr Right_Paren
	fp1 := g.rules[2].productions[1]
	testing.expectf(t, len(fp1.symbols) == 3, "factor prod 1: expected 3 symbols, got %d", len(fp1.symbols))
	testing.expectf(t, fp1.symbols[0].name == "Left_Paren", "Expected 'Left_Paren', got '%s'", fp1.symbols[0].name)
	testing.expectf(t, fp1.symbols[1].name == "expr", "Expected 'expr', got '%s'", fp1.symbols[1].name)
	testing.expectf(t, fp1.symbols[2].name == "Right_Paren", "Expected 'Right_Paren', got '%s'", fp1.symbols[2].name)
}

@(test)
parse_package_directive_test :: proc(t: ^testing.T) {
	input := `%package calc
%token Eof Number
%%
expr : Number ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, g.package_name == "calc", "Expected package 'calc', got '%s'", g.package_name)
}

@(test)
parse_term_directive_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Newline Semicolon
%term Newline Semicolon
%%
expr : Number ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, len(g.term_tokens) == 2, "Expected 2 term tokens, got %d", len(g.term_tokens))
	testing.expectf(t, g.term_tokens[0] == "Newline", "Expected 'Newline', got '%s'", g.term_tokens[0])
	testing.expectf(t, g.term_tokens[1] == "Semicolon", "Expected 'Semicolon', got '%s'", g.term_tokens[1])
}

@(test)
parse_empty_production_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Comma
%%
args : Number
     | args Comma Number
     |
     ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, len(g.rules) == 1, "Expected 1 rule, got %d", len(g.rules))
	testing.expectf(t, len(g.rules[0].productions) == 3, "Expected 3 productions, got %d", len(g.rules[0].productions))

	// 3番目の production は空 (ε)
	p2 := g.rules[0].productions[2]
	testing.expectf(t, len(p2.symbols) == 0, "Expected empty production (ε), got %d symbols", len(p2.symbols))
}

@(test)
parse_nonassoc_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Eq
%nonassoc Eq
%%
expr : Number ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, len(g.precedence) == 1, "Expected 1 precedence entry, got %d", len(g.precedence))
	testing.expectf(t, g.precedence[0].assoc == .None, "Expected None assoc, got %v", g.precedence[0].assoc)
}

@(test)
parse_right_assoc_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Assign
%right Assign
%%
expr : Number ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, len(g.precedence) == 1, "Expected 1 precedence entry, got %d", len(g.precedence))
	testing.expectf(t, g.precedence[0].assoc == .Right, "Expected Right assoc, got %v", g.precedence[0].assoc)
}

@(test)
parse_no_trailing_separator_test :: proc(t: ^testing.T) {
	// 末尾の %% なしでも OK
	input := `%token Eof Number
%%
expr : Number ;`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, len(g.rules) == 1, "Expected 1 rule, got %d", len(g.rules))
}

@(test)
parse_comments_in_grammar_test :: proc(t: ^testing.T) {
	input := `// header comment
%token Eof Number Plus
// precedence
%left Plus
%%
// rules
expr : Number  // single number
     | expr Plus expr
     ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")
	testing.expectf(t, len(g.rules) == 1, "Expected 1 rule, got %d", len(g.rules))
	testing.expectf(t, len(g.rules[0].productions) == 2, "Expected 2 productions, got %d", len(g.rules[0].productions))
}

@(test)
parse_calc_llp_test :: proc(t: ^testing.T) {
	// IMPL_TODO.md の calc.llp 相当
	input := `%package calc

%token Eof Error
%token Number Ident
%token Plus Minus Asterisk Slash
%token Left_Paren Right_Paren
%token Comma

%left Plus Minus
%left Asterisk Slash

%%
expr : expr Plus term
     | expr Minus term
     | term
     ;

term : term Asterisk factor
     | term Slash factor
     | factor
     ;

factor : Number
       | Ident Left_Paren args Right_Paren
       | Left_Paren expr Right_Paren
       | Minus factor
       ;

args : expr
     | args Comma expr
     |
     ;
%%`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)

	testing.expectf(t, ok, "Expected parse success")

	// package
	testing.expectf(t, g.package_name == "calc", "Expected package 'calc', got '%s'", g.package_name)

	// tokens: Eof, Error, Number, Ident, Plus, Minus, Asterisk, Slash, Left_Paren, Right_Paren, Comma = 11
	testing.expectf(t, len(g.tokens) == 11, "Expected 11 tokens, got %d", len(g.tokens))

	// precedence: 2 levels
	testing.expectf(t, len(g.precedence) == 2, "Expected 2 precedence levels, got %d", len(g.precedence))

	// rules: expr, term, factor, args = 4
	testing.expectf(t, len(g.rules) == 4, "Expected 4 rules, got %d", len(g.rules))
	testing.expectf(t, g.rules[0].name == "expr", "Rule 0: expected 'expr', got '%s'", g.rules[0].name)
	testing.expectf(t, g.rules[1].name == "term", "Rule 1: expected 'term', got '%s'", g.rules[1].name)
	testing.expectf(t, g.rules[2].name == "factor", "Rule 2: expected 'factor', got '%s'", g.rules[2].name)
	testing.expectf(t, g.rules[3].name == "args", "Rule 3: expected 'args', got '%s'", g.rules[3].name)

	// expr: 3 productions
	testing.expectf(t, len(g.rules[0].productions) == 3, "expr: expected 3 prods, got %d", len(g.rules[0].productions))

	// term: 3 productions
	testing.expectf(t, len(g.rules[1].productions) == 3, "term: expected 3 prods, got %d", len(g.rules[1].productions))

	// factor: 4 productions (Number, Ident(...), (expr), -factor)
	testing.expectf(t, len(g.rules[2].productions) == 4, "factor: expected 4 prods, got %d", len(g.rules[2].productions))

	// args: 3 productions (expr, args Comma expr, ε)
	testing.expectf(t, len(g.rules[3].productions) == 3, "args: expected 3 prods, got %d", len(g.rules[3].productions))

	// args last production is ε (empty)
	args_last := g.rules[3].productions[2]
	testing.expectf(t, len(args_last.symbols) == 0, "args ε prod: expected 0 symbols, got %d", len(args_last.symbols))

	// factor production 3: Minus factor
	f3 := g.rules[2].productions[3]
	testing.expectf(t, len(f3.symbols) == 2, "factor prod 3: expected 2 symbols, got %d", len(f3.symbols))
	testing.expectf(t, f3.symbols[0].name == "Minus", "Expected 'Minus', got '%s'", f3.symbols[0].name)
	testing.expectf(t, f3.symbols[1].name == "factor", "Expected 'factor', got '%s'", f3.symbols[1].name)

	// start_rule
	testing.expectf(t, g.start_rule == "expr", "Expected start_rule 'expr', got '%s'", g.start_rule)
}

@(test)
parse_error_missing_colon_test :: proc(t: ^testing.T) {
	input := `%token Eof Number
%%
expr Number ;`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)
	testing.expect(t, !ok, "Expected parse failure for missing colon")
}

@(test)
parse_error_missing_semicolon_test :: proc(t: ^testing.T) {
	input := `%token Eof Number
%%
expr : Number`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)
	testing.expect(t, !ok, "Expected parse failure for missing semicolon")
}

@(test)
parse_error_missing_separator_test :: proc(t: ^testing.T) {
	input := `%token Eof Number
expr : Number ;`
	g, ok := parse_llp(input)
	defer grammar_destroy(&g)
	testing.expect(t, !ok, "Expected parse failure for missing %% separator")
}
