package llpgen

import "core:fmt"
import "core:strings"

// コード生成の入力
Codegen_Input :: struct {
	grammar: ^Grammar,
	firsts:  ^First_Sets,
	follows: ^Follow_Sets,
	states:  ^[dynamic]Gen_State,
}

// コード生成メイン
codegen :: proc(input: Codegen_Input) -> string {
	b: strings.Builder
	strings.builder_init(&b)

	emit_header(&b, input.grammar)
	emit_state_enum(&b, input.states)
	emit_common_types(&b)
	emit_core_functions(&b, input.grammar)
	emit_push_token(&b, input.grammar, input.states)
	emit_parse_start(&b, input.grammar, input.states)
	emit_parse_functions(&b, input)

	return strings.to_string(b)
}

// ========================================================================
// ヘッダ (package宣言 + import)
// ========================================================================

@(private = "file")
emit_header :: proc(b: ^strings.Builder, g: ^Grammar) {
	pkg := g.package_name if len(g.package_name) > 0 else "parser"
	fmt.sbprintf(b, "package %s\n\n", pkg)
	fmt.sbprint(b, "import \"core:container/queue\"\n")
	fmt.sbprint(b, "import \"core:fmt\"\n")
	fmt.sbprint(b, "\n")
}

// ========================================================================
// 4.1a: Parse_State_Kind enum
// ========================================================================

@(private = "file")
emit_state_enum :: proc(b: ^strings.Builder, states: ^[dynamic]Gen_State) {
	fmt.sbprint(b, "// パーサーの状態\n")
	fmt.sbprint(b, "Parse_State_Kind :: enum {\n")
	fmt.sbprint(b, "\t// 基本状態\n")
	fmt.sbprint(b, "\tStart,\n")
	fmt.sbprint(b, "\tEnd,\n")
	fmt.sbprint(b, "\tError,\n")

	// 規則ごとにグループ分けして出力
	current_rule := ""
	for &s in states {
		if s.rule != current_rule {
			current_rule = s.rule
			fmt.sbprintf(b, "\t// -- %s --\n", s.rule)
		}
		fmt.sbprintf(b, "\t%s,\n", s.name)
	}

	fmt.sbprint(b, "}\n\n")
}

// ========================================================================
// 4.1b: 共通型定義 (Parse_Loop_Action, Parse_Result, Parse_State, Parser)
// ========================================================================

@(private = "file")
emit_common_types :: proc(b: ^strings.Builder) {
	fmt.sbprint(b, `// パースループ制御アクション
Parse_Loop_Action :: enum {
	Break,
	Continue,
}

// パース結果
Parse_Result :: enum {
	Parse_End,
	Push_More,
}

// パーサー状態
Parse_State :: struct {
	state: Parse_State_Kind,
	node:  ^^Node,    // 現在のノードへのポインタ
	saved: ^Node,     // 保存用ノード
	op:    string,    // 演算子 (必要に応じて)
}

// パーサー
Parser :: struct {
	state_stack: queue.Queue(Parse_State),
	root:        ^Node,
	error_msg:   string,
	nerr:        int,
}

`)
}

// ========================================================================
// 4.1c: パーサーコア関数 (テンプレート)
// ========================================================================

@(private = "file")
emit_core_functions :: proc(b: ^strings.Builder, g: ^Grammar) {
	fmt.sbprint(b, `// パーサーの初期化
parser_new :: proc() -> ^Parser {
	p := new(Parser)
	queue.init(&p.state_stack, capacity = 16)
	p.root = nil
	p.error_msg = ""
	p.nerr = 0
	parser_begin(p, .Start, &p.root)
	return p
}

// パーサーの破棄
parser_destroy :: proc(p: ^Parser) {
	if p == nil {
		return
	}
	queue.destroy(&p.state_stack)
	if p.root != nil {
		node_free(p.root)
	}
	free(p)
}

// パーサーのリセット
parser_reset :: proc(p: ^Parser) {
	queue.clear(&p.state_stack)
	if p.root != nil {
		node_free(p.root)
	}
	p.root = nil
	p.error_msg = ""
	p.nerr = 0
	parser_begin(p, .Start, &p.root)
}

// 新しい状態をスタックにプッシュ
parser_begin :: proc(p: ^Parser, state: Parse_State_Kind, node: ^^Node) {
	queue.push_front(&p.state_stack, Parse_State{state = state, node = node})
}

// 現在の状態をスタックからポップ
parser_end :: proc(p: ^Parser) {
	if queue.len(p.state_stack) > 0 {
		queue.pop_front(&p.state_stack)
	}
}

// 現在の状態を取得
parser_get_state :: proc(p: ^Parser) -> ^Parse_State {
	if queue.len(p.state_stack) <= 0 {
		return nil
	}
	return queue.front_ptr(&p.state_stack)
}

// 現在の状態を更新
parser_set_state :: proc(p: ^Parser, state: Parse_State_Kind, node: ^^Node = nil) {
	if queue.len(p.state_stack) <= 0 {
		return
	}
	top := parser_get_state(p)
	if top == nil {
		return
	}
	top.state = state
	if node != nil {
		top.node = node
	}
}

// エラー状態に遷移
parser_error :: proc(p: ^Parser, msg: string) {
	p.error_msg = msg
	p.nerr += 1
	if p.root != nil {
		node_free(p.root)
	}
	p.root = nil
	queue.clear(&p.state_stack)
	parser_begin(p, .Error, &p.root)
}

// トークンが期待通りか確認して消費
consumed :: proc(actual: ^Token, expected: Token_Type) -> bool {
	if actual.type == expected {
		actual.consumed = true
		return true
	}
	return false
}

`)

	// is_term: term_tokens が定義されている場合のみ生成
	if len(g.term_tokens) > 0 {
		fmt.sbprint(b, "// 文区切りトークンかチェック\n")
		fmt.sbprint(b, "is_term :: proc(tk: ^Token) -> bool {\n")
		fmt.sbprint(b, "\treturn ")
		for tok, i in g.term_tokens {
			if i > 0 {
				fmt.sbprint(b, " || ")
			}
			fmt.sbprintf(b, "tk.type == .%s", tok)
		}
		fmt.sbprint(b, "\n}\n\n")

		fmt.sbprint(b, `// 文区切りトークンを消費
consume_term :: proc(tk: ^Token) -> bool {
	if is_term(tk) {
		tk.consumed = true
		return true
	}
	return false
}

`)
	}

	// is_between ヘルパー
	fmt.sbprint(b, `// 状態が範囲内かチェック
@(private = "file")
is_between :: proc(state, from, to: Parse_State_Kind) -> bool {
	return from <= state && state <= to
}

`)
}

// ========================================================================
// 4.1d: parser_push_token ディスパッチ関数
// ========================================================================

@(private = "file")
emit_push_token :: proc(b: ^strings.Builder, g: ^Grammar, states: ^[dynamic]Gen_State) {
	fmt.sbprint(b, `// トークンをプッシュしてパース
parser_push_token :: proc(p: ^Parser, token: Token) -> Parse_Result {
	tk := token
	action: Parse_Loop_Action
	max_iterations := 1000

	for i := 0; i < max_iterations; i += 1 {
		top := parser_get_state(p)
		if top == nil {
			break
		}
		pstate := top.state

		if tk.consumed {
			break
		}

		if tk.type == .Error && pstate != .Error {
			parser_error(p, fmt.tprintf("Lexer error: %%s", tk.lexeme))
			break
		}

		// 状態に応じたパース関数を呼び出す
		if is_between(pstate, .Start, .Error) {
			action = parse_start(p, &tk)
`)

	// 各規則の状態範囲に基づくディスパッチを生成
	groups := build_state_groups(g, states)
	defer delete(groups)

	for &group in groups {
		fmt.sbprintf(b, "\t\t}} else if is_between(pstate, .%s, .%s) {{\n",
			group.first_state, group.last_state)
		fmt.sbprintf(b, "\t\t\taction = parse_%s(p, &tk)\n", group.rule_name)
	}

	fmt.sbprint(b, `		} else {
			fmt.eprintfln("Parse: Unknown state %v", top.state)
			break
		}

		if action == .Break {
			break
		}
	}

	top := parser_get_state(p)
	if top != nil && (top.state == .End || top.state == .Error) {
		return .Parse_End
	}
	return .Push_More
}

`)
}

// 状態グループ (1つの規則に所属する状態の最初と最後)
@(private = "file")
State_Group :: struct {
	rule_name:   string,
	first_state: string,
	last_state:  string,
}

@(private = "file")
build_state_groups :: proc(g: ^Grammar, states: ^[dynamic]Gen_State) -> [dynamic]State_Group {
	groups: [dynamic]State_Group
	current_rule := ""
	group_start := -1

	for s, i in states {
		if s.rule != current_rule {
			if group_start >= 0 {
				groups[len(groups) - 1].last_state = states[i - 1].name
			}
			current_rule = s.rule
			group_start = i
			append(&groups, State_Group{
				rule_name   = s.rule,
				first_state = s.name,
				last_state  = s.name,
			})
		}
	}
	// 最後のグループの last_state を設定
	if len(groups) > 0 && len(states) > 0 {
		groups[len(groups) - 1].last_state = states[len(states) - 1].name
	}

	return groups
}

// ========================================================================
// 4.1e-0: parse_start 関数
// ========================================================================

@(private = "file")
emit_parse_start :: proc(b: ^strings.Builder, g: ^Grammar, states: ^[dynamic]Gen_State) {
	// 開始規則の状態名を取得
	start_state := ""
	for &s in states {
		if s.rule == g.start_rule && s.pos == 0 {
			start_state = s.name
			break
		}
	}

	fmt.sbprint(b, "// 開始状態のパース\n")
	fmt.sbprint(b, "parse_start :: proc(p: ^Parser, tk: ^Token) -> Parse_Loop_Action {\n")
	fmt.sbprint(b, "\ttop := parser_get_state(p)\n")
	fmt.sbprint(b, "\tif top == nil { return .Break }\n\n")
	fmt.sbprint(b, "\t#partial switch top.state {\n")
	fmt.sbprint(b, "\tcase .Start:\n")
	fmt.sbprint(b, "\t\tif tk.type == .Eof {\n")
	fmt.sbprint(b, "\t\t\tparser_set_state(p, .End)\n")
	fmt.sbprint(b, "\t\t\treturn .Break\n")
	fmt.sbprint(b, "\t\t}\n")
	fmt.sbprint(b, "\t\tparser_set_state(p, .End)\n")
	fmt.sbprintf(b, "\t\tparser_begin(p, .%s, top.node)\n", start_state)
	fmt.sbprint(b, "\t\treturn .Continue\n")
	fmt.sbprint(b, "\tcase .End:\n")
	fmt.sbprint(b, "\t\treturn .Break\n")
	fmt.sbprint(b, "\tcase .Error:\n")
	fmt.sbprint(b, "\t\ttk.consumed = true\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\treturn .Break\n")
	fmt.sbprint(b, "}\n\n")
}

// ========================================================================
// 4.1e: 各 parse_* 関数のスケルトン生成
// ========================================================================

@(private = "file")
emit_parse_functions :: proc(b: ^strings.Builder, input: Codegen_Input) {
	g := input.grammar

	for &rule in g.rules {
		emit_parse_function(b, input, &rule)
	}
}

@(private = "file")
emit_parse_function :: proc(b: ^strings.Builder, input: Codegen_Input, rule: ^Rule) {
	g := input.grammar
	states := input.states

	// この規則に属する状態を収集
	rule_states: [dynamic]Gen_State
	defer delete(rule_states)
	for &s in states {
		if s.rule == rule.name {
			append(&rule_states, s)
		}
	}

	fmt.sbprintf(b, "// %s 規則のパース\n", rule.name)
	fmt.sbprintf(b, "parse_%s :: proc(p: ^Parser, tk: ^Token) -> Parse_Loop_Action {{\n", rule.name)
	fmt.sbprint(b, "\ttop := parser_get_state(p)\n")
	fmt.sbprint(b, "\tif top == nil { return .Break }\n\n")
	fmt.sbprint(b, "\t#partial switch top.state {\n")

	// 開始状態のケース (pos == 0)
	for &s in rule_states {
		if s.pos == 0 {
			emit_rule_start_case(b, input, rule, &s)
		}
	}

	// 中間状態のケース (pos > 0)
	for &s in rule_states {
		if s.pos > 0 {
			emit_intermediate_case(b, input, rule, &s)
		}
	}

	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\treturn .Break\n")
	fmt.sbprint(b, "}\n\n")
}

// 規則の開始状態ケース: 各 production の FIRST に基づく分岐
@(private = "file")
emit_rule_start_case :: proc(b: ^strings.Builder, input: Codegen_Input, rule: ^Rule, state: ^Gen_State) {
	g := input.grammar

	fmt.sbprintf(b, "\tcase .%s:\n", state.name)

	if len(rule.productions) == 1 {
		// 1つの production のみ: 分岐なし
		emit_production_body(b, input, rule, 0, "\t\t")
	} else {
		// 複数 production: FIRST に基づく分岐
		first_if := true
		for prod_idx := 0; prod_idx < len(rule.productions); prod_idx += 1 {
			prod := &rule.productions[prod_idx]
			if len(prod.symbols) == 0 {
				continue // ε production は後で else として処理
			}

			if first_if {
				fmt.sbprint(b, "\t\t")
				first_if = false
			} else {
				fmt.sbprint(b, " else ")
			}

			// 条件を生成
			emit_production_condition(b, input, prod)
			fmt.sbprint(b, " {\n")
			emit_production_body(b, input, rule, prod_idx, "\t\t\t")
			fmt.sbprint(b, "\t\t}")
		}

		// ε production があれば else として出力
		has_epsilon := false
		for prod_idx := 0; prod_idx < len(rule.productions); prod_idx += 1 {
			prod := &rule.productions[prod_idx]
			if len(prod.symbols) == 0 {
				has_epsilon = true
				fmt.sbprint(b, " else {\n")
				fmt.sbprint(b, "\t\t\t// ε production\n")
				fmt.sbprint(b, "\t\t\tparser_end(p)\n")
				fmt.sbprint(b, "\t\t\treturn .Continue\n")
				fmt.sbprint(b, "\t\t}")
				break
			}
		}

		if !has_epsilon && !first_if {
			fmt.sbprint(b, " else {\n")
			fmt.sbprintf(b, "\t\t\tparser_error(p, fmt.tprintf(\"Unexpected token in %s: %%v\", tk.type))\n", rule.name)
			fmt.sbprint(b, "\t\t\treturn .Break\n")
			fmt.sbprint(b, "\t\t}")
		}
		fmt.sbprint(b, "\n")
	}
}

// production の条件式を生成
@(private = "file")
emit_production_condition :: proc(b: ^strings.Builder, input: Codegen_Input, prod: ^Production) {
	g := input.grammar

	if len(prod.symbols) == 0 {
		fmt.sbprint(b, "if true")
		return
	}

	first_sym := prod.symbols[0]
	if first_sym.kind == .Terminal {
		fmt.sbprintf(b, "if tk.type == .%s", first_sym.name)
	} else {
		// Nonterminal: FIRST 集合の全トークンで分岐
		mutable_firsts := input.firsts^
		first_set := compute_first_of_symbols(&mutable_firsts, prod.symbols[:], g)
		defer delete(first_set)

		conditions: [dynamic]string
		defer delete(conditions)
		for tok in first_set {
			if tok == EPSILON_MARKER { continue }
			append(&conditions, tok)
		}

		if len(conditions) > 0 {
			fmt.sbprint(b, "if ")
			for ci := 0; ci < len(conditions); ci += 1 {
				if ci > 0 { fmt.sbprint(b, " || ") }
				fmt.sbprintf(b, "tk.type == .%s", conditions[ci])
			}
		} else {
			fmt.sbprint(b, "if true /* TODO: FIRST set empty */")
		}
	}
}

// 1つの production のボディ(開始処理)を生成
@(private = "file")
emit_production_body :: proc(b: ^strings.Builder, input: Codegen_Input, rule: ^Rule, prod_idx: int, indent: string) {
	prod := &rule.productions[prod_idx]

	if len(prod.symbols) == 0 {
		fmt.sbprintf(b, "%s// ε production\n", indent)
		fmt.sbprintf(b, "%sparser_end(p)\n", indent)
		fmt.sbprintf(b, "%sreturn .Continue\n", indent)
		return
	}

	first_sym := prod.symbols[0]

	fmt.sbprintf(b, "%s// TODO: AST node construction\n", indent)

	if first_sym.kind == .Terminal {
		// Terminal を消費してから次へ
		next_state := find_state_for(input.states, rule.name, prod_idx, 1)
		if len(prod.symbols) == 1 {
			fmt.sbprintf(b, "%stk.consumed = true\n", indent)
			fmt.sbprintf(b, "%sparser_end(p)\n", indent)
			fmt.sbprintf(b, "%sreturn .Continue\n", indent)
		} else {
			fmt.sbprintf(b, "%stk.consumed = true\n", indent)
			fmt.sbprintf(b, "%sparser_set_state(p, .%s)\n", indent, next_state)
			fmt.sbprintf(b, "%sreturn .Continue\n", indent)
		}
	} else {
		// Nonterminal → parser_begin
		nonterminal_start := find_state_for(input.states, first_sym.name, 0, 0)
		next_state := find_state_for(input.states, rule.name, prod_idx, 1)
		if len(prod.symbols) == 1 {
			fmt.sbprintf(b, "%sparser_end(p)\n", indent)
			fmt.sbprintf(b, "%sparser_begin(p, .%s, top.node)\n", indent, nonterminal_start)
			fmt.sbprintf(b, "%sreturn .Continue\n", indent)
		} else {
			fmt.sbprintf(b, "%sparser_set_state(p, .%s)\n", indent, next_state)
			fmt.sbprintf(b, "%sparser_begin(p, .%s, top.node)\n", indent, nonterminal_start)
			fmt.sbprintf(b, "%sreturn .Continue\n", indent)
		}
	}
}

// 中間状態のケース
@(private = "file")
emit_intermediate_case :: proc(b: ^strings.Builder, input: Codegen_Input, rule: ^Rule, state: ^Gen_State) {
	g := input.grammar
	prod := &rule.productions[state.prod]

	fmt.sbprintf(b, "\tcase .%s:\n", state.name)

	// この状態の位置のシンボルを取得
	if state.pos >= len(prod.symbols) {
		// production 終了: 規則完了
		fmt.sbprint(b, "\t\t// production 完了\n")
		fmt.sbprint(b, "\t\tparser_end(p)\n")
		fmt.sbprint(b, "\t\treturn .Continue\n")
		return
	}

	sym := prod.symbols[state.pos]
	is_last := (state.pos == len(prod.symbols) - 1)

	if sym.kind == .Terminal {
		fmt.sbprintf(b, "\t\tif consumed(tk, .%s) {{\n", sym.name)
		if is_last {
			fmt.sbprint(b, "\t\t\t// TODO: AST node construction\n")
			fmt.sbprint(b, "\t\t\tparser_end(p)\n")
			fmt.sbprint(b, "\t\t\treturn .Continue\n")
		} else {
			next_state := find_state_for(input.states, rule.name, state.prod, state.pos + 1)
			fmt.sbprint(b, "\t\t\t// TODO: AST node construction\n")
			fmt.sbprintf(b, "\t\t\tparser_set_state(p, .%s)\n", next_state)
			fmt.sbprint(b, "\t\t\treturn .Continue\n")
		}
		fmt.sbprint(b, "\t\t} else {\n")
		fmt.sbprintf(b, "\t\t\tparser_error(p, fmt.tprintf(\"Expected %s, got %%v\", tk.type))\n", sym.name)
		fmt.sbprint(b, "\t\t}\n")
	} else {
		// Nonterminal
		nonterminal_start := find_state_for(input.states, sym.name, 0, 0)
		if is_last {
			fmt.sbprint(b, "\t\t// TODO: AST node construction\n")
			fmt.sbprint(b, "\t\tparser_end(p)\n")
			fmt.sbprintf(b, "\t\tparser_begin(p, .%s, top.node)\n", nonterminal_start)
			fmt.sbprint(b, "\t\treturn .Continue\n")
		} else {
			next_state := find_state_for(input.states, rule.name, state.prod, state.pos + 1)
			fmt.sbprint(b, "\t\t// TODO: AST node construction\n")
			fmt.sbprintf(b, "\t\tparser_set_state(p, .%s)\n", next_state)
			fmt.sbprintf(b, "\t\tparser_begin(p, .%s, top.node)\n", nonterminal_start)
			fmt.sbprint(b, "\t\treturn .Continue\n")
		}
	}
}

// 指定された規則・production・位置に対応する状態名を検索
@(private = "file")
find_state_for :: proc(states: ^[dynamic]Gen_State, rule_name: string, prod_idx: int, pos: int) -> string {
	for &s in states {
		if s.rule == rule_name && s.prod == prod_idx && s.pos == pos {
			return s.name
		}
	}
	// 見つからない場合は開始状態を返す
	for &s in states {
		if s.rule == rule_name && s.pos == 0 {
			return s.name
		}
	}
	return "Error"
}
