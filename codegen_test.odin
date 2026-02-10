package llpgen

import "core:strings"
import "core:testing"

// ヘルパー: 文法をパース → 分析 → コード生成 (parser コード)
@(private = "file")
generate_code_from_input :: proc(input: string) -> (string, bool) {
	g, ok := parse_llp(input)
	if !ok {
		grammar_destroy(&g)
		return "", false
	}
	grammar_build_indices(&g)

	firsts := compute_first_sets(&g)
	follows := compute_follow_sets(&g, firsts)
	states := generate_states(&g)

	ci := Codegen_Input{
		grammar = &g,
		firsts  = &firsts,
		follows = &follows,
		states  = &states,
	}

	code := codegen(ci)

	// cleanup
	grammar_destroy(&g)
	for k, &v in firsts {
		delete(v)
	}
	delete(firsts)
	for k, &v in follows {
		delete(v)
	}
	delete(follows)
	states_destroy(&states)

	return code, true
}

// ヘルパー: 文法をパース → 分析 → token コード生成
@(private = "file")
generate_token_code_from_input :: proc(input: string) -> (string, bool) {
	g, ok := parse_llp(input)
	if !ok {
		grammar_destroy(&g)
		return "", false
	}
	grammar_build_indices(&g)

	code := codegen_token(&g)

	grammar_destroy(&g)
	return code, true
}

@(test)
codegen_minimal_grammar_test :: proc(t: ^testing.T) {
	input := `%package minimal
%token Eof Number
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")
	testing.expectf(t, len(code) > 0, "Expected non-empty code")

	// package 宣言が含まれている
	testing.expect(t, strings.contains(code, "package minimal"), "Expected 'package minimal'")

	// Parse_State_Kind enum が含まれている
	testing.expect(t, strings.contains(code, "Parse_State_Kind :: enum"), "Expected Parse_State_Kind enum")
	testing.expect(t, strings.contains(code, "Start,"), "Expected Start state")
	testing.expect(t, strings.contains(code, "End,"), "Expected End state")
	testing.expect(t, strings.contains(code, "Error,"), "Expected Error state")
	testing.expect(t, strings.contains(code, "Expr,"), "Expected Expr state")

	// 共通型
	testing.expect(t, strings.contains(code, "Parse_Loop_Action :: enum"), "Expected Parse_Loop_Action")
	testing.expect(t, strings.contains(code, "Parse_Result :: enum"), "Expected Parse_Result")
	testing.expect(t, strings.contains(code, "Parser :: struct"), "Expected Parser struct")

	// コア関数
	testing.expect(t, strings.contains(code, "parser_new :: proc"), "Expected parser_new")
	testing.expect(t, strings.contains(code, "parser_destroy :: proc"), "Expected parser_destroy")
	testing.expect(t, strings.contains(code, "parser_push_token :: proc"), "Expected parser_push_token")

	// parse_start と parse_expr
	testing.expect(t, strings.contains(code, "parse_start :: proc"), "Expected parse_start")
	testing.expect(t, strings.contains(code, "parse_expr :: proc"), "Expected parse_expr")
}

@(test)
codegen_calc_grammar_test :: proc(t: ^testing.T) {
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
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// package
	testing.expect(t, strings.contains(code, "package calc"), "Expected 'package calc'")

	// 各規則の parse 関数が生成されている
	testing.expect(t, strings.contains(code, "parse_expr :: proc"), "Expected parse_expr")
	testing.expect(t, strings.contains(code, "parse_term :: proc"), "Expected parse_term")
	testing.expect(t, strings.contains(code, "parse_factor :: proc"), "Expected parse_factor")
	testing.expect(t, strings.contains(code, "parse_args :: proc"), "Expected parse_args")

	// ε production のハンドリング (args)
	testing.expect(t, strings.contains(code, "ε production"), "Expected ε production handling in args")

	// ディスパッチに各規則が含まれる
	testing.expect(t, strings.contains(code, "parse_start(p, &tk)"), "Expected parse_start dispatch")
	testing.expect(t, strings.contains(code, "parse_expr(p, &tk)"), "Expected parse_expr dispatch")
	testing.expect(t, strings.contains(code, "parse_term(p, &tk)"), "Expected parse_term dispatch")
	testing.expect(t, strings.contains(code, "parse_factor(p, &tk)"), "Expected parse_factor dispatch")
	testing.expect(t, strings.contains(code, "parse_args(p, &tk)"), "Expected parse_args dispatch")
}

@(test)
codegen_with_term_tokens_test :: proc(t: ^testing.T) {
	input := `%package streem
%token Eof Error Number Newline Semicolon
%term Newline Semicolon
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// is_term, consume_term, consumed は parser ファイルに含まれない (token ファイルに移動済み)
	testing.expect(t, !strings.contains(code, "is_term :: proc"), "is_term should not be in parser code")
	testing.expect(t, !strings.contains(code, "consume_term :: proc"), "consume_term should not be in parser code")
	testing.expect(t, !strings.contains(code, "consumed :: proc"), "consumed should not be in parser code")
}

@(test)
codegen_output_valid_odin_test :: proc(t: ^testing.T) {
	input := `%package test_pkg
%token Eof Number Plus
%%
expr : Number
     | expr Plus Number
     ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// コードを一時ファイルに書き出して odin check で検証
	// テスト内ではファイルIO不可なため、基本的な構文チェックのみ行う

	// 中括弧のバランスチェック
	brace_count := 0
	for ch in code {
		if ch == '{' { brace_count += 1 }
		if ch == '}' { brace_count -= 1 }
	}
	testing.expectf(t, brace_count == 0, "Unbalanced braces: count=%d", brace_count)

	// パーレンのバランスチェック
	paren_count := 0
	for ch in code {
		if ch == '(' { paren_count += 1 }
		if ch == ')' { paren_count -= 1 }
	}
	testing.expectf(t, paren_count == 0, "Unbalanced parens: count=%d", paren_count)
}

@(test)
codegen_multiple_rules_states_test :: proc(t: ^testing.T) {
	input := `%package multi
%token Eof Number Plus Minus Asterisk Slash Left_Paren Right_Paren
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
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// is_between ベースのディスパッチが生成されている
	testing.expect(t, strings.contains(code, "is_between"), "Expected is_between usage")

	// parser_begin が Nonterminal 呼び出しで使われている
	testing.expect(t, strings.contains(code, "parser_begin(p,"), "Expected parser_begin calls")

	// consumed が Terminal 消費で使われている
	testing.expect(t, strings.contains(code, "consumed(tk,"), "Expected consumed calls")
}

// ========================================================================
// Token codegen テスト
// ========================================================================

@(test)
codegen_token_basic_test :: proc(t: ^testing.T) {
	input := `%package test_pkg
%token Eof Error Number Plus
%%
expr : Number ;
%%`
	code, ok := generate_token_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected token codegen success")
	testing.expectf(t, len(code) > 0, "Expected non-empty token code")

	// package 宣言
	testing.expect(t, strings.contains(code, "package test_pkg"), "Expected 'package test_pkg'")

	// 自動生成コメント
	testing.expect(t, strings.contains(code, "自動生成"), "Expected auto-generated comment")

	// Token_Type enum
	testing.expect(t, strings.contains(code, "Token_Type :: enum"), "Expected Token_Type enum")
	testing.expect(t, strings.contains(code, "Eof,"), "Expected Eof member")
	testing.expect(t, strings.contains(code, "Error,"), "Expected Error member")
	testing.expect(t, strings.contains(code, "Number,"), "Expected Number member")
	testing.expect(t, strings.contains(code, "Plus,"), "Expected Plus member")

	// Token struct
	testing.expect(t, strings.contains(code, "Token :: struct"), "Expected Token struct")
	testing.expect(t, strings.contains(code, "type:"), "Expected type field")
	testing.expect(t, strings.contains(code, "consumed:"), "Expected consumed field")
	testing.expect(t, strings.contains(code, "lexeme:"), "Expected lexeme field")
	testing.expect(t, strings.contains(code, "using pos: Pos,"), "Expected using pos: Pos field")

	// consumed 関数
	testing.expect(t, strings.contains(code, "consumed :: proc"), "Expected consumed function")
}

@(test)
codegen_token_custom_type_test :: proc(t: ^testing.T) {
	input := `%package custom
%token Eof Error Number
%token_type Tok
%%
expr : Number ;
%%`
	code, ok := generate_token_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected token codegen success")

	// カスタム型名が使われている
	testing.expect(t, strings.contains(code, "Tok_Type :: enum"), "Expected Tok_Type enum")
	testing.expect(t, strings.contains(code, "Tok :: struct"), "Expected Tok struct")
	testing.expect(t, strings.contains(code, "consumed :: proc(actual: ^Tok"), "Expected consumed with custom type")
}

@(test)
codegen_token_with_term_test :: proc(t: ^testing.T) {
	input := `%package streem
%token Eof Error Number Newline Semicolon
%term Newline Semicolon
%%
expr : Number ;
%%`
	code, ok := generate_token_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected token codegen success")

	// is_term と consume_term が生成されている
	testing.expect(t, strings.contains(code, "is_term :: proc"), "Expected is_term function")
	testing.expect(t, strings.contains(code, "consume_term :: proc"), "Expected consume_term function")
	testing.expect(t, strings.contains(code, ".Newline"), "Expected Newline in is_term")
	testing.expect(t, strings.contains(code, ".Semicolon"), "Expected Semicolon in is_term")
}

@(test)
codegen_token_no_term_test :: proc(t: ^testing.T) {
	input := `%package simple
%token Eof Error Number
%%
expr : Number ;
%%`
	code, ok := generate_token_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected token codegen success")

	// %term 未指定時は is_term/consume_term が生成されない
	testing.expect(t, !strings.contains(code, "is_term :: proc"), "is_term should not be generated without %term")
	testing.expect(t, !strings.contains(code, "consume_term :: proc"), "consume_term should not be generated without %term")

	// consumed は常に生成される
	testing.expect(t, strings.contains(code, "consumed :: proc"), "Expected consumed function")
}
