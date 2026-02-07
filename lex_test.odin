package llpgen

import "core:testing"

// ヘルパー: 全トークンを取得する
@(private = "file")
lex_all_tokens :: proc(input: string) -> [dynamic]Llp_Token {
	lex: Lex
	lex_init(&lex, input)
	tokens: [dynamic]Llp_Token
	for {
		tok := lex_scan_token(&lex)
		append(&tokens, tok)
		if tok.type == .Eof || tok.type == .Error {
			break
		}
	}
	return tokens
}

@(test)
lex_directive_tokens_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens("%token Eof Error")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 4, "Expected 4 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Dir_Token, "Expected Dir_Token")
	testing.expectf(t, tokens[0].lexeme == "%token", "Expected '%%token', got '%s'", tokens[0].lexeme)
	testing.expect(t, tokens[1].type == .Ident, "Expected Ident")
	testing.expectf(t, tokens[1].lexeme == "Eof", "Expected 'Eof', got '%s'", tokens[1].lexeme)
	testing.expect(t, tokens[2].type == .Ident, "Expected Ident")
	testing.expectf(t, tokens[2].lexeme == "Error", "Expected 'Error', got '%s'", tokens[2].lexeme)
	testing.expect(t, tokens[3].type == .Eof, "Expected Eof")
}

@(test)
lex_all_directives_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens("%package %token %left %right %nonassoc %term")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 7, "Expected 7 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Dir_Package, "Expected Dir_Package")
	testing.expect(t, tokens[1].type == .Dir_Token, "Expected Dir_Token")
	testing.expect(t, tokens[2].type == .Dir_Left, "Expected Dir_Left")
	testing.expect(t, tokens[3].type == .Dir_Right, "Expected Dir_Right")
	testing.expect(t, tokens[4].type == .Dir_Nonassoc, "Expected Dir_Nonassoc")
	testing.expect(t, tokens[5].type == .Dir_Term, "Expected Dir_Term")
	testing.expect(t, tokens[6].type == .Eof, "Expected Eof")
}

@(test)
lex_separator_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens("%%")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 2, "Expected 2 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Separator, "Expected Separator")
	testing.expectf(t, tokens[0].lexeme == "%%", "Expected '%%%%', got '%s'", tokens[0].lexeme)
	testing.expect(t, tokens[1].type == .Eof, "Expected Eof")
}

@(test)
lex_grammar_rule_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens("program : topstmt_list ;")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 5, "Expected 5 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Ident, "Expected Ident for 'program'")
	testing.expectf(t, tokens[0].lexeme == "program", "Expected 'program', got '%s'", tokens[0].lexeme)
	testing.expect(t, tokens[1].type == .Colon, "Expected Colon")
	testing.expect(t, tokens[2].type == .Ident, "Expected Ident for 'topstmt_list'")
	testing.expectf(t, tokens[2].lexeme == "topstmt_list", "Expected 'topstmt_list', got '%s'", tokens[2].lexeme)
	testing.expect(t, tokens[3].type == .Semicolon, "Expected Semicolon")
	testing.expect(t, tokens[4].type == .Eof, "Expected Eof")
}

@(test)
lex_pipe_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens("expr : Number | Ident ;")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 7, "Expected 7 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Ident, "Expected Ident")
	testing.expect(t, tokens[1].type == .Colon, "Expected Colon")
	testing.expect(t, tokens[2].type == .Ident, "Expected Ident")
	testing.expect(t, tokens[3].type == .Pipe, "Expected Pipe")
	testing.expect(t, tokens[4].type == .Ident, "Expected Ident")
	testing.expect(t, tokens[5].type == .Semicolon, "Expected Semicolon")
	testing.expect(t, tokens[6].type == .Eof, "Expected Eof")
}

@(test)
lex_comment_skip_test :: proc(t: ^testing.T) {
	input := `// this is a comment
%token Eof`
	tokens := lex_all_tokens(input)
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 3, "Expected 3 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Dir_Token, "Expected Dir_Token")
	testing.expect(t, tokens[1].type == .Ident, "Expected Ident")
	testing.expectf(t, tokens[1].lexeme == "Eof", "Expected 'Eof', got '%s'", tokens[1].lexeme)
	testing.expect(t, tokens[2].type == .Eof, "Expected Eof")
}

@(test)
lex_line_tracking_test :: proc(t: ^testing.T) {
	input := `%token Eof
%left Plus
%%`
	lex: Lex
	lex_init(&lex, input)

	tok1 := lex_scan_token(&lex) // %token
	testing.expectf(t, tok1.line == 1, "Expected line 1, got %d", tok1.line)

	_ = lex_scan_token(&lex) // Eof

	tok3 := lex_scan_token(&lex) // %left
	testing.expectf(t, tok3.line == 2, "Expected line 2, got %d", tok3.line)

	_ = lex_scan_token(&lex) // Plus

	tok5 := lex_scan_token(&lex) // %%
	testing.expectf(t, tok5.line == 3, "Expected line 3, got %d", tok5.line)
}

@(test)
lex_full_example_test :: proc(t: ^testing.T) {
	input := `%package calc

%token Eof Error
%token Number Plus Minus
%left Plus Minus

%%
expr : expr Plus term
     | term
     ;
%%`
	tokens := lex_all_tokens(input)
	defer delete(tokens)

	// 期待するトークン列:
	// Dir_Package, Ident(calc),
	// Dir_Token, Ident(Eof), Ident(Error),
	// Dir_Token, Ident(Number), Ident(Plus), Ident(Minus),
	// Dir_Left, Ident(Plus), Ident(Minus),
	// Separator,
	// Ident(expr), Colon, Ident(expr), Ident(Plus), Ident(term),
	// Pipe, Ident(term),
	// Semicolon,
	// Separator,
	// Eof
	expected_types := [?]Llp_Token_Type{
		.Dir_Package, .Ident,
		.Dir_Token, .Ident, .Ident,
		.Dir_Token, .Ident, .Ident, .Ident,
		.Dir_Left, .Ident, .Ident,
		.Separator,
		.Ident, .Colon, .Ident, .Ident, .Ident,
		.Pipe, .Ident,
		.Semicolon,
		.Separator,
		.Eof,
	}

	testing.expectf(t, len(tokens) == len(expected_types), "Expected %d tokens, got %d", len(expected_types), len(tokens))

	for i := 0; i < min(len(tokens), len(expected_types)); i += 1 {
		testing.expectf(
			t,
			tokens[i].type == expected_types[i],
			"Token %d: expected %v, got %v (lexeme='%s')",
			i,
			expected_types[i],
			tokens[i].type,
			tokens[i].lexeme,
		)
	}
}

@(test)
lex_empty_input_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens("")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 1, "Expected 1 token, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Eof, "Expected Eof")
}

@(test)
lex_string_literal_test :: proc(t: ^testing.T) {
	tokens := lex_all_tokens(`"hello"`)
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 2, "Expected 2 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .String_Lit, "Expected String_Lit")
	testing.expectf(t, tokens[0].lexeme == `"hello"`, "Expected '\"hello\"', got '%s'", tokens[0].lexeme)
}

@(test)
lex_column_tracking_test :: proc(t: ^testing.T) {
	lex: Lex
	lex_init(&lex, "%token Eof")

	tok1 := lex_scan_token(&lex) // %token
	testing.expectf(t, tok1.column == 1, "Expected column 1, got %d", tok1.column)

	tok2 := lex_scan_token(&lex) // Eof
	testing.expectf(t, tok2.column == 8, "Expected column 8, got %d", tok2.column)
}

@(test)
lex_multiple_comments_test :: proc(t: ^testing.T) {
	input := `// comment 1
// comment 2
%token Eof`
	tokens := lex_all_tokens(input)
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 3, "Expected 3 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Dir_Token, "Expected Dir_Token")
	testing.expect(t, tokens[1].type == .Ident, "Expected Ident(Eof)")
	testing.expect(t, tokens[2].type == .Eof, "Expected Eof")
}

@(test)
lex_empty_production_test :: proc(t: ^testing.T) {
	// 空の production は | と ; の間に何もない場合
	tokens := lex_all_tokens("args : expr | ;")
	defer delete(tokens)

	testing.expectf(t, len(tokens) == 6, "Expected 6 tokens, got %d", len(tokens))
	testing.expect(t, tokens[0].type == .Ident, "Expected Ident(args)")
	testing.expect(t, tokens[1].type == .Colon, "Expected Colon")
	testing.expect(t, tokens[2].type == .Ident, "Expected Ident(expr)")
	testing.expect(t, tokens[3].type == .Pipe, "Expected Pipe")
	testing.expect(t, tokens[4].type == .Semicolon, "Expected Semicolon")
	testing.expect(t, tokens[5].type == .Eof, "Expected Eof")
}
