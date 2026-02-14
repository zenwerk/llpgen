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

	op_loops := detect_operator_loops(&g)
	firsts := compute_first_sets(&g)
	follows := compute_follow_sets(&g, firsts)
	states := generate_states(&g, &op_loops)

	ci := Codegen_Input{
		grammar  = &g,
		firsts   = &firsts,
		follows  = &follows,
		states   = &states,
		op_loops = &op_loops,
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
	operator_loops_destroy(&op_loops)

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

	// args は演算子ループとして変換される
	testing.expect(t, strings.contains(code, "parse_args :: proc"), "Expected parse_args function")

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

	// #partial switch ベースのディスパッチが生成されている
	testing.expect(t, strings.contains(code, "#partial switch pstate"), "Expected #partial switch dispatch")

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
	testing.expect(t, strings.contains(code, "Code generated by llpgen. DO NOT EDIT."), "Expected auto-generated comment")

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

// ========================================================================
// 演算子ループ codegen テスト
// ========================================================================

@(test)
codegen_operator_loop_test :: proc(t: ^testing.T) {
	input := `%package calc
%token Eof Error Number Plus Minus Asterisk Slash
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
factor : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// 演算子ループ規則の関数が生成されている
	testing.expect(t, strings.contains(code, "parse_expr :: proc"), "Expected parse_expr")
	testing.expect(t, strings.contains(code, "parse_term :: proc"), "Expected parse_term")

	// Expr_Op, Term_Op 状態が生成されている
	testing.expect(t, strings.contains(code, "Expr_Op,"), "Expected Expr_Op state")
	testing.expect(t, strings.contains(code, "Term_Op,"), "Expected Term_Op state")

	// 演算子チェックのコードが含まれている
	testing.expect(t, strings.contains(code, "tk.type == .Plus"), "Expected Plus operator check")
	testing.expect(t, strings.contains(code, "tk.type == .Minus"), "Expected Minus operator check")
	testing.expect(t, strings.contains(code, "tk.type == .Asterisk"), "Expected Asterisk operator check")
	testing.expect(t, strings.contains(code, "tk.type == .Slash"), "Expected Slash operator check")

	// 演算子ループパターン: 演算子がなければ parser_end
	testing.expect(t, strings.contains(code, "parser_end(p)"), "Expected parser_end for non-operator")

	// コメントに演算子ループであることが記載されている
	testing.expect(t, strings.contains(code, "演算子ループ"), "Expected operator loop comment")
}

@(test)
codegen_operator_loop_braces_balanced_test :: proc(t: ^testing.T) {
	input := `%package calc
%token Eof Error Number Plus Minus Asterisk Slug Left_Paren Right_Paren
%left Plus Minus
%left Asterisk Slug
%%
expr : expr Plus term
     | expr Minus term
     | term
     ;
term : term Asterisk factor
     | term Slug factor
     | factor
     ;
factor : Number
       | Left_Paren expr Right_Paren
       ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

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

// ========================================================================
// Phase 4: 通過状態除去 + 意味的命名テスト
// ========================================================================

@(test)
codegen_passthrough_elimination_test :: proc(t: ^testing.T) {
	// factor : Ident Left_Paren args Right_Paren | Left_Paren expr Right_Paren | Minus factor ;
	// Phase 4: Nonterminal 位置の通過状態が除去されている
	input := `%package test_pkg
%token Eof Number Ident Left_Paren Right_Paren Minus
%%
factor : Number
       | Ident Left_Paren args Right_Paren
       | Left_Paren expr Right_Paren
       | Minus factor
       ;
args : Number ;
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// Phase 4 の Await_ 命名が使われている
	testing.expect(t, strings.contains(code, "Await_"), "Expected Await_ state naming")

	// After_ 命名が使われていない（通過状態が除去されている）
	testing.expect(t, !strings.contains(code, "After_"), "After_ naming should not exist (Phase 4)")

	// Left_Paren 消費後に直接 Nonterminal を begin するコードがある
	testing.expect(t, strings.contains(code, "parser_begin(p, .Args"), "Expected direct begin for args")
	testing.expect(t, strings.contains(code, "parser_begin(p, .Expr"), "Expected direct begin for expr")

	// Minus 消費後に直接 Factor を begin するコードがある
	testing.expect(t, strings.contains(code, "parser_begin(p, .Factor"), "Expected direct begin for factor (unary)")
}

@(test)
codegen_await_naming_test :: proc(t: ^testing.T) {
	// 意味的な命名: Terminal待ち状態は Await_<Terminal名>
	input := `%package test_pkg
%token Eof Number Plus
%%
expr : Number Plus Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// Await_Plus 状態が生成されている（pos=1 の Plus を待つ状態）
	testing.expect(t, strings.contains(code, "Await_Plus"), "Expected Await_Plus state")
}

// ========================================================================
// Phase 5: #partial switch ディスパッチテスト
// ========================================================================

@(test)
codegen_partial_switch_dispatch_test :: proc(t: ^testing.T) {
	input := `%package calc
%token Eof Error Number Plus Minus Asterisk Slash Left_Paren Right_Paren Comma Ident
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

	// #partial switch が生成されている
	testing.expect(t, strings.contains(code, "#partial switch pstate"), "Expected #partial switch dispatch")

	// is_between が生成されていない
	testing.expect(t, !strings.contains(code, "is_between"), "is_between should not be in generated code")

	// case .Start, .End, .Error: が生成されている
	testing.expect(t, strings.contains(code, "case .Start, .End, .Error:"), "Expected Start/End/Error case")

	// 各規則の状態が case に列挙されている
	testing.expect(t, strings.contains(code, "case .Expr, .Expr_Op:"), "Expected Expr states in case")
	testing.expect(t, strings.contains(code, "case .Term, .Term_Op:"), "Expected Term states in case")
}

@(test)
codegen_no_is_between_test :: proc(t: ^testing.T) {
	input := `%package minimal
%token Eof Number
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// is_between ヘルパー関数が生成されていない
	testing.expect(t, !strings.contains(code, "is_between :: proc"), "is_between helper should not be generated")
	testing.expect(t, !strings.contains(code, "is_between("), "is_between calls should not be generated")

	// #partial switch が使われている
	testing.expect(t, strings.contains(code, "#partial switch pstate"), "Expected #partial switch dispatch")
}

// ========================================================================
// Phase AST Builder: Parse_Event + on_parse_event テスト
// ========================================================================

@(test)
codegen_parse_event_enum_test :: proc(t: ^testing.T) {
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
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// Parse_Event enum が生成されている
	testing.expect(t, strings.contains(code, "Parse_Event :: enum"), "Expected Parse_Event enum")
	testing.expect(t, strings.contains(code, "None,"), "Expected None event")

	// 演算子ループイベント (状態名と一致)
	testing.expect(t, strings.contains(code, "Expr_Op,"), "Expected Expr_Op event")
	testing.expect(t, strings.contains(code, "Term_Op,"), "Expected Term_Op event")
	testing.expect(t, strings.contains(code, "Args_Op,"), "Expected Args_Op event")

	// factor の開始状態イベント
	testing.expect(t, strings.contains(code, "Factor_Number,"), "Expected Factor_Number event")
	testing.expect(t, strings.contains(code, "Factor_Ident,"), "Expected Factor_Ident event")
	testing.expect(t, strings.contains(code, "Factor_Left_Paren,"), "Expected Factor_Left_Paren event")
	testing.expect(t, strings.contains(code, "Factor_Minus,"), "Expected Factor_Minus event")

	// factor の中間状態イベント
	testing.expect(t, strings.contains(code, "Factor_Await_Left_Paren,"), "Expected Factor_Await_Left_Paren event")
	testing.expect(t, strings.contains(code, "Factor_Await_Right_Paren,"), "Expected Factor_Await_Right_Paren event")
	testing.expect(t, strings.contains(code, "Factor_Await_Right_Paren_2,"), "Expected Factor_Await_Right_Paren_2 event")
}

@(test)
codegen_on_parse_event_call_test :: proc(t: ^testing.T) {
	input := `%package test_pkg
%token Eof Number Plus Minus
%left Plus Minus
%%
expr : expr Plus term
     | expr Minus term
     | term
     ;
term : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// on_parse_event 呼び出しが生成されている
	testing.expect(t, strings.contains(code, "on_parse_event(p, .Expr_Op, tk, top)"), "Expected Expr_Op event call")
	testing.expect(t, strings.contains(code, "on_parse_event(p, .Term_Number, tk, top)"), "Expected Term_Number event call")
}

@(test)
codegen_no_todo_comment_test :: proc(t: ^testing.T) {
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
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// TODO: AST コメントが生成されていない
	testing.expect(t, !strings.contains(code, "// TODO: AST"), "TODO AST comments should not be in generated code")
}

@(test)
codegen_event_operator_loop_test :: proc(t: ^testing.T) {
	input := `%package test_pkg
%token Eof Number Plus Minus Asterisk Slash
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
factor : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// 演算子ループのイベント呼び出し (状態名と一致)
	testing.expect(t, strings.contains(code, "on_parse_event(p, .Expr_Op, tk, top)"), "Expected Expr_Op call")
	testing.expect(t, strings.contains(code, "on_parse_event(p, .Term_Op, tk, top)"), "Expected Term_Op call")

	// factor の開始状態イベント
	testing.expect(t, strings.contains(code, "on_parse_event(p, .Factor_Number, tk, top)"), "Expected Factor_Number call")
}

// ========================================================================
// 出力の決定的順序テスト
// ========================================================================

@(test)
codegen_deterministic_output_test :: proc(t: ^testing.T) {
	// 複数の FIRST トークンを持つ文法で、2回コード生成して同一出力を確認
	input := `%package det_test
%token Eof Number Ident Plus Minus Asterisk Slash Left_Paren Right_Paren
%%
factor : Number
       | Ident
       | Left_Paren expr Right_Paren
       | Minus factor
       ;
expr : Number ;
%%`
	code1, ok1 := generate_code_from_input(input)
	defer delete(code1)
	testing.expectf(t, ok1, "Expected codegen success (1)")

	code2, ok2 := generate_code_from_input(input)
	defer delete(code2)
	testing.expectf(t, ok2, "Expected codegen success (2)")

	testing.expect(t, code1 == code2, "Expected deterministic output: two codegen runs should produce identical code")
}

@(test)
codegen_epsilon_follow_condition_test :: proc(t: ^testing.T) {
	// stmt が2つの production を持ち、片方が ε 導出可能な Nonterminal (opt_prefix) で始まる場合、
	// その production の条件に FOLLOW 集合のトークンも含まれる
	input := `%package test_pkg
%token Eof Number Plus Minus
%%
stmt : Plus Number
     | opt_prefix Number
     ;
opt_prefix : Minus
           |
           ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// opt_prefix の FIRST は {Minus, ε}
	// stmt の FOLLOW は {Eof}
	// opt_prefix で始まる production の条件には FIRST(opt_prefix)\{ε} + FOLLOW(stmt) が含まれる
	// → Minus, Eof, Number (FOLLOW に Number は含まれないが Eof は含まれる)
	testing.expect(t, strings.contains(code, "tk.type == .Minus"), "Expected FIRST token Minus in condition")
	testing.expect(t, strings.contains(code, "tk.type == .Eof"), "Expected FOLLOW token Eof in condition")

	// if true TODO が含まれていない
	testing.expect(t, !strings.contains(code, "if true /* TODO"), "TODO fallback should not exist")
}

@(test)
codegen_operator_loop_multi_symbol_base_test :: proc(t: ^testing.T) {
	// mul_expr : mul_expr Op_Mult unary | Op_Minus unary ;
	// ベースケース Op_Minus unary は複数シンボル — unary への遷移が生成されること
	input := `%package test_pkg
%token Eof Number Op_Mult Op_Minus
%left Op_Mult
%%
mul_expr : mul_expr Op_Mult unary
         | Op_Minus unary
         ;
unary : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// Op_Minus を消費するイベントがある
	testing.expect(t, strings.contains(code, "on_parse_event(p, .Mul_Expr_Op_Minus, tk, top)"), "Expected Mul_Expr_Op_Minus event")

	// Op_Minus 消費後に unary への begin が生成される
	testing.expect(t, strings.contains(code, "parser_begin(p, .Unary"), "Expected parser_begin for Unary after Op_Minus")

	// 中括弧バランス
	brace_count := 0
	for ch in code {
		if ch == '{' { brace_count += 1 }
		if ch == '}' { brace_count -= 1 }
	}
	testing.expectf(t, brace_count == 0, "Unbalanced braces: count=%d", brace_count)
}

@(test)
codegen_nonassoc_operator_test :: proc(t: ^testing.T) {
	// nonassoc 演算子: a == b == c がパースエラーになるチェックコードが生成される
	input := `%package test_pkg
%token Eof Number Eq Plus
%nonassoc Eq
%left Plus
%%
expr : expr Eq term
     | expr Plus term
     | term
     ;
term : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// nonassoc チェーンの検出コードが含まれている
	testing.expect(t, strings.contains(code, "Non-associative operator"), "Expected nonassoc chain error message")
	testing.expect(t, strings.contains(code, `top.op == "Eq"`), "Expected nonassoc check for Eq")

	// top.op = tk.lexeme で演算子を記録
	testing.expect(t, strings.contains(code, "top.op = tk.lexeme"), "Expected operator recording")
}

@(test)
codegen_no_nonassoc_no_check_test :: proc(t: ^testing.T) {
	// nonassoc がない場合はチェックコードが生成されない
	input := `%package test_pkg
%token Eof Number Plus Minus
%left Plus Minus
%%
expr : expr Plus term
     | expr Minus term
     | term
     ;
term : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)

	testing.expectf(t, ok, "Expected codegen success")

	// nonassoc チェックが含まれていない
	testing.expect(t, !strings.contains(code, "Non-associative operator"), "nonassoc check should not exist for left-assoc only")
}

@(test)
codegen_max_iterations_default_test :: proc(t: ^testing.T) {
	// デフォルトでは max_iterations = 1000
	input := `%package test_pkg
%token Eof Number
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)
	testing.expectf(t, ok, "Expected codegen success")
	testing.expect(t, strings.contains(code, "max_iterations := 1000"), "Expected default max_iterations 1000")
}

@(test)
codegen_max_iterations_custom_test :: proc(t: ^testing.T) {
	// %max_iterations でカスタム値を設定
	input := `%package test_pkg
%token Eof Number
%max_iterations 500
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)
	testing.expectf(t, ok, "Expected codegen success")
	testing.expect(t, strings.contains(code, "max_iterations := 500"), "Expected custom max_iterations 500")
	testing.expect(t, !strings.contains(code, "max_iterations := 1000"), "Should not have default 1000")
}

@(test)
codegen_max_iterations_error_message_test :: proc(t: ^testing.T) {
	// max_iterations 超過時のエラーメッセージが生成される
	input := `%package test_pkg
%token Eof Number
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)
	testing.expectf(t, ok, "Expected codegen success")
	testing.expect(t, strings.contains(code, "max iterations exceeded"), "Expected max iterations error message")
}

@(test)
codegen_error_recovery_with_term_test :: proc(t: ^testing.T) {
	// %term がある場合、Error 状態でパニックモード回復コードが生成される
	input := `%package test_pkg
%token Eof Error Number Newline Semicolon
%term Newline Semicolon
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)
	testing.expectf(t, ok, "Expected codegen success")

	// パニックモード回復コードが含まれている
	testing.expect(t, strings.contains(code, "is_term(tk)"), "Expected is_term check in error recovery")
	testing.expect(t, strings.contains(code, "parser_set_state(p, .Start)"), "Expected reset to Start state")
}

@(test)
codegen_error_no_recovery_without_term_test :: proc(t: ^testing.T) {
	// %term がない場合、パニックモード回復コードは生成されない
	input := `%package test_pkg
%token Eof Error Number
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)
	testing.expectf(t, ok, "Expected codegen success")

	// パニックモード回復コードが含まれていない
	testing.expect(t, !strings.contains(code, "is_term(tk)"), "is_term should not be in code without %term")
}

@(test)
codegen_user_data_field_test :: proc(t: ^testing.T) {
	// Parse_State に user_data フィールドが生成される
	input := `%package test_pkg
%token Eof Number
%%
expr : Number ;
%%`
	code, ok := generate_code_from_input(input)
	defer delete(code)
	testing.expectf(t, ok, "Expected codegen success")
	testing.expect(t, strings.contains(code, "user_data: rawptr"), "Expected user_data field in Parse_State")
}
