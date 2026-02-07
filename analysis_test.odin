package llpgen

import "core:testing"

// ヘルパー: 文法をパースしてインデックスを構築する
@(private = "file")
parse_and_build :: proc(input: string) -> (Grammar, bool) {
	g, ok := parse_llp(input)
	if !ok {
		return g, false
	}
	grammar_build_indices(&g)
	return g, true
}

// ========================================================================
// 3.1a: grammar_build_indices テスト
// ========================================================================

@(test)
analysis_build_indices_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Plus Minus
%%
expr : expr Plus term
     | term
     ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	// token_set
	testing.expect(t, "Eof" in g.token_set, "Expected 'Eof' in token_set")
	testing.expect(t, "Number" in g.token_set, "Expected 'Number' in token_set")
	testing.expect(t, "Plus" in g.token_set, "Expected 'Plus' in token_set")
	testing.expect(t, "expr" not_in g.token_set, "'expr' should not be in token_set")

	// rule_map
	testing.expect(t, "expr" in g.rule_map, "Expected 'expr' in rule_map")
	testing.expect(t, "term" in g.rule_map, "Expected 'term' in rule_map")
	testing.expectf(t, g.rule_map["expr"] == 0, "Expected expr index 0, got %d", g.rule_map["expr"])
	testing.expectf(t, g.rule_map["term"] == 1, "Expected term index 1, got %d", g.rule_map["term"])

	// Symbol.kind の確定
	// expr の production 0: expr Plus term
	p0 := g.rules[0].productions[0]
	testing.expectf(t, p0.symbols[0].kind == .Nonterminal, "expr should be Nonterminal, got %v", p0.symbols[0].kind)
	testing.expectf(t, p0.symbols[1].kind == .Terminal, "Plus should be Terminal, got %v", p0.symbols[1].kind)
	testing.expectf(t, p0.symbols[2].kind == .Nonterminal, "term should be Nonterminal, got %v", p0.symbols[2].kind)

	// term の production 0: Number
	tp0 := g.rules[1].productions[0]
	testing.expectf(t, tp0.symbols[0].kind == .Terminal, "Number should be Terminal, got %v", tp0.symbols[0].kind)
}

// ========================================================================
// 3.1b: FIRST 集合テスト
// ========================================================================

@(test)
analysis_first_sets_simple_test :: proc(t: ^testing.T) {
	// term : Number ;
	// → FIRST(term) = { Number }
	input := `%token Eof Number
%%
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	testing.expect(t, "term" in firsts, "Expected 'term' in firsts")
	testing.expect(t, "Number" in firsts["term"], "Expected 'Number' in FIRST(term)")
	testing.expectf(t, len(firsts["term"]) == 1, "Expected 1 element in FIRST(term), got %d", len(firsts["term"]))
}

@(test)
analysis_first_sets_multiple_rules_test :: proc(t: ^testing.T) {
	// expr : expr Plus term | term ;
	// term : Number ;
	// → FIRST(term) = { Number }
	// → FIRST(expr) = { Number } (expr → term → Number)
	input := `%token Eof Number Plus
%%
expr : expr Plus term
     | term
     ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	testing.expect(t, "Number" in firsts["expr"], "Expected 'Number' in FIRST(expr)")
	testing.expect(t, "Number" in firsts["term"], "Expected 'Number' in FIRST(term)")
}

@(test)
analysis_first_sets_with_epsilon_test :: proc(t: ^testing.T) {
	// args : Number | ;  (ε production あり)
	// → FIRST(args) = { Number, ε }
	input := `%token Eof Number
%%
args : Number
     |
     ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	testing.expect(t, "Number" in firsts["args"], "Expected 'Number' in FIRST(args)")
	testing.expect(t, EPSILON_MARKER in firsts["args"], "Expected ε in FIRST(args)")
}

@(test)
analysis_first_sets_calc_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Ident Plus Minus Asterisk Slash Left_Paren Right_Paren Comma
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
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	// FIRST(factor) = { Number, Ident, Left_Paren, Minus }
	testing.expect(t, "Number" in firsts["factor"], "Expected 'Number' in FIRST(factor)")
	testing.expect(t, "Ident" in firsts["factor"], "Expected 'Ident' in FIRST(factor)")
	testing.expect(t, "Left_Paren" in firsts["factor"], "Expected 'Left_Paren' in FIRST(factor)")
	testing.expect(t, "Minus" in firsts["factor"], "Expected 'Minus' in FIRST(factor)")

	// FIRST(term) = FIRST(factor) = { Number, Ident, Left_Paren, Minus }
	testing.expect(t, "Number" in firsts["term"], "Expected 'Number' in FIRST(term)")
	testing.expect(t, "Ident" in firsts["term"], "Expected 'Ident' in FIRST(term)")

	// FIRST(expr) = FIRST(term) = { Number, Ident, Left_Paren, Minus }
	testing.expect(t, "Number" in firsts["expr"], "Expected 'Number' in FIRST(expr)")
	testing.expect(t, "Minus" in firsts["expr"], "Expected 'Minus' in FIRST(expr)")

	// FIRST(args) = { Number, Ident, Left_Paren, Minus, ε }
	testing.expect(t, "Number" in firsts["args"], "Expected 'Number' in FIRST(args)")
	testing.expect(t, EPSILON_MARKER in firsts["args"], "Expected ε in FIRST(args)")
}

// ========================================================================
// 3.1c: FOLLOW 集合テスト
// ========================================================================

@(test)
analysis_follow_sets_simple_test :: proc(t: ^testing.T) {
	// expr : expr Plus term | term ;
	// term : Number ;
	// → FOLLOW(expr) = { Eof, Plus }
	// → FOLLOW(term) = { Eof, Plus }
	input := `%token Eof Number Plus
%%
expr : expr Plus term
     | term
     ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	follows := compute_follow_sets(&g, firsts)
	defer {
		for k, &v in follows {
			delete(v)
		}
		delete(follows)
	}

	// FOLLOW(expr) = { Eof, Plus }
	testing.expect(t, "Eof" in follows["expr"], "Expected 'Eof' in FOLLOW(expr)")
	testing.expect(t, "Plus" in follows["expr"], "Expected 'Plus' in FOLLOW(expr)")

	// FOLLOW(term) = FOLLOW(expr) = { Eof, Plus }
	testing.expect(t, "Eof" in follows["term"], "Expected 'Eof' in FOLLOW(term)")
	testing.expect(t, "Plus" in follows["term"], "Expected 'Plus' in FOLLOW(term)")
}

@(test)
analysis_follow_sets_calc_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Ident Plus Minus Asterisk Slash Left_Paren Right_Paren Comma
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
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	follows := compute_follow_sets(&g, firsts)
	defer {
		for k, &v in follows {
			delete(v)
		}
		delete(follows)
	}

	// FOLLOW(expr) = { Eof, Plus, Minus, Right_Paren, Comma }
	testing.expect(t, "Eof" in follows["expr"], "Expected 'Eof' in FOLLOW(expr)")
	testing.expect(t, "Plus" in follows["expr"], "Expected 'Plus' in FOLLOW(expr)")
	testing.expect(t, "Minus" in follows["expr"], "Expected 'Minus' in FOLLOW(expr)")
	testing.expect(t, "Right_Paren" in follows["expr"], "Expected 'Right_Paren' in FOLLOW(expr)")
	testing.expect(t, "Comma" in follows["expr"], "Expected 'Comma' in FOLLOW(expr)")

	// FOLLOW(term) = { Eof, Plus, Minus, Asterisk, Slash, Right_Paren, Comma }
	testing.expect(t, "Asterisk" in follows["term"], "Expected 'Asterisk' in FOLLOW(term)")
	testing.expect(t, "Slash" in follows["term"], "Expected 'Slash' in FOLLOW(term)")
	testing.expect(t, "Plus" in follows["term"], "Expected 'Plus' in FOLLOW(term)")

	// FOLLOW(factor) = FOLLOW(term) (factor は term の末尾にしか出ない)
	testing.expect(t, "Asterisk" in follows["factor"], "Expected 'Asterisk' in FOLLOW(factor)")
	testing.expect(t, "Eof" in follows["factor"], "Expected 'Eof' in FOLLOW(factor)")

	// FOLLOW(args) = { Right_Paren }
	testing.expect(t, "Right_Paren" in follows["args"], "Expected 'Right_Paren' in FOLLOW(args)")
}

// ========================================================================
// 3.1d: LL(1) 衝突検出テスト
// ========================================================================

@(test)
analysis_ll1_no_conflict_test :: proc(t: ^testing.T) {
	// LL(1) 衝突のない単純な文法
	input := `%token Eof Number Ident
%%
primary : Number
        | Ident
        ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	follows := compute_follow_sets(&g, firsts)
	defer {
		for k, &v in follows {
			delete(v)
		}
		delete(follows)
	}

	conflicts := check_ll1_conflicts(&g, firsts, follows)
	defer delete(conflicts)

	testing.expectf(t, len(conflicts) == 0, "Expected no conflicts, got %d", len(conflicts))
}

@(test)
analysis_ll1_conflict_detection_test :: proc(t: ^testing.T) {
	// 左再帰文法は LL(1) 衝突がある
	// expr : expr Plus term | term ;
	// FIRST(prod0) と FIRST(prod1) が重複 (Numberが両方に含まれる)
	input := `%token Eof Number Plus
%%
expr : expr Plus term
     | term
     ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	follows := compute_follow_sets(&g, firsts)
	defer {
		for k, &v in follows {
			delete(v)
		}
		delete(follows)
	}

	conflicts := check_ll1_conflicts(&g, firsts, follows)
	defer delete(conflicts)

	testing.expectf(t, len(conflicts) > 0, "Expected LL(1) conflicts for left-recursive grammar, got %d", len(conflicts))
	testing.expectf(t, conflicts[0].rule_name == "expr", "Expected conflict in 'expr', got '%s'", conflicts[0].rule_name)
}

// ========================================================================
// 3.1e: 状態生成テスト
// ========================================================================

@(test)
analysis_generate_states_simple_test :: proc(t: ^testing.T) {
	input := `%token Eof Number
%%
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	states := generate_states(&g)
	defer states_destroy(&states)

	// 期待: Term (開始), Term_After_Number (pos=1)
	testing.expectf(t, len(states) == 2, "Expected 2 states, got %d", len(states))
	testing.expectf(t, states[0].name == "Term", "Expected 'Term', got '%s'", states[0].name)
	testing.expectf(t, states[0].pos == 0, "Expected pos 0, got %d", states[0].pos)
	testing.expectf(t, states[1].name == "Term_After_Number", "Expected 'Term_After_Number', got '%s'", states[1].name)
	testing.expectf(t, states[1].pos == 1, "Expected pos 1, got %d", states[1].pos)
}

@(test)
analysis_generate_states_calc_test :: proc(t: ^testing.T) {
	input := `%token Eof Number Plus Minus Asterisk Slash Left_Paren Right_Paren
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
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	states := generate_states(&g)
	defer states_destroy(&states)

	// 全状態にはそれぞれ rule が設定されている
	for &s in states {
		testing.expectf(t, len(s.rule) > 0, "State '%s' should have a rule", s.name)
	}

	// 最低でも各規則の開始状態がある
	found_expr := false
	found_term := false
	found_factor := false
	for &s in states {
		if s.name == "Expr" && s.pos == 0 { found_expr = true }
		if s.name == "Term" && s.pos == 0 { found_term = true }
		if s.name == "Factor" && s.pos == 0 { found_factor = true }
	}
	testing.expect(t, found_expr, "Expected 'Expr' start state")
	testing.expect(t, found_term, "Expected 'Term' start state")
	testing.expect(t, found_factor, "Expected 'Factor' start state")

	// 状態数の確認: 少なくとも 3(開始) + 中間状態
	testing.expectf(t, len(states) >= 3, "Expected at least 3 states, got %d", len(states))
}

@(test)
analysis_generate_states_unique_names_test :: proc(t: ^testing.T) {
	// 同じシンボル名が複数回出現する場合、状態名がユニークであることを確認
	input := `%token Eof Number Plus
%%
expr : expr Plus expr ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	states := generate_states(&g)
	defer states_destroy(&states)

	// 全状態名がユニークか確認
	seen: map[string]bool
	defer delete(seen)
	for &s in states {
		testing.expectf(t, s.name not_in seen, "Duplicate state name: '%s'", s.name)
		seen[s.name] = true
	}
}

// ========================================================================
// 統合テスト: parse → build_indices → first → follow → conflicts → states
// ========================================================================

@(test)
analysis_full_pipeline_test :: proc(t: ^testing.T) {
	input := `%package calc
%token Eof Error Number Ident Plus Minus Asterisk Slash Left_Paren Right_Paren Comma
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
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	follows := compute_follow_sets(&g, firsts)
	defer {
		for k, &v in follows {
			delete(v)
		}
		delete(follows)
	}

	conflicts := check_ll1_conflicts(&g, firsts, follows)
	defer delete(conflicts)
	// 左再帰があるので衝突は0ではない
	testing.expectf(t, len(conflicts) > 0, "Expected conflicts for left-recursive grammar, got %d", len(conflicts))

	states := generate_states(&g)
	defer states_destroy(&states)
	testing.expectf(t, len(states) > 0, "Expected some states, got %d", len(states))

	// 基本的な整合性チェック
	testing.expect(t, g.package_name == "calc", "Expected package 'calc'")
	testing.expectf(t, len(g.tokens) == 11, "Expected 11 tokens, got %d", len(g.tokens))
	testing.expectf(t, len(g.rules) == 4, "Expected 4 rules, got %d", len(g.rules))
}
