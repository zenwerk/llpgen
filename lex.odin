package llpgen

// レキサー
Lex :: struct {
	input:  string,
	offset: int,
	line:   int,
	column: int,
}

// レキサーの初期化
lex_init :: proc(lex: ^Lex, input: string) {
	lex.input = input
	lex.offset = 0
	lex.line = 1
	lex.column = 1
}

// 次の文字を覗き見る（消費しない）
lex_peek :: proc(lex: ^Lex) -> u8 {
	if lex.offset >= len(lex.input) {
		return 0
	}
	return lex.input[lex.offset]
}

// 次の文字を消費して返す
lex_advance :: proc(lex: ^Lex) -> u8 {
	if lex.offset >= len(lex.input) {
		return 0
	}
	ch := lex.input[lex.offset]
	lex.offset += 1
	lex.column += 1
	return ch
}

// トークンを作成する
lex_make_token :: proc(lex: ^Lex, t: Llp_Token_Type, lexeme: string, line: int, col: int) -> Llp_Token {
	return Llp_Token{type = t, lexeme = lexeme, line = line, column = col}
}

// 空白・改行をスキップし、行番号をトラッキングする
lex_skip_whitespace :: proc(lex: ^Lex) {
	for lex.offset < len(lex.input) {
		ch := lex.input[lex.offset]
		switch ch {
		case ' ', '\t', '\r':
			lex.offset += 1
			lex.column += 1
		case '\n':
			lex.offset += 1
			lex.line += 1
			lex.column = 1
		case:
			return
		}
	}
}

// 行コメント '//' をスキップする
lex_skip_line_comment :: proc(lex: ^Lex) {
	for lex.offset < len(lex.input) {
		ch := lex.input[lex.offset]
		if ch == '\n' {
			return // 改行は lex_skip_whitespace で処理する
		}
		lex.offset += 1
		lex.column += 1
	}
}

// 識別子を読む
lex_read_ident :: proc(lex: ^Lex, start: int) -> string {
	for lex.offset < len(lex.input) {
		ch := lex.input[lex.offset]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' {
			lex.offset += 1
			lex.column += 1
		} else {
			break
		}
	}
	return lex.input[start:lex.offset]
}

// ディレクティブキーワードのマッチ
lex_match_directive :: proc(word: string) -> Llp_Token_Type {
	switch word {
	case "package":
		return .Dir_Package
	case "token":
		return .Dir_Token
	case "left":
		return .Dir_Left
	case "right":
		return .Dir_Right
	case "nonassoc":
		return .Dir_Nonassoc
	case "term":
		return .Dir_Term
	case "token_type":
		return .Dir_Token_Type
	case "node_type":
		return .Dir_Node_Type
	case "expect_conflict":
		return .Dir_Expect_Conflict
	case "max_iterations":
		return .Dir_Max_Iterations
	case:
		return .Error
	}
}

// 文字列リテラルを読む
lex_read_string :: proc(lex: ^Lex, start: int) -> (string, bool) {
	// 開始の '"' は既に消費済み
	for lex.offset < len(lex.input) {
		ch := lex.input[lex.offset]
		if ch == '"' {
			lex.offset += 1
			lex.column += 1
			return lex.input[start:lex.offset], true
		}
		if ch == '\n' {
			return "", false // 文字列リテラル内の改行はエラー
		}
		lex.offset += 1
		lex.column += 1
	}
	return "", false // 閉じ引用符がない
}

// 次のトークンをスキャンする
lex_scan_token :: proc(lex: ^Lex) -> Llp_Token {
	for {
		lex_skip_whitespace(lex)

		// コメントチェック
		if lex.offset + 1 < len(lex.input) && lex.input[lex.offset] == '/' && lex.input[lex.offset + 1] == '/' {
			lex_skip_line_comment(lex)
			continue
		}

		break
	}

	// EOF チェック
	if lex.offset >= len(lex.input) {
		return lex_make_token(lex, .Eof, "", lex.line, lex.column)
	}

	line := lex.line
	col := lex.column
	start := lex.offset
	ch := lex_advance(lex)

	switch ch {
	case ':':
		return lex_make_token(lex, .Colon, ":", line, col)
	case '|':
		return lex_make_token(lex, .Pipe, "|", line, col)
	case ';':
		return lex_make_token(lex, .Semicolon, ";", line, col)
	case '%':
		// '%%' セパレータチェック
		if lex_peek(lex) == '%' {
			lex_advance(lex)
			return lex_make_token(lex, .Separator, "%%", line, col)
		}
		// ディレクティブ: '%' の後に識別子
		if lex.offset < len(lex.input) {
			next := lex.input[lex.offset]
			if (next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') {
				word_start := lex.offset
				word := lex_read_ident(lex, word_start)
				dir_type := lex_match_directive(word)
				if dir_type == .Error {
					return lex_make_token(lex, .Error, lex.input[start:lex.offset], line, col)
				}
				return lex_make_token(lex, dir_type, lex.input[start:lex.offset], line, col)
			}
		}
		return lex_make_token(lex, .Error, "%", line, col)
	case '"':
		str, ok := lex_read_string(lex, start)
		if !ok {
			return lex_make_token(lex, .Error, lex.input[start:lex.offset], line, col)
		}
		return lex_make_token(lex, .String_Lit, str, line, col)
	case:
		// 識別子
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' {
			ident := lex_read_ident(lex, start)
			return lex_make_token(lex, .Ident, ident, line, col)
		}
		// 数字 (ディレクティブの引数として使用)
		if ch >= '0' && ch <= '9' {
			for lex.offset < len(lex.input) {
				c := lex.input[lex.offset]
				if c >= '0' && c <= '9' {
					lex.offset += 1
					lex.column += 1
				} else {
					break
				}
			}
			return lex_make_token(lex, .Ident, lex.input[start:lex.offset], line, col)
		}
		// 不明な文字
		return lex_make_token(lex, .Error, lex.input[start:lex.offset], line, col)
	}
}
