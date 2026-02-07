package llpgen

import "core:fmt"
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
	token:     string, // 衝突するトークン
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
	delete(r.conflicts)
	states_destroy(&r.states)
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

// ========================================================================
// 3.1b: FIRST 集合の計算
// ========================================================================

compute_first_sets :: proc(g: ^Grammar) -> First_Sets {
	firsts: First_Sets

	// 全非終端記号の FIRST を空で初期化
	for &rule in g.rules {
		firsts[rule.name] = {}
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
		follows[rule.name] = {}
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
						if !(tok in follows[sym.name]) {
							(&follows[sym.name])[tok] = true
							changed = true
						}
					}

					// β が ε を導出可能 (または β が空) → FOLLOW(sym) に FOLLOW(rule) を追加
					if EPSILON_MARKER in first_beta {
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

check_ll1_conflicts :: proc(g: ^Grammar, firsts: First_Sets, follows: Follow_Sets) -> [dynamic]Ll1_Conflict {
	conflicts: [dynamic]Ll1_Conflict

	for &rule in g.rules {
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

		// 各ペアの FIRST に重複がないかチェック
		for i := 0; i < prods_count; i += 1 {
			for j := i + 1; j < prods_count; j += 1 {
				for tok in prod_firsts[i] {
					if tok == EPSILON_MARKER {
						continue
					}
					if tok in prod_firsts[j] {
						append(&conflicts, Ll1_Conflict{
							rule_name = rule.name,
							prod_i    = i,
							prod_j    = j,
							token     = tok,
						})
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
						append(&conflicts, Ll1_Conflict{
							rule_name = rule.name,
							prod_i    = i,
							prod_j    = j,
							token     = tok,
						})
					}
				}
			}
		}
	}

	return conflicts
}

// ========================================================================
// 3.1e: Push Parser 状態の生成
// ========================================================================

// 規則名を PascalCase に変換 (例: "topstmt_list" → "Topstmt_List")
// 返される文字列は呼び出し側が delete で解放する必要がある
@(private = "file")
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

generate_states :: proc(g: ^Grammar, allocator := context.allocator) -> [dynamic]Gen_State {
	states: [dynamic]Gen_State

	for &rule in g.rules {
		// 規則の開始状態
		rule_pascal := to_pascal_case(rule.name, context.temp_allocator)
		append(&states, Gen_State{
			name = strings.clone(rule_pascal, allocator),
			rule = rule.name,
			prod = 0,
			pos  = 0,
		})

		// 各 production の各ドット位置に対して中間状態を生成
		for &prod, prod_idx in rule.productions {
			for pos := 1; pos <= len(prod.symbols); pos += 1 {
				prev_sym := prod.symbols[pos - 1]
				sym_pascal := to_pascal_case(prev_sym.name, context.temp_allocator)
				state_name := fmt.tprintf("%s_After_%s", rule_pascal, sym_pascal)

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
