package llpgen

// シンボルの種類
Symbol_Kind :: enum {
	Terminal,    // トークン (Token_Type のメンバー名に対応)
	Nonterminal, // 非終端記号 (文法規則名)
	Epsilon,     // 空列 (ε)
}

// 文法シンボル
Symbol :: struct {
	kind: Symbol_Kind,
	name: string, // Terminal: "Kw_If", "Op_Plus" 等
	              // Nonterminal: "expr", "stmt" 等
}

// 結合性
Assoc :: enum {
	None,  // %nonassoc
	Left,  // %left
	Right, // %right
}

// 優先順位エントリ
Prec_Entry :: struct {
	level:  int, // 優先順位レベル (1が最低, 数値が大きいほど高い)
	assoc:  Assoc,
	tokens: [dynamic]string, // 適用されるトークン名
}

// 1つの生成規則 (alternative)
Production :: struct {
	symbols: [dynamic]Symbol,
}

// 文法規則 (1つの非終端記号に対する全alternative)
Rule :: struct {
	name:        string,
	productions: [dynamic]Production,
}

// 文法全体
Grammar :: struct {
	package_name:    string,              // %package で指定された名前
	token_type_name: string,              // %token_type で指定されたトークン型名 (デフォルト: "Token")
	node_type_name:  string,              // %node_type で指定されたノード型名 (デフォルト: "Node")
	tokens:          [dynamic]string,     // %token で宣言されたトークン名
	term_tokens:     [dynamic]string,     // %term で宣言された文区切りトークン
	precedence:      [dynamic]Prec_Entry, // 優先順位テーブル (index順に低→高)
	rules:           [dynamic]Rule,       // 文法規則
	start_rule:      string,              // 開始規則名 (最初のrule)
	expected_conflicts: map[string]int,    // %expect_conflict で指定された規則名→許容衝突数
	max_iterations:     int,               // %max_iterations で指定された最大反復数 (デフォルト: 1000)
	// 以下は analysis.odin で設定
	token_set:       map[string]bool,     // 全トークンのセット (O(1)検索用)
	rule_map:        map[string]int,      // 規則名 → rules配列のインデックス
}

grammar_destroy :: proc(g: ^Grammar) {
	delete(g.tokens)
	delete(g.term_tokens)
	for &pe in g.precedence {
		delete(pe.tokens)
	}
	delete(g.precedence)
	for &rule in g.rules {
		for &prod in rule.productions {
			delete(prod.symbols)
		}
		delete(rule.productions)
	}
	delete(g.rules)
	delete(g.expected_conflicts)
	delete(g.token_set)
	delete(g.rule_map)
}

grammar_add_token :: proc(g: ^Grammar, name: string) {
	append(&g.tokens, name)
}

grammar_add_term_token :: proc(g: ^Grammar, name: string) {
	append(&g.term_tokens, name)
}

grammar_add_precedence :: proc(g: ^Grammar, assoc: Assoc, tokens: [dynamic]string) {
	level := len(g.precedence) + 1
	append(&g.precedence, Prec_Entry{level = level, assoc = assoc, tokens = tokens})
}

grammar_add_rule :: proc(g: ^Grammar, rule: Rule) {
	if len(g.rules) == 0 {
		g.start_rule = rule.name
	}
	append(&g.rules, rule)
}

grammar_is_terminal :: proc(g: ^Grammar, name: string) -> bool {
	return name in g.token_set
}

grammar_find_rule :: proc(g: ^Grammar, name: string) -> (^Rule, bool) {
	idx, ok := g.rule_map[name]
	if !ok {
		return nil, false
	}
	return &g.rules[idx], true
}
