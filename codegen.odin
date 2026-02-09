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

// Grammar から Token 型名を取得 (デフォルト: "Token")
@(private = "file")
get_token_type :: proc(g: ^Grammar) -> string {
	return g.token_type_name if len(g.token_type_name) > 0 else "Token"
}

// Grammar から Token_Type enum 名を取得 (Token 型名 + "_Type")
@(private = "file")
get_token_enum_type :: proc(g: ^Grammar) -> string {
	tk := get_token_type(g)
	return fmt.tprintf("%s_Type", tk)
}

// Grammar から Node 型名を取得 (デフォルト: "Node")
@(private = "file")
get_node_type :: proc(g: ^Grammar) -> string {
	return g.node_type_name if len(g.node_type_name) > 0 else "Node"
}

// Grammar から node_free 関数名を取得 ("<node_type>_free" の形式, 先頭小文字)
@(private = "file")
get_node_free :: proc(g: ^Grammar) -> string {
	node := get_node_type(g)
	if len(node) == 0 { return "node_free" }
	// PascalCase/CamelCase を snake_case に変換
	buf := make([dynamic]u8, 0, len(node) * 2, context.temp_allocator)
	for i := 0; i < len(node); i += 1 {
		ch := node[i]
		if ch >= 'A' && ch <= 'Z' {
			if i > 0 && node[i - 1] != '_' {
				append(&buf, '_')
			}
			append(&buf, ch + 32) // to lowercase
		} else {
			append(&buf, ch)
		}
	}
	return fmt.tprintf("%s_free", string(buf[:]))
}

// コード生成メイン
codegen :: proc(input: Codegen_Input) -> string {
	b: strings.Builder
	strings.builder_init(&b)

	emit_header(&b, input.grammar)
	emit_state_enum(&b, input.states)
	emit_common_types(&b, input.grammar)
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

	// ユーザーが実装すべきインターフェースをコメントで出力
	tk_type := get_token_type(g)
	tk_enum := get_token_enum_type(g)
	node := get_node_type(g)
	node_free := get_node_free(g)

	fmt.sbprint(b, "// ========================================================================\n")
	fmt.sbprint(b, "// このパーサーを使用するには、以下の型と関数を別ファイルで定義してください:\n")
	fmt.sbprint(b, "//\n")
	fmt.sbprintf(b, "//   %s :: struct {{ ... }}       // AST ノード型\n", node)
	fmt.sbprintf(b, "//   %s(n: ^%s)                  // ノードの再帰的解放\n", node_free, node)
	fmt.sbprint(b, "//\n")
	fmt.sbprintf(b, "//   %s :: enum {{ ... }}   // トークン種別 (Eof, Error, ... を含む)\n", tk_enum)
	fmt.sbprintf(b, "//   %s :: struct {{                   // トークン型\n", tk_type)
	fmt.sbprintf(b, "//       type:     %s,\n", tk_enum)
	fmt.sbprint(b, "//       consumed: bool,\n")
	fmt.sbprint(b, "//       lexeme:   string,\n")
	fmt.sbprint(b, "//   }\n")
	fmt.sbprint(b, "// ========================================================================\n\n")
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
emit_common_types :: proc(b: ^strings.Builder, g: ^Grammar) {
	node := get_node_type(g)

	fmt.sbprint(b, "// パースループ制御アクション\n")
	fmt.sbprint(b, "Parse_Loop_Action :: enum {\n")
	fmt.sbprint(b, "\tBreak,\n")
	fmt.sbprint(b, "\tContinue,\n")
	fmt.sbprint(b, "}\n\n")
	fmt.sbprint(b, "// パース結果\n")
	fmt.sbprint(b, "Parse_Result :: enum {\n")
	fmt.sbprint(b, "\tParse_End,\n")
	fmt.sbprint(b, "\tPush_More,\n")
	fmt.sbprint(b, "}\n\n")
	fmt.sbprint(b, "// パーサー状態\n")
	fmt.sbprint(b, "Parse_State :: struct {\n")
	fmt.sbprint(b, "\tstate: Parse_State_Kind,\n")
	fmt.sbprintf(b, "\tnode:  ^^%s,    // 現在のノードへのポインタ\n", node)
	fmt.sbprintf(b, "\tsaved: ^%s,     // 保存用ノード\n", node)
	fmt.sbprint(b, "\top:    string,    // 演算子 (必要に応じて)\n")
	fmt.sbprint(b, "}\n\n")
	fmt.sbprint(b, "// パーサー\n")
	fmt.sbprint(b, "Parser :: struct {\n")
	fmt.sbprint(b, "\tstate_stack: queue.Queue(Parse_State),\n")
	fmt.sbprintf(b, "\troot:        ^%s,\n", node)
	fmt.sbprint(b, "\terror_msg:   string,\n")
	fmt.sbprint(b, "\tnerr:        int,\n")
	fmt.sbprint(b, "}\n\n")
}

// ========================================================================
// 4.1c: パーサーコア関数 (テンプレート)
// ========================================================================

@(private = "file")
emit_core_functions :: proc(b: ^strings.Builder, g: ^Grammar) {
	node := get_node_type(g)
	node_free := get_node_free(g)
	tk_type := get_token_type(g)
	tk_enum := get_token_enum_type(g)

	fmt.sbprint(b, "// パーサーの初期化\n")
	fmt.sbprint(b, "parser_new :: proc() -> ^Parser {\n")
	fmt.sbprint(b, "\tp := new(Parser)\n")
	fmt.sbprint(b, "\tqueue.init(&p.state_stack, capacity = 16)\n")
	fmt.sbprint(b, "\tp.root = nil\n")
	fmt.sbprint(b, "\tp.error_msg = \"\"\n")
	fmt.sbprint(b, "\tp.nerr = 0\n")
	fmt.sbprint(b, "\tparser_begin(p, .Start, &p.root)\n")
	fmt.sbprint(b, "\treturn p\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// パーサーの破棄\n")
	fmt.sbprint(b, "parser_destroy :: proc(p: ^Parser) {\n")
	fmt.sbprint(b, "\tif p == nil {\n")
	fmt.sbprint(b, "\t\treturn\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\tqueue.destroy(&p.state_stack)\n")
	fmt.sbprint(b, "\tif p.root != nil {\n")
	fmt.sbprintf(b, "\t\t%s(p.root)\n", node_free)
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\tfree(p)\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// パーサーのリセット\n")
	fmt.sbprint(b, "parser_reset :: proc(p: ^Parser) {\n")
	fmt.sbprint(b, "\tqueue.clear(&p.state_stack)\n")
	fmt.sbprint(b, "\tif p.root != nil {\n")
	fmt.sbprintf(b, "\t\t%s(p.root)\n", node_free)
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\tp.root = nil\n")
	fmt.sbprint(b, "\tp.error_msg = \"\"\n")
	fmt.sbprint(b, "\tp.nerr = 0\n")
	fmt.sbprint(b, "\tparser_begin(p, .Start, &p.root)\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// 新しい状態をスタックにプッシュ\n")
	fmt.sbprintf(b, "parser_begin :: proc(p: ^Parser, state: Parse_State_Kind, node: ^^%s) {{\n", node)
	fmt.sbprint(b, "\tqueue.push_front(&p.state_stack, Parse_State{state = state, node = node})\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// 現在の状態をスタックからポップ\n")
	fmt.sbprint(b, "parser_end :: proc(p: ^Parser) {\n")
	fmt.sbprint(b, "\tif queue.len(p.state_stack) > 0 {\n")
	fmt.sbprint(b, "\t\tqueue.pop_front(&p.state_stack)\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// 現在の状態を取得\n")
	fmt.sbprint(b, "parser_get_state :: proc(p: ^Parser) -> ^Parse_State {\n")
	fmt.sbprint(b, "\tif queue.len(p.state_stack) <= 0 {\n")
	fmt.sbprint(b, "\t\treturn nil\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\treturn queue.front_ptr(&p.state_stack)\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// 現在の状態を更新\n")
	fmt.sbprintf(b, "parser_set_state :: proc(p: ^Parser, state: Parse_State_Kind, node: ^^%s = nil) {{\n", node)
	fmt.sbprint(b, "\tif queue.len(p.state_stack) <= 0 {\n")
	fmt.sbprint(b, "\t\treturn\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\ttop := parser_get_state(p)\n")
	fmt.sbprint(b, "\tif top == nil {\n")
	fmt.sbprint(b, "\t\treturn\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\ttop.state = state\n")
	fmt.sbprint(b, "\tif node != nil {\n")
	fmt.sbprint(b, "\t\ttop.node = node\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// エラー状態に遷移\n")
	fmt.sbprint(b, "parser_error :: proc(p: ^Parser, msg: string) {\n")
	fmt.sbprint(b, "\tp.error_msg = msg\n")
	fmt.sbprint(b, "\tp.nerr += 1\n")
	fmt.sbprint(b, "\tif p.root != nil {\n")
	fmt.sbprintf(b, "\t\t%s(p.root)\n", node_free)
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\tp.root = nil\n")
	fmt.sbprint(b, "\tqueue.clear(&p.state_stack)\n")
	fmt.sbprint(b, "\tparser_begin(p, .Error, &p.root)\n")
	fmt.sbprint(b, "}\n\n")

	fmt.sbprint(b, "// トークンが期待通りか確認して消費\n")
	fmt.sbprintf(b, "consumed :: proc(actual: ^%s, expected: %s) -> bool {{\n", tk_type, tk_enum)
	fmt.sbprint(b, "\tif actual.type == expected {\n")
	fmt.sbprint(b, "\t\tactual.consumed = true\n")
	fmt.sbprint(b, "\t\treturn true\n")
	fmt.sbprint(b, "\t}\n")
	fmt.sbprint(b, "\treturn false\n")
	fmt.sbprint(b, "}\n\n")

	// is_term: term_tokens が定義されている場合のみ生成
	if len(g.term_tokens) > 0 {
		fmt.sbprint(b, "// 文区切りトークンかチェック\n")
		fmt.sbprintf(b, "is_term :: proc(tk: ^%s) -> bool {{\n", tk_type)
		fmt.sbprint(b, "\treturn ")
		for tok, i in g.term_tokens {
			if i > 0 {
				fmt.sbprint(b, " || ")
			}
			fmt.sbprintf(b, "tk.type == .%s", tok)
		}
		fmt.sbprint(b, "\n}\n\n")

		fmt.sbprint(b, "// 文区切りトークンを消費\n")
		fmt.sbprintf(b, "consume_term :: proc(tk: ^%s) -> bool {{\n", tk_type)
		fmt.sbprint(b, "\tif is_term(tk) {\n")
		fmt.sbprint(b, "\t\ttk.consumed = true\n")
		fmt.sbprint(b, "\t\treturn true\n")
		fmt.sbprint(b, "\t}\n")
		fmt.sbprint(b, "\treturn false\n")
		fmt.sbprint(b, "}\n\n")
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
	tk_type := get_token_type(g)

	fmt.sbprint(b, "// トークンをプッシュしてパース\n")
	fmt.sbprintf(b, "parser_push_token :: proc(p: ^Parser, token: %s) -> Parse_Result {{\n", tk_type)
	fmt.sbprint(b, "\ttk := token\n")
	fmt.sbprint(b, "\taction: Parse_Loop_Action\n")
	fmt.sbprint(b, "\tmax_iterations := 1000\n\n")
	fmt.sbprint(b, "\tfor i := 0; i < max_iterations; i += 1 {\n")
	fmt.sbprint(b, "\t\ttop := parser_get_state(p)\n")
	fmt.sbprint(b, "\t\tif top == nil {\n")
	fmt.sbprint(b, "\t\t\tbreak\n")
	fmt.sbprint(b, "\t\t}\n")
	fmt.sbprint(b, "\t\tpstate := top.state\n\n")
	fmt.sbprint(b, "\t\tif tk.consumed {\n")
	fmt.sbprint(b, "\t\t\tbreak\n")
	fmt.sbprint(b, "\t\t}\n\n")
	fmt.sbprint(b, "\t\tif tk.type == .Error && pstate != .Error {\n")
	fmt.sbprint(b, "\t\t\tparser_error(p, fmt.tprintf(\"Lexer error: %%s\", tk.lexeme))\n")
	fmt.sbprint(b, "\t\t\tbreak\n")
	fmt.sbprint(b, "\t\t}\n\n")
	fmt.sbprint(b, "\t\t// 状態に応じたパース関数を呼び出す\n")
	fmt.sbprint(b, "\t\tif is_between(pstate, .Start, .Error) {\n")
	fmt.sbprint(b, "\t\t\taction = parse_start(p, &tk)\n")

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

	tk_type := get_token_type(g)

	fmt.sbprint(b, "// 開始状態のパース\n")
	fmt.sbprintf(b, "parse_start :: proc(p: ^Parser, tk: ^%s) -> Parse_Loop_Action {{\n", tk_type)
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

	tk_type := get_token_type(g)

	fmt.sbprintf(b, "// %s 規則のパース\n", rule.name)
	fmt.sbprintf(b, "parse_%s :: proc(p: ^Parser, tk: ^%s) -> Parse_Loop_Action {{\n", rule.name, tk_type)
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
