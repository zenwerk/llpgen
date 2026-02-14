package llpgen

import "core:fmt"
import "core:slice"
import "core:strings"

// FIRST 集合: 非終端記号名 → {トークン名} のマップ
// "_epsilon" は ε を導出可能であることを示す特殊キー
First_Sets :: map[string]map[string]bool

// FOLLOW 集合: 非終端記号名 → {トークン名} のマップ
Follow_Sets :: map[string]map[string]bool

EPSILON_MARKER :: "_epsilon"

// LL(1) 衝突情報
Ll1_Conflict :: struct {
	rule_name: string,
	prod_i:    int,
	prod_j:    int,
	tokens:    [dynamic]string, // 衝突するトークンのリスト
}

// 演算子ループ変換情報
// A : A op1 B | A op2 B | ... | B パターンを表現
Operator_Loop :: struct {
	rule_name:      string,              // 変換対象の規則名 (例: "expr")
	base_name:      string,              // ベースケースの非終端記号名 (例: "term")
	operators:      [dynamic]string,     // 演算子トークン名リスト (例: {"Plus", "Minus"})
	operator_assoc: map[string]Assoc,    // 演算子名→結合性 (precedence 宣言から取得)
	base_prods:     [dynamic]int,        // ベースケース production のインデックス
}

// Push Parser 状態
Gen_State :: struct {
	name: string, // 状態名 (Parse_State_Kind のメンバー名)
	rule: string, // 所属する規則名
	prod: int,    // alternative番号
	pos:  int,    // ドット位置 (0 = 開始, len(symbols) = 完了)
}

// 分析結果
Analysis_Result :: struct {
	firsts:    First_Sets,
	follows:   Follow_Sets,
	conflicts: [dynamic]Ll1_Conflict,
	states:    [dynamic]Gen_State,
}

analysis_result_destroy :: proc(r: ^Analysis_Result) {
	for k, &v in r.firsts {
		delete(v)
	}
	delete(r.firsts)
	for k, &v in r.follows {
		delete(v)
	}
	delete(r.follows)
	ll1_conflicts_destroy(&r.conflicts)
	states_destroy(&r.states)
}

ll1_conflicts_destroy :: proc(conflicts: ^[dynamic]Ll1_Conflict) {
	for &c in conflicts {
		delete(c.tokens)
	}
	delete(conflicts^)
}

states_destroy :: proc(states: ^[dynamic]Gen_State) {
	for &s in states {
		delete(s.name)
	}
	delete(states^)
}

// ========================================================================
// 3.1a: token_set と rule_map の構築 + Symbol.kind の確定
// ========================================================================

grammar_build_indices :: proc(g: ^Grammar) {
	// token_set の構築
	for tok in g.tokens {
		g.token_set[tok] = true
	}

	// rule_map の構築
	for rule, i in g.rules {
		g.rule_map[rule.name] = i
	}

	// 各 Production 内の Symbol.kind を確定
	for &rule in g.rules {
		for &prod in rule.productions {
			for &sym in prod.symbols {
				if sym.name in g.token_set {
					sym.kind = .Terminal
				} else if sym.name in g.rule_map {
					sym.kind = .Nonterminal
				} else {
					// 未知のシンボル: Nonterminal のまま (エラー扱いにはしない)
					sym.kind = .Nonterminal
				}
			}
		}
	}
}

// 未定義シンボル情報
Undefined_Symbol :: struct {
	name:      string,
	rule_name: string,
	prod_idx:  int,
}

// 未定義シンボルの検出: token_set にも rule_map にも存在しないシンボルを検出する
// grammar_build_indices() の後に呼ぶこと
check_undefined_symbols :: proc(g: ^Grammar) -> [dynamic]Undefined_Symbol {
	results: [dynamic]Undefined_Symbol
	reported: map[string]bool
	defer delete(reported)

	for &rule in g.rules {
		for &prod, prod_idx in rule.productions {
			for &sym in prod.symbols {
				if sym.name not_in g.token_set && sym.name not_in g.rule_map {
					if sym.name not_in reported {
						append(&results, Undefined_Symbol{
							name      = sym.name,
							rule_name = rule.name,
							prod_idx  = prod_idx,
						})
						reported[sym.name] = true
					}
				}
			}
		}
	}

	return results
}

// ========================================================================
// 3.1a-2: 直接左再帰の検出
// ========================================================================

// 左再帰情報
Left_Recursion :: struct {
	rule_name: string,
	prod_idx:  int, // 左再帰している production のインデックス
}

// 直接左再帰を検出する (A : A ... 形式)
// grammar_build_indices() の後に呼ぶこと
check_left_recursion :: proc(g: ^Grammar) -> [dynamic]Left_Recursion {
	results: [dynamic]Left_Recursion

	for &rule in g.rules {
		for &prod, prod_idx in rule.productions {
			if len(prod.symbols) == 0 {
				continue
			}
			first_sym := prod.symbols[0]
			if first_sym.kind == .Nonterminal && first_sym.name == rule.name {
				append(&results, Left_Recursion{
					rule_name = rule.name,
					prod_idx  = prod_idx,
				})
			}
		}
	}

	return results
}

// 間接左再帰の情報
Indirect_Left_Recursion :: struct {
	cycle: [dynamic]string, // サイクルを構成する規則名のリスト (例: {"A", "B", "A"})
}

indirect_left_recursion_destroy :: proc(results: ^[dynamic]Indirect_Left_Recursion) {
	for &r in results {
		delete(r.cycle)
	}
	delete(results^)
}

// 間接左再帰を検出する (A : B ... ; B : A ... ; のような循環)
// grammar_build_indices() の後に呼ぶこと
// op_loops: 演算子ループとして既に検出済みの規則はスキップ
check_indirect_left_recursion :: proc(g: ^Grammar, op_loops: ^map[string]Operator_Loop = nil) -> [dynamic]Indirect_Left_Recursion {
	results: [dynamic]Indirect_Left_Recursion

	// 各規則の先頭シンボルで有向グラフを構築 (Nonterminal のみ)
	// edge: rule_name → {先頭に来る可能性のある Nonterminal 名}
	edges: map[string]map[string]bool
	defer {
		for _, &v in edges {
			delete(v)
		}
		delete(edges)
	}

	for &rule in g.rules {
		// 演算子ループ規則はスキップ
		if op_loops != nil && rule.name in op_loops^ {
			continue
		}
		edges[rule.name] = make(map[string]bool)
		for &prod in rule.productions {
			// ε 導出可能な先頭シンボルを考慮してエッジを追加
			add_leading_nonterminal_edges(g, &edges, rule.name, prod.symbols[:])
		}
	}

	// DFS でサイクルを検出
	Color :: enum { White, Gray, Black }
	color: map[string]Color
	parent: map[string]string
	defer delete(color)
	defer delete(parent)

	for &rule in g.rules {
		if op_loops != nil && rule.name in op_loops^ {
			continue
		}
		color[rule.name] = .White
	}

	// DFS
	for &rule in g.rules {
		if op_loops != nil && rule.name in op_loops^ {
			continue
		}
		if color[rule.name] != .White {
			continue
		}
		// DFS スタック: (node, parent)
		stack: [dynamic]struct{node, par: string}
		defer delete(stack)
		append(&stack, struct{node, par: string}{rule.name, ""})

		for len(stack) > 0 {
			top := pop(&stack)
			u := top.node

			if color[u] == .Black {
				continue
			}

			if color[u] == .Gray {
				// Gray → Black: 探索完了
				color[u] = .Black
				continue
			}

			// White → Gray
			color[u] = .Gray
			parent[u] = top.par
			// Gray → Black のマーカーをプッシュ
			append(&stack, struct{node, par: string}{u, ""})

			if u in edges {
				for v in edges[u] {
					if v not_in color {
						continue // 演算子ループ等で除外された規則
					}
					if color[v] == .Gray && v != u {
						// 間接左再帰サイクルを発見 (直接左再帰 v==u はスキップ)
						cycle: [dynamic]string
						append(&cycle, v)
						cur := u
						for cur != v {
							append(&cycle, cur)
							if cur in parent {
								cur = parent[cur]
							} else {
								break
							}
						}
						append(&cycle, v)
						// サイクルを逆順にして正しい順序に
						// (現在は v → ... → u → v の逆順)
						for i := 0; i < len(cycle) / 2; i += 1 {
							j := len(cycle) - 1 - i
							cycle[i], cycle[j] = cycle[j], cycle[i]
						}
						append(&results, Indirect_Left_Recursion{cycle = cycle})
					} else if color[v] == .White {
						append(&stack, struct{node, par: string}{v, u})
					}
				}
			}
		}
	}

	return results
}

// 先頭の Nonterminal シンボルをエッジとして追加 (ε 導出可能なシンボルを考慮)
@(private = "file")
add_leading_nonterminal_edges :: proc(g: ^Grammar, edges: ^map[string]map[string]bool, rule_name: string, symbols: []Symbol) {
	for sym in symbols {
		if sym.kind == .Terminal {
			return // Terminal に到達したら終了
		}
		if sym.kind == .Nonterminal {
			if rule_name != sym.name { // 直接左再帰はスキップ (check_left_recursion で検出済み)
				if rule_name in edges {
					(&edges[rule_name])[sym.name] = true
				}
			}
			// sym がε導出可能か確認
			// 簡易チェック: sym の全 production のいずれかが ε かチェック
			if sym.name in g.rule_map {
				rule_idx := g.rule_map[sym.name]
				sym_rule := &g.rules[rule_idx]
				has_epsilon := false
				for &prod in sym_rule.productions {
					if len(prod.symbols) == 0 {
						has_epsilon = true
						break
					}
				}
				if has_epsilon {
					continue // 次のシンボルもチェック
				}
			}
			return // ε 導出不可なら終了
		}
	}
}

// ========================================================================
// 3.1a-2b: パススルー規則の検出
// ========================================================================

// パススルー規則: production が1つだけで、シンボルが1つの Nonterminal のみ
// 例: lambda_expr : pipe_expr ;
// 返り値: rule_name → target_name のマップ
detect_passthrough_rules :: proc(g: ^Grammar) -> map[string]string {
	result: map[string]string

	for &rule in g.rules {
		if len(rule.productions) != 1 {
			continue
		}
		prod := &rule.productions[0]
		if len(prod.symbols) != 1 {
			continue
		}
		sym := prod.symbols[0]
		if sym.kind == .Nonterminal {
			result[rule.name] = sym.name
		}
	}

	return result
}

// ========================================================================
// 3.1a-3: 演算子ループパターンの検出
// ========================================================================

// A : A op1 B | A op2 B | ... | B パターンを検出する
// grammar_build_indices() の後に呼ぶこと
// 返り値: 規則名 → Operator_Loop のマップ
detect_operator_loops :: proc(g: ^Grammar) -> map[string]Operator_Loop {
	result: map[string]Operator_Loop

	for &rule in g.rules {
		loop, ok := try_detect_operator_loop(g, &rule)
		if ok {
			result[rule.name] = loop
		}
	}

	return result
}

operator_loops_destroy :: proc(loops: ^map[string]Operator_Loop) {
	for _, &v in loops {
		delete(v.operators)
		delete(v.operator_assoc)
		delete(v.base_prods)
	}
	delete(loops^)
}

// 単一の規則が演算子ループパターンに該当するか判定
@(private = "file")
try_detect_operator_loop :: proc(g: ^Grammar, rule: ^Rule) -> (Operator_Loop, bool) {
	operators: [dynamic]string
	base_prods: [dynamic]int
	base_name := ""

	for &prod, prod_idx in rule.productions {
		if len(prod.symbols) == 0 {
			// ε production → ベースケースとして扱う
			append(&base_prods, prod_idx)
			continue
		}

		first_sym := prod.symbols[0]
		if first_sym.kind == .Nonterminal && first_sym.name == rule.name {
			// 左再帰 production: A op B の形か検証
			// 条件: 3シンボル, 2番目が Terminal, 3番目が Nonterminal
			if len(prod.symbols) != 3 {
				// 3シンボルでない左再帰は変換不可
				delete(operators)
				delete(base_prods)
				return {}, false
			}
			if prod.symbols[1].kind != .Terminal {
				// 2番目が Terminal でない
				delete(operators)
				delete(base_prods)
				return {}, false
			}
			if prod.symbols[2].kind != .Nonterminal {
				// 3番目が Nonterminal でない
				delete(operators)
				delete(base_prods)
				return {}, false
			}
			// 全左再帰 production のベース (3番目) は同じ非終端記号であること
			rhs_name := prod.symbols[2].name
			if base_name == "" {
				base_name = rhs_name
			} else if base_name != rhs_name {
				// 右辺の非終端記号が一致しない
				delete(operators)
				delete(base_prods)
				return {}, false
			}
			append(&operators, prod.symbols[1].name)
		} else {
			// 非左再帰 production → ベースケース
			// ベースケースは「単一の非終端記号」であるのが理想
			// (例: term, factor)
			// ただし、任意のベースケースも許容する
			append(&base_prods, prod_idx)
		}
	}

	// 条件チェック: 演算子が1つ以上、ベースケースが1つ以上
	if len(operators) == 0 || len(base_prods) == 0 {
		delete(operators)
		delete(base_prods)
		return {}, false
	}

	// ベースケースが単一の非終端記号 (例: | term ;) かチェック
	// 複数のベースケースがある場合もOK（通常のproduction分岐として処理）
	// ただし、base_name が未確定の場合はベースケースから推定
	if base_name == "" {
		// 左再帰productionがない場合 (ここには来ないはず)
		delete(operators)
		delete(base_prods)
		return {}, false
	}

	// 各演算子の結合性を precedence テーブルから取得
	op_assoc: map[string]Assoc
	for &op in operators {
		for &pe in g.precedence {
			for &tok in pe.tokens {
				if tok == op {
					op_assoc[op] = pe.assoc
				}
			}
		}
	}

	return Operator_Loop{
		rule_name      = rule.name,
		base_name      = base_name,
		operators      = operators,
		operator_assoc = op_assoc,
		base_prods     = base_prods,
	}, true
}

// ========================================================================
// 3.1b: FIRST 集合の計算
// ========================================================================

compute_first_sets :: proc(g: ^Grammar) -> First_Sets {
	firsts: First_Sets

	// 全非終端記号の FIRST を空で初期化
	for &rule in g.rules {
		firsts[rule.name] = make(map[string]bool)
	}

	// 不動点アルゴリズム
	changed := true
	for changed {
		changed = false
		for &rule in g.rules {
			for &prod in rule.productions {
				if add_first_from_symbols(&firsts, rule.name, prod.symbols[:], g) {
					changed = true
				}
			}
		}
	}

	return firsts
}

// シンボル列の先頭から FIRST に追加する。変化があれば true を返す。
@(private = "file")
add_first_from_symbols :: proc(firsts: ^First_Sets, rule_name: string, symbols: []Symbol, g: ^Grammar) -> bool {
	changed := false

	if len(symbols) == 0 {
		// 空の production → ε を導出可能
		if !(EPSILON_MARKER in firsts[rule_name]) {
			(&firsts[rule_name])[EPSILON_MARKER] = true
			changed = true
		}
		return changed
	}

	for sym in symbols {
		if sym.kind == .Terminal {
			// Terminal → FIRST(rule) に追加
			if !(sym.name in firsts[rule_name]) {
				(&firsts[rule_name])[sym.name] = true
				changed = true
			}
			return changed // Terminal に到達したら終了
		}

		// Nonterminal → FIRST(sym) \ {ε} を追加
		if sym.name in firsts^ {
			for tok in firsts[sym.name] {
				if tok == EPSILON_MARKER {
					continue
				}
				if !(tok in firsts[rule_name]) {
					(&firsts[rule_name])[tok] = true
					changed = true
				}
			}
		}

		// sym が ε を導出できなければ終了
		if sym.name not_in firsts^ || !(EPSILON_MARKER in firsts[sym.name]) {
			return changed
		}
		// sym が ε を導出可能なら次のシンボルへ
	}

	// 全シンボルが ε を導出可能 → この production も ε を導出可能
	if !(EPSILON_MARKER in firsts[rule_name]) {
		(&firsts[rule_name])[EPSILON_MARKER] = true
		changed = true
	}
	return changed
}

// シンボル列の FIRST 集合を計算する（production の FIRST 計算用）
compute_first_of_symbols :: proc(firsts: ^First_Sets, symbols: []Symbol, g: ^Grammar) -> map[string]bool {
	result: map[string]bool

	if len(symbols) == 0 {
		result[EPSILON_MARKER] = true
		return result
	}

	for sym in symbols {
		if sym.kind == .Terminal {
			result[sym.name] = true
			return result // Terminal に到達したら終了
		}

		// Nonterminal → FIRST(sym) \ {ε} を追加
		if sym.name in firsts^ {
			for tok in firsts[sym.name] {
				if tok == EPSILON_MARKER {
					continue
				}
				result[tok] = true
			}
		}

		// sym が ε を導出できなければ終了
		if sym.name not_in firsts^ || !(EPSILON_MARKER in firsts[sym.name]) {
			return result
		}
	}

	// 全シンボルが ε を導出可能
	result[EPSILON_MARKER] = true
	return result
}

// ========================================================================
// 3.1c: FOLLOW 集合の計算
// ========================================================================

compute_follow_sets :: proc(g: ^Grammar, firsts: First_Sets) -> Follow_Sets {
	follows: Follow_Sets

	// 全非終端記号の FOLLOW を空で初期化
	for &rule in g.rules {
		follows[rule.name] = make(map[string]bool)
	}

	// FOLLOW(開始記号) に Eof ($) を追加
	(&follows[g.start_rule])["Eof"] = true

	// 不動点アルゴリズム
	changed := true
	for changed {
		changed = false
		for &rule in g.rules {
			for &prod in rule.productions {
				for i := 0; i < len(prod.symbols); i += 1 {
					sym := prod.symbols[i]
					if sym.kind != .Nonterminal {
						continue
					}

					// β = prod.symbols[i+1:]
					beta := prod.symbols[i + 1:]

					// FOLLOW(sym) に FIRST(β) \ {ε} を追加
					mutable_firsts := firsts
					first_beta := compute_first_of_symbols(&mutable_firsts, beta, g)
					defer delete(first_beta)

					for tok in first_beta {
						if tok == EPSILON_MARKER {
							continue
						}
						if sym.name not_in follows {
							continue // 未定義の非終端記号はスキップ
						}
						if !(tok in follows[sym.name]) {
							(&follows[sym.name])[tok] = true
							changed = true
						}
					}

					// β が ε を導出可能 (または β が空) → FOLLOW(sym) に FOLLOW(rule) を追加
					if EPSILON_MARKER in first_beta {
						if sym.name not_in follows {
							continue // 未定義の非終端記号はスキップ
						}
						for tok in follows[rule.name] {
							if !(tok in follows[sym.name]) {
								(&follows[sym.name])[tok] = true
								changed = true
							}
						}
					}
				}
			}
		}
	}

	return follows
}

// ========================================================================
// 3.1d: LL(1) 衝突検出
// ========================================================================

check_ll1_conflicts :: proc(g: ^Grammar, firsts: First_Sets, follows: Follow_Sets, op_loops: ^map[string]Operator_Loop = nil) -> [dynamic]Ll1_Conflict {
	// (rule_name, prod_i, prod_j) でグループ化するための一時マップ
	Conflict_Key :: struct {
		rule_name: string,
		prod_i:    int,
		prod_j:    int,
	}
	grouped: map[Conflict_Key]^Ll1_Conflict
	defer delete(grouped)

	conflicts: [dynamic]Ll1_Conflict

	for &rule in g.rules {
		// 演算子ループ変換された規則はスキップ
		if op_loops != nil && rule.name in op_loops^ {
			continue
		}
		prods_count := len(rule.productions)
		if prods_count < 2 {
			continue
		}

		// 各 production の FIRST 集合を計算
		prod_firsts := make([]map[string]bool, prods_count)
		defer {
			for &pf in prod_firsts {
				delete(pf)
			}
			delete(prod_firsts)
		}

		mutable_firsts := firsts
		for i := 0; i < prods_count; i += 1 {
			prod_firsts[i] = compute_first_of_symbols(&mutable_firsts, rule.productions[i].symbols[:], g)
		}

		add_conflict_token :: proc(conflicts: ^[dynamic]Ll1_Conflict, grouped: ^map[Conflict_Key]^Ll1_Conflict, rule_name: string, pi: int, pj: int, tok: string) {
			key := Conflict_Key{rule_name = rule_name, prod_i = pi, prod_j = pj}
			if key in grouped^ {
				c := grouped[key]
				append(&c.tokens, tok)
			} else {
				tokens: [dynamic]string
				append(&tokens, tok)
				append(conflicts, Ll1_Conflict{
					rule_name = rule_name,
					prod_i    = pi,
					prod_j    = pj,
					tokens    = tokens,
				})
				grouped[key] = &conflicts[len(conflicts^) - 1]
			}
		}

		// 各ペアの FIRST に重複がないかチェック
		for i := 0; i < prods_count; i += 1 {
			for j := i + 1; j < prods_count; j += 1 {
				for tok in prod_firsts[i] {
					if tok == EPSILON_MARKER {
						continue
					}
					if tok in prod_firsts[j] {
						add_conflict_token(&conflicts, &grouped, rule.name, i, j, tok)
					}
				}
			}
		}

		// ε を導出可能な production がある場合、FIRST と FOLLOW の重複チェック
		for i := 0; i < prods_count; i += 1 {
			if !(EPSILON_MARKER in prod_firsts[i]) {
				continue
			}
			if rule.name not_in follows {
				continue
			}
			for j := 0; j < prods_count; j += 1 {
				if i == j {
					continue
				}
				for tok in follows[rule.name] {
					if tok in prod_firsts[j] {
						add_conflict_token(&conflicts, &grouped, rule.name, i, j, tok)
					}
				}
			}
		}
	}

	// 各衝突のトークンリストをソート
	for &c in conflicts {
		slice.sort(c.tokens[:])
	}

	return conflicts
}

// ========================================================================
// 3.1d-2: 空 FIRST+FOLLOW 集合のチェック
// ========================================================================

// production の先頭シンボルが Nonterminal の場合、FIRST+FOLLOW が空でないか検証
// 空の場合は Warning を出力
check_empty_first_follow :: proc(g: ^Grammar, firsts: First_Sets, follows: Follow_Sets, op_loops: ^map[string]Operator_Loop = nil) {
	for &rule in g.rules {
		// 演算子ループ規則はスキップ
		if op_loops != nil && rule.name in op_loops^ {
			continue
		}
		if len(rule.productions) < 2 {
			continue // 単一 production は分岐不要
		}

		for &prod, prod_idx in rule.productions {
			if len(prod.symbols) == 0 {
				continue // ε production は条件なしで else ブランチになる
			}
			first_sym := prod.symbols[0]
			if first_sym.kind != .Nonterminal {
				continue // Terminal は直接マッチ
			}

			// FIRST(production) を計算
			mutable_firsts := firsts
			first_set := compute_first_of_symbols(&mutable_firsts, prod.symbols[:], g)
			defer delete(first_set)

			has_non_epsilon := false
			for tok in first_set {
				if tok != EPSILON_MARKER {
					has_non_epsilon = true
					break
				}
			}

			if !has_non_epsilon {
				// FIRST が空 (ε のみ)、FOLLOW もチェック
				has_follow := false
				if rule.name in follows {
					for _ in follows[rule.name] {
						has_follow = true
						break
					}
				}
				if !has_follow {
					fmt.eprintfln("Warning: rule '%s' production %d has empty FIRST+FOLLOW set for leading nonterminal '%s'",
						rule.name, prod_idx, first_sym.name)
				}
			}
		}
	}
}

// ========================================================================
// 3.1e: Push Parser 状態の生成
// ========================================================================

// 規則名を PascalCase に変換 (例: "topstmt_list" → "Topstmt_List")
// 返される文字列は呼び出し側が delete で解放する必要がある
to_pascal_case :: proc(name: string, allocator := context.allocator) -> string {
	if len(name) == 0 {
		return ""
	}
	buf := make([dynamic]u8, 0, len(name), context.temp_allocator)

	capitalize_next := true
	for i := 0; i < len(name); i += 1 {
		ch := name[i]
		if ch == '_' {
			append(&buf, '_')
			capitalize_next = true
		} else if capitalize_next {
			if ch >= 'a' && ch <= 'z' {
				append(&buf, ch - 32) // to uppercase
			} else {
				append(&buf, ch)
			}
			capitalize_next = false
		} else {
			append(&buf, ch)
		}
	}

	return strings.clone(string(buf[:]), allocator)
}

generate_states :: proc(g: ^Grammar, op_loops: ^map[string]Operator_Loop = nil, allocator := context.allocator) -> [dynamic]Gen_State {
	states: [dynamic]Gen_State

	for &rule in g.rules {
		rule_pascal := to_pascal_case(rule.name, context.temp_allocator)

		// 演算子ループ規則の場合: A, A_Op の2状態のみ生成
		if op_loops != nil && rule.name in op_loops^ {
			// 開始状態: A (pos=0)
			append(&states, Gen_State{
				name = strings.clone(rule_pascal, allocator),
				rule = rule.name,
				prod = 0,
				pos  = 0,
			})
			// 演算子待ち状態: A_Op (pos=1, special marker)
			op_state_name := fmt.tprintf("%s_Op", rule_pascal)
			append(&states, Gen_State{
				name = strings.clone(op_state_name, allocator),
				rule = rule.name,
				prod = -1, // -1 は演算子ループの Op 状態を示す特殊マーカー
				pos  = 1,
			})
			continue
		}

		// 通常の規則: 規則の開始状態
		append(&states, Gen_State{
			name = strings.clone(rule_pascal, allocator),
			rule = rule.name,
			prod = 0,
			pos  = 0,
		})

		// 各 production の各ドット位置に対して中間状態を生成
		// - 末尾位置 (pos == len(symbols)) は生成しない (Phase 2)
		// - pos のシンボルが Nonterminal の場合は通過状態なので生成しない (Phase 4)
		//   → 前の状態から直接 Nonterminal を begin し、その先の状態に遷移する
		for &prod, prod_idx in rule.productions {
			for pos := 1; pos < len(prod.symbols); pos += 1 {
				current_sym := prod.symbols[pos]

				// 通過状態のスキップ: 現在位置のシンボルが Nonterminal の場合は状態を生成しない
				if current_sym.kind == .Nonterminal {
					continue
				}

				// 状態名: 「次に待つシンボル」で命名
				// Terminal を待つ状態 → "Await_<Terminal名>"
				sym_pascal := to_pascal_case(current_sym.name, context.temp_allocator)
				state_name := fmt.tprintf("%s_Await_%s", rule_pascal, sym_pascal)

				// 同名の状態がすでにあるか確認し、重複回避
				unique_name := make_unique_state_name(&states, state_name)

				append(&states, Gen_State{
					name = strings.clone(unique_name, allocator),
					rule = rule.name,
					prod = prod_idx,
					pos  = pos,
				})
			}
		}
	}

	return states
}

// 同名状態の重複を避けるためにサフィックスを付ける
// 返り値は temp_allocator のメモリを指す (呼び出し側で clone する)
@(private = "file")
make_unique_state_name :: proc(states: ^[dynamic]Gen_State, name: string) -> string {
	// まず名前がユニークか確認
	found := false
	for &s in states {
		if s.name == name {
			found = true
			break
		}
	}
	if !found {
		return name
	}

	// サフィックスを付けて一意にする
	for i := 2; i < 100; i += 1 {
		candidate := fmt.tprintf("%s_%d", name, i)
		is_unique := true
		for &s in states {
			if s.name == candidate {
				is_unique = false
				break
			}
		}
		if is_unique {
			return candidate
		}
	}
	return name // fallback
}
