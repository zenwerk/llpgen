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
	defer ll1_conflicts_destroy(&conflicts)

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
	defer ll1_conflicts_destroy(&conflicts)

	testing.expectf(t, len(conflicts) > 0, "Expected LL(1) conflicts for left-recursive grammar, got %d", len(conflicts))
	testing.expectf(t, conflicts[0].rule_name == "expr", "Expected conflict in 'expr', got '%s'", conflicts[0].rule_name)
}

@(test)
analysis_ll1_conflict_grouped_test :: proc(t: ^testing.T) {
	// 同じ (rule, prod_i, prod_j) ペアで複数トークンが衝突する場合、1つの Ll1_Conflict にグループ化
	input := `%token Eof Number Ident Plus Minus
%%
expr : expr Plus term
     | term
     ;
term : Number
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
	defer ll1_conflicts_destroy(&conflicts)

	// expr の prod 0 (expr Plus term) と prod 1 (term) が Number と Ident で衝突
	// これが1つの Ll1_Conflict にグループ化されている
	found_grouped := false
	for &c in conflicts {
		if c.rule_name == "expr" && c.prod_i == 0 && c.prod_j == 1 {
			testing.expectf(t, len(c.tokens) >= 2, "Expected at least 2 tokens in grouped conflict, got %d", len(c.tokens))
			found_grouped = true
			break
		}
	}
	testing.expect(t, found_grouped, "Expected grouped conflict for expr prod 0 and 1")
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

	// 期待: Term (開始) のみ — 1シンボル production は末尾状態を生成しない
	testing.expectf(t, len(states) == 1, "Expected 1 state, got %d", len(states))
	testing.expectf(t, states[0].name == "Term", "Expected 'Term', got '%s'", states[0].name)
	testing.expectf(t, states[0].pos == 0, "Expected pos 0, got %d", states[0].pos)
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
// 3.1a-2: 直接左再帰の検出テスト
// ========================================================================

@(test)
analysis_left_recursion_detected_test :: proc(t: ^testing.T) {
	// expr : expr Plus term | term ; は直接左再帰
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

	left_recs := check_left_recursion(&g)
	defer delete(left_recs)

	testing.expectf(t, len(left_recs) == 1, "Expected 1 left recursion, got %d", len(left_recs))
	testing.expect(t, left_recs[0].rule_name == "expr", "Expected left recursion in 'expr'")
	testing.expectf(t, left_recs[0].prod_idx == 0, "Expected prod_idx 0, got %d", left_recs[0].prod_idx)
}

@(test)
analysis_left_recursion_multiple_test :: proc(t: ^testing.T) {
	// expr と term の両方に左再帰
	input := `%token Eof Number Plus Asterisk
%%
expr : expr Plus term
     | term
     ;
term : term Asterisk Number
     | Number
     ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	left_recs := check_left_recursion(&g)
	defer delete(left_recs)

	testing.expectf(t, len(left_recs) == 2, "Expected 2 left recursions, got %d", len(left_recs))

	found_expr := false
	found_term := false
	for &lr in left_recs {
		if lr.rule_name == "expr" { found_expr = true }
		if lr.rule_name == "term" { found_term = true }
	}
	testing.expect(t, found_expr, "Expected left recursion in 'expr'")
	testing.expect(t, found_term, "Expected left recursion in 'term'")
}

@(test)
analysis_no_left_recursion_test :: proc(t: ^testing.T) {
	// 左再帰のない文法
	input := `%token Eof Number Plus
%%
expr : Number Plus Number
     | Number
     ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	left_recs := check_left_recursion(&g)
	defer delete(left_recs)

	testing.expectf(t, len(left_recs) == 0, "Expected no left recursion, got %d", len(left_recs))
}

@(test)
analysis_left_recursion_epsilon_safe_test :: proc(t: ^testing.T) {
	// ε production は左再帰ではない
	input := `%token Eof Number
%%
args : Number
     |
     ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	left_recs := check_left_recursion(&g)
	defer delete(left_recs)

	testing.expectf(t, len(left_recs) == 0, "Expected no left recursion for epsilon, got %d", len(left_recs))
}

// ========================================================================
// 3.1a-3: 演算子ループパターン検出テスト
// ========================================================================

@(test)
analysis_operator_loop_basic_test :: proc(t: ^testing.T) {
	// expr : expr Plus term | expr Minus term | term ;
	// → 演算子ループパターン: term (Plus|Minus term)*
	input := `%token Eof Number Plus Minus
%%
expr : expr Plus term
     | expr Minus term
     | term
     ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	testing.expectf(t, len(op_loops) == 1, "Expected 1 operator loop, got %d", len(op_loops))
	testing.expect(t, "expr" in op_loops, "Expected 'expr' in operator loops")

	loop := op_loops["expr"]
	testing.expect(t, loop.base_name == "term", "Expected base_name 'term'")
	testing.expectf(t, len(loop.operators) == 2, "Expected 2 operators, got %d", len(loop.operators))
	testing.expectf(t, len(loop.base_prods) == 1, "Expected 1 base prod, got %d", len(loop.base_prods))
}

@(test)
analysis_operator_loop_not_detected_test :: proc(t: ^testing.T) {
	// 左再帰でない文法 → 演算子ループなし
	input := `%token Eof Number Plus
%%
expr : Number Plus Number
     | Number
     ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	testing.expectf(t, len(op_loops) == 0, "Expected no operator loops, got %d", len(op_loops))
}

@(test)
analysis_operator_loop_with_epsilon_test :: proc(t: ^testing.T) {
	// args : expr | args Comma expr | ;
	// → 演算子ループ: expr (Comma expr)* (ε ベースケースあり)
	input := `%token Eof Number Comma
%%
args : expr
     | args Comma expr
     |
     ;
expr : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	testing.expectf(t, len(op_loops) == 1, "Expected 1 operator loop, got %d", len(op_loops))
	testing.expect(t, "args" in op_loops, "Expected 'args' in operator loops")
	testing.expectf(t, len(op_loops["args"].base_prods) == 2, "Expected 2 base prods (expr + ε), got %d", len(op_loops["args"].base_prods))
}

@(test)
analysis_operator_loop_states_test :: proc(t: ^testing.T) {
	// 演算子ループ規則は A, A_Op の2状態のみ
	input := `%token Eof Number Plus Minus
%%
expr : expr Plus term
     | expr Minus term
     | term
     ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	states := generate_states(&g, &op_loops)
	defer states_destroy(&states)

	// expr: Expr, Expr_Op (2 states)
	// term: Term (1 state, single terminal production)
	testing.expectf(t, len(states) == 3, "Expected 3 states, got %d", len(states))

	found_expr := false
	found_expr_op := false
	found_term := false
	for &s in states {
		if s.name == "Expr" { found_expr = true }
		if s.name == "Expr_Op" { found_expr_op = true }
		if s.name == "Term" { found_term = true }
	}
	testing.expect(t, found_expr, "Expected 'Expr' state")
	testing.expect(t, found_expr_op, "Expected 'Expr_Op' state")
	testing.expect(t, found_term, "Expected 'Term' state")
}

@(test)
analysis_operator_loop_invalid_pattern_test :: proc(t: ^testing.T) {
	// A : A B C D | B ; (左再帰だが4シンボルなので演算子ループではない)
	input := `%token Eof Number Plus Minus
%%
expr : expr Plus Number Minus
     | Number
     ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	testing.expectf(t, len(op_loops) == 0, "Expected no operator loops for 4-symbol production, got %d", len(op_loops))
}

// ========================================================================
// 間接左再帰の検出テスト
// ========================================================================

@(test)
analysis_indirect_left_recursion_test :: proc(t: ^testing.T) {
	// A : B c ; B : A d ; → 間接左再帰
	input := `%token Eof C_tok D_tok
%%
a : b C_tok ;
b : a D_tok ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	indirect_recs := check_indirect_left_recursion(&g, &op_loops)
	defer indirect_left_recursion_destroy(&indirect_recs)

	testing.expectf(t, len(indirect_recs) > 0, "Expected indirect left recursion, got %d", len(indirect_recs))
}

@(test)
analysis_no_indirect_left_recursion_test :: proc(t: ^testing.T) {
	// 間接左再帰のない文法
	input := `%token Eof Number Plus
%%
expr : Number Plus term ;
term : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	indirect_recs := check_indirect_left_recursion(&g, &op_loops)
	defer indirect_left_recursion_destroy(&indirect_recs)

	testing.expectf(t, len(indirect_recs) == 0, "Expected no indirect left recursion, got %d", len(indirect_recs))
}

@(test)
analysis_indirect_left_recursion_three_rules_test :: proc(t: ^testing.T) {
	// A : B x ; B : C y ; C : A z ; → 3規則の間接左再帰
	input := `%token Eof X_tok Y_tok Z_tok
%%
a : b X_tok ;
b : c Y_tok ;
c : a Z_tok ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	indirect_recs := check_indirect_left_recursion(&g, &op_loops)
	defer indirect_left_recursion_destroy(&indirect_recs)

	testing.expectf(t, len(indirect_recs) > 0, "Expected indirect left recursion for 3-rule cycle, got %d", len(indirect_recs))
}

// ========================================================================
// Phase 4: 通過状態スキップと意味的命名テスト
// ========================================================================

@(test)
analysis_passthrough_skip_test :: proc(t: ^testing.T) {
	// factor : Ident Left_Paren args Right_Paren
	// pos=0: Factor (開始), pos=1: Await_Left_Paren (Terminal),
	// pos=2: SKIP (args = Nonterminal), pos=3: Await_Right_Paren (Terminal, is_last なので生成しない)
	// → 結果: Factor, Factor_Await_Left_Paren, Factor_Await_Right_Paren の3状態のみ
	// (pos=3 は Phase 2 で除去済みだが、pos=2 の通過状態が Phase 4 で除去される)
	input := `%token Eof Number Ident Left_Paren Right_Paren
%%
factor : Ident Left_Paren args Right_Paren ;
args : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	states := generate_states(&g)
	defer states_destroy(&states)

	// factor の状態: Factor (開始), Factor_Await_Left_Paren (pos=1), Factor_Await_Right_Paren (pos=3)
	// args の状態: Args (開始)
	// pos=2 (args, Nonterminal) は通過状態としてスキップ
	factor_states := 0
	for &s in states {
		if s.rule == "factor" {
			factor_states += 1
		}
	}
	testing.expectf(t, factor_states == 3, "Expected 3 factor states (passthrough skipped), got %d", factor_states)

	// Await_ 命名が使われている
	found_await := false
	for &s in states {
		if s.rule == "factor" && s.pos > 0 {
			// 中間状態名に "Await_" が含まれている
			for i := 0; i + 6 <= len(s.name); i += 1 {
				if s.name[i:i+6] == "Await_" {
					found_await = true
					break
				}
			}
		}
	}
	testing.expect(t, found_await, "Expected Await_ naming for terminal states")
}

@(test)
analysis_nonterminal_only_production_test :: proc(t: ^testing.T) {
	// A : B C ; (B, C が全て Nonterminal)
	// pos=0: A (開始), pos=1: SKIP (C = Nonterminal)
	// → A のみ (中間状態はすべて通過状態)
	input := `%token Eof Number
%%
a : b c ;
b : Number ;
c : Number ;
%%`
	g, ok := parse_and_build(input)
	defer grammar_destroy(&g)
	testing.expectf(t, ok, "Expected parse success")

	states := generate_states(&g)
	defer states_destroy(&states)

	a_states := 0
	for &s in states {
		if s.rule == "a" {
			a_states += 1
		}
	}
	// A のみ: 全中間状態は Nonterminal 位置なのでスキップ
	testing.expectf(t, a_states == 1, "Expected 1 state for 'a' (all passthrough), got %d", a_states)
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

	// 演算子ループ検出
	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)
	testing.expectf(t, len(op_loops) == 3, "Expected 3 operator loops, got %d", len(op_loops))

	conflicts := check_ll1_conflicts(&g, firsts, follows, &op_loops)
	defer ll1_conflicts_destroy(&conflicts)
	// 演算子ループ規則をスキップするので衝突は 0 になる可能性がある
	// (factor は左再帰でないので衝突がない)

	states := generate_states(&g, &op_loops)
	defer states_destroy(&states)
	testing.expectf(t, len(states) > 0, "Expected some states, got %d", len(states))

	// 基本的な整合性チェック
	testing.expect(t, g.package_name == "calc", "Expected package 'calc'")
	testing.expectf(t, len(g.tokens) == 11, "Expected 11 tokens, got %d", len(g.tokens))
	testing.expectf(t, len(g.rules) == 4, "Expected 4 rules, got %d", len(g.rules))
}
