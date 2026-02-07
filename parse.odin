package llpgen

import "core:fmt"

// DSLパーサー
Llp_Parser :: struct {
	lex:       Lex,
	current:   Llp_Token,
	error_msg: string,
	has_error: bool,
}

// パーサーの初期化と最初のトークン読み込み
llp_parser_init :: proc(p: ^Llp_Parser, input: string) {
	lex_init(&p.lex, input)
	p.has_error = false
	p.error_msg = ""
	llp_parser_advance(p)
}

// 次のトークンを読み込む
llp_parser_advance :: proc(p: ^Llp_Parser) {
	p.current = lex_scan_token(&p.lex)
}

// 期待するトークンタイプか確認し、一致すれば進める
llp_parser_expect :: proc(p: ^Llp_Parser, expected: Llp_Token_Type) -> bool {
	if p.current.type != expected {
		llp_parser_error(p, fmt.tprintf("expected %v, got %v (lexeme='%s') at line %d, column %d",
			expected, p.current.type, p.current.lexeme, p.current.line, p.current.column))
		return false
	}
	llp_parser_advance(p)
	return true
}

// エラーを設定
llp_parser_error :: proc(p: ^Llp_Parser, msg: string) {
	if !p.has_error {
		p.has_error = true
		p.error_msg = msg
	}
}

// .llp ファイルをパースして Grammar を返す
parse_llp :: proc(input: string) -> (Grammar, bool) {
	p: Llp_Parser
	llp_parser_init(&p, input)

	g: Grammar

	// ヘッダセクションをパース
	parse_header_section(&p, &g)
	if p.has_error {
		return g, false
	}

	// %% セパレータを期待
	if p.current.type != .Separator {
		llp_parser_error(&p, fmt.tprintf("expected %%%% separator, got %v at line %d", p.current.type, p.current.line))
		return g, false
	}
	llp_parser_advance(&p)

	// 文法規則セクションをパース
	parse_rules_section(&p, &g)
	if p.has_error {
		return g, false
	}

	// オプションの末尾 %% は無視（あれば以降も無視）

	return g, true
}

// ヘッダセクションのパース
parse_header_section :: proc(p: ^Llp_Parser, g: ^Grammar) {
	for !p.has_error {
		#partial switch p.current.type {
		case .Dir_Package:
			parse_package_directive(p, g)
		case .Dir_Token:
			parse_token_directive(p, g)
		case .Dir_Left:
			parse_precedence_directive(p, g, .Left)
		case .Dir_Right:
			parse_precedence_directive(p, g, .Right)
		case .Dir_Nonassoc:
			parse_precedence_directive(p, g, .None)
		case .Dir_Term:
			parse_term_directive(p, g)
		case .Separator:
			return // ヘッダ終了
		case .Eof:
			llp_parser_error(p, "unexpected end of input in header section")
			return
		case:
			llp_parser_error(p, fmt.tprintf("unexpected token %v (lexeme='%s') in header section at line %d",
				p.current.type, p.current.lexeme, p.current.line))
			return
		}
	}
}

// %package <ident>
parse_package_directive :: proc(p: ^Llp_Parser, g: ^Grammar) {
	llp_parser_advance(p) // %package を消費
	if p.current.type != .Ident {
		llp_parser_error(p, fmt.tprintf("expected package name after %%package at line %d", p.current.line))
		return
	}
	g.package_name = p.current.lexeme
	llp_parser_advance(p)
}

// %token <ident> <ident> ...
parse_token_directive :: proc(p: ^Llp_Parser, g: ^Grammar) {
	llp_parser_advance(p) // %token を消費
	count := 0
	for p.current.type == .Ident {
		grammar_add_token(g, p.current.lexeme)
		llp_parser_advance(p)
		count += 1
	}
	if count == 0 {
		llp_parser_error(p, fmt.tprintf("expected at least one token name after %%token at line %d", p.current.line))
	}
}

// %left / %right / %nonassoc <ident> <ident> ...
parse_precedence_directive :: proc(p: ^Llp_Parser, g: ^Grammar, assoc: Assoc) {
	llp_parser_advance(p) // ディレクティブを消費
	tokens: [dynamic]string
	for p.current.type == .Ident {
		append(&tokens, p.current.lexeme)
		llp_parser_advance(p)
	}
	if len(tokens) == 0 {
		llp_parser_error(p, fmt.tprintf("expected at least one token name after precedence directive at line %d", p.current.line))
		delete(tokens)
		return
	}
	grammar_add_precedence(g, assoc, tokens)
}

// %term <ident> <ident> ...
parse_term_directive :: proc(p: ^Llp_Parser, g: ^Grammar) {
	llp_parser_advance(p) // %term を消費
	count := 0
	for p.current.type == .Ident {
		grammar_add_term_token(g, p.current.lexeme)
		llp_parser_advance(p)
		count += 1
	}
	if count == 0 {
		llp_parser_error(p, fmt.tprintf("expected at least one token name after %%term at line %d", p.current.line))
	}
}

// 文法規則セクションのパース
parse_rules_section :: proc(p: ^Llp_Parser, g: ^Grammar) {
	for !p.has_error && p.current.type == .Ident {
		parse_rule(p, g)
	}
	// Eof または %% で終了
	if p.has_error {
		return
	}
	if p.current.type != .Eof && p.current.type != .Separator {
		llp_parser_error(p, fmt.tprintf("unexpected token %v at line %d in rules section",
			p.current.type, p.current.line))
	}
}

// 1つの文法規則をパース
// <ident> : <production> ( '|' <production> )* ';'
rule_destroy :: proc(rule: ^Rule) {
	for &prod in rule.productions {
		delete(prod.symbols)
	}
	delete(rule.productions)
}

parse_rule :: proc(p: ^Llp_Parser, g: ^Grammar) {
	// 規則名
	rule_name := p.current.lexeme
	llp_parser_advance(p)

	// ':'
	if p.current.type != .Colon {
		llp_parser_error(p, fmt.tprintf("expected ':' after rule name '%s' at line %d", rule_name, p.current.line))
		return
	}
	llp_parser_advance(p)

	rule: Rule
	rule.name = rule_name

	// 最初の production
	prod := parse_production(p)
	if p.has_error {
		delete(prod.symbols)
		rule_destroy(&rule)
		return
	}
	append(&rule.productions, prod)

	// '|' で区切られた追加の production
	for p.current.type == .Pipe {
		llp_parser_advance(p) // '|' を消費
		prod = parse_production(p)
		if p.has_error {
			delete(prod.symbols)
			rule_destroy(&rule)
			return
		}
		append(&rule.productions, prod)
	}

	// ';'
	if p.current.type != .Semicolon {
		llp_parser_error(p, fmt.tprintf("expected ';' at end of rule '%s' at line %d", rule_name, p.current.line))
		rule_destroy(&rule)
		return
	}
	llp_parser_advance(p)

	grammar_add_rule(g, rule)
}

// 1つの production (シンボル列) をパース
// シンボルが0個の場合はε (空) production
parse_production :: proc(p: ^Llp_Parser) -> Production {
	prod: Production
	for p.current.type == .Ident {
		sym := Symbol {
			kind = .Nonterminal, // この時点では仮。analysis で token_set と照合して確定する
			name = p.current.lexeme,
		}
		append(&prod.symbols, sym)
		llp_parser_advance(p)
	}
	// シンボルが0個ならε production (symbols は空のまま)
	return prod
}
