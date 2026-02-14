package streem

import "core:unicode/utf8"

// ============================================================================
// レキサー
// ============================================================================
// streem_odin/lex.odin を参考に、生成パーサーの Token_Type に合わせたレキサー。
//
// 名称マッピング:
//   streem_odin         → llpgen Token_Type
//   .Lit_Int/.Lit_Float → .Lit_Number
//   .Left_Paren         → .Lparen
//   .Right_Paren        → .Rparen
//   .Left_Brace         → .Lbrace
//   .Right_Brace        → .Rbrace
//   .Left_Bracket       → .Lbracket
//   .Right_Bracket      → .Rbracket
//   .Op_Assign          → .Eq
//   .Colon              → (symbol の接頭辞として処理)

Lexer :: struct {
	source: string,
	offset: int,
	line:   int,
	column: int,
}

lexer_new :: proc(source: string) -> Lexer {
	return Lexer{source = source, offset = 0, line = 1, column = 1}
}

// ============================================================================
// 基本操作
// ============================================================================

@(private = "file")
lex_peek :: proc(l: ^Lexer) -> rune {
	if l.offset >= len(l.source) {
		return utf8.RUNE_EOF
	}
	r, _ := utf8.decode_rune_in_string(l.source[l.offset:])
	return r
}

@(private = "file")
lex_peek_n :: proc(l: ^Lexer, n: int) -> rune {
	offset := l.offset
	for i := 0; i < n; i += 1 {
		if offset >= len(l.source) {
			return utf8.RUNE_EOF
		}
		_, size := utf8.decode_rune_in_string(l.source[offset:])
		offset += size
	}
	if offset >= len(l.source) {
		return utf8.RUNE_EOF
	}
	r, _ := utf8.decode_rune_in_string(l.source[offset:])
	return r
}

@(private = "file")
lex_advance :: proc(l: ^Lexer) -> rune {
	r := lex_peek(l)
	if r != utf8.RUNE_ERROR && r != utf8.RUNE_EOF {
		size := utf8.rune_size(r)
		l.offset += size
		if r == '\n' {
			l.line += 1
			l.column = 1
		} else {
			l.column += 1
		}
	}
	return r
}

@(private = "file")
make_token :: proc(l: ^Lexer, type: Token_Type, lexeme: string, p: Pos) -> Token {
	return Token{type = type, lexeme = lexeme, pos = p, consumed = false}
}

// ============================================================================
// 文字種判定
// ============================================================================

@(private = "file")
is_ident_start :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_' || r >= 0x80
}

@(private = "file")
is_ident_char :: proc(r: rune) -> bool {
	return is_ident_start(r) || (r >= '0' && r <= '9')
}

@(private = "file")
is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

@(private = "file")
is_hex_digit :: proc(r: rune) -> bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
}

@(private = "file")
is_octal_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '7'
}

// ============================================================================
// TRAIL スキップ（演算子後の空白/改行/コメント読み飛ばし）
// ============================================================================

@(private = "file")
skip_trail :: proc(l: ^Lexer) {
	for {
		r := lex_peek(l)
		switch r {
		case ' ', '\t', '\n':
			lex_advance(l)
		case '#':
			for lex_peek(l) != '\n' && lex_peek(l) != utf8.RUNE_EOF {
				lex_advance(l)
			}
			if lex_peek(l) == '\n' {
				lex_advance(l)
			}
		case:
			return
		}
	}
}

// ============================================================================
// キーワードテーブル
// ============================================================================

@(private = "file")
lookup_keyword :: proc(lexeme: string) -> (Token_Type, bool) {
	switch lexeme {
	case "if":        return .Kw_If, true
	case "else":      return .Kw_Else, true
	case "case":      return .Kw_Case, true
	case "emit":      return .Kw_Emit, true
	case "skip":      return .Kw_Skip, true
	case "return":    return .Kw_Return, true
	case "namespace": return .Kw_Namespace, true
	case "class":     return .Kw_Class, true
	case "import":    return .Kw_Import, true
	case "def":       return .Kw_Def, true
	case "method":    return .Kw_Method, true
	case "new":       return .Kw_New, true
	case "nil":       return .Kw_Nil, true
	case "true":      return .Kw_True, true
	case "false":     return .Kw_False, true
	}
	return .Error, false
}

// ============================================================================
// 識別子/キーワードスキャン
// ============================================================================

@(private = "file")
scan_identifier :: proc(l: ^Lexer, start: int, p: Pos) -> Token {
	for is_ident_char(lex_peek(l)) {
		lex_advance(l)
	}
	lexeme := l.source[start:l.offset]

	// ラベルチェック (ident: で :: でない)
	if lex_peek(l) == ':' && lex_peek_n(l, 1) != ':' {
		lex_advance(l) // ':'を消費
		return make_token(l, .Label, lexeme, p)
	}

	// キーワードチェック
	if kw, ok := lookup_keyword(lexeme); ok {
		return make_token(l, kw, lexeme, p)
	}

	return make_token(l, .Ident, lexeme, p)
}

// ============================================================================
// 数値スキャン (Lit_Number に統合)
// ============================================================================

@(private = "file")
scan_number :: proc(l: ^Lexer, start: int, p: Pos) -> Token {
	// 0x hex / 0o octal
	if l.source[start] == '0' && l.offset - start == 1 {
		r := lex_peek(l)
		if r == 'x' || r == 'X' {
			lex_advance(l)
			for is_hex_digit(lex_peek(l)) {
				lex_advance(l)
			}
			return make_token(l, .Lit_Number, l.source[start:l.offset], p)
		}
		if r == 'o' || r == 'O' {
			lex_advance(l)
			for is_octal_digit(lex_peek(l)) {
				lex_advance(l)
			}
			return make_token(l, .Lit_Number, l.source[start:l.offset], p)
		}
	}

	// 整数部分
	for is_digit(lex_peek(l)) {
		lex_advance(l)
	}

	// 時刻リテラル判定 (4桁 + '.' + digit)
	digits_count := l.offset - start
	if digits_count == 4 && lex_peek(l) == '.' && is_digit(lex_peek_n(l, 1)) {
		saved_offset := l.offset
		saved_line := l.line
		saved_column := l.column

		lex_advance(l) // '.'
		month_start := l.offset
		for is_digit(lex_peek(l)) {
			lex_advance(l)
		}
		month_digits := l.offset - month_start

		if month_digits >= 1 && month_digits <= 2 && lex_peek(l) == '.' && is_digit(lex_peek_n(l, 1)) {
			lex_advance(l) // '.'
			for is_digit(lex_peek(l)) {
				lex_advance(l)
			}
			// 時刻リテラルの残りをスキャン
			return scan_time_rest(l, start, p)
		}

		// ロールバック
		l.offset = saved_offset
		l.line = saved_line
		l.column = saved_column
	}

	// 小数点 (ただし '..' や メソッド呼び出しの '.' は除く)
	if lex_peek(l) == '.' && is_digit(lex_peek_n(l, 1)) {
		lex_advance(l) // '.'
		for is_digit(lex_peek(l)) {
			lex_advance(l)
		}
	}

	// 指数部
	r := lex_peek(l)
	if r == 'e' || r == 'E' {
		lex_advance(l)
		r2 := lex_peek(l)
		if r2 == '+' || r2 == '-' {
			lex_advance(l)
		}
		for is_digit(lex_peek(l)) {
			lex_advance(l)
		}
	}

	return make_token(l, .Lit_Number, l.source[start:l.offset], p)
}

// ============================================================================
// 時刻リテラルの残りスキャン
// ============================================================================

@(private = "file")
scan_time_rest :: proc(l: ^Lexer, start: int, p: Pos) -> Token {
	// YYYY.MM.DD まではスキャン済み
	// オプション: Thh:mm:ss[.fraction][timezone]
	if lex_peek(l) == 'T' {
		lex_advance(l)
		for is_digit(lex_peek(l)) {
			lex_advance(l)
		}
		if lex_peek(l) == ':' {
			lex_advance(l)
			for is_digit(lex_peek(l)) {
				lex_advance(l)
			}
		}
		if lex_peek(l) == ':' {
			lex_advance(l)
			for is_digit(lex_peek(l)) {
				lex_advance(l)
			}
		}
		if lex_peek(l) == '.' {
			lex_advance(l)
			for is_digit(lex_peek(l)) {
				lex_advance(l)
			}
		}
		r := lex_peek(l)
		if r == 'Z' {
			lex_advance(l)
		} else if r == '+' || r == '-' {
			lex_advance(l)
			for is_digit(lex_peek(l)) {
				lex_advance(l)
			}
			if lex_peek(l) == ':' {
				lex_advance(l)
				for is_digit(lex_peek(l)) {
					lex_advance(l)
				}
			}
		}
	}
	return make_token(l, .Lit_Time, l.source[start:l.offset], p)
}

// ============================================================================
// 文字列スキャン
// ============================================================================

@(private = "file")
scan_string :: proc(l: ^Lexer, start: int, p: Pos) -> Token {
	// 開始 '"' は消費済み
	for {
		r := lex_peek(l)
		if r == utf8.RUNE_EOF {
			return make_token(l, .Error, "unterminated string", p)
		}
		if r == '"' {
			lex_advance(l) // 閉じ '"'
			break
		}
		if r == '\\' {
			lex_advance(l)
			if lex_peek(l) != utf8.RUNE_EOF {
				lex_advance(l)
			}
		} else {
			lex_advance(l)
		}
	}

	// ラベルチェック ("string":)
	if lex_peek(l) == ':' && lex_peek_n(l, 1) != ':' {
		lex_advance(l)
		return make_token(l, .Label, l.source[start + 1:l.offset - 2], p)
	}

	// クォートを除いた内容を返す
	return make_token(l, .Lit_String, l.source[start + 1:l.offset - 1], p)
}

// ============================================================================
// シンボルスキャン (:identifier)
// ============================================================================

@(private = "file")
scan_symbol :: proc(l: ^Lexer, start: int, p: Pos) -> Token {
	// ':' は消費済み
	if !is_ident_start(lex_peek(l)) {
		// シンボルでない場合はエラーではなく、上位で処理
		return make_token(l, .Error, ":", p)
	}
	for is_ident_char(lex_peek(l)) {
		lex_advance(l)
	}
	return make_token(l, .Lit_Symbol, l.source[start:l.offset], p)
}

// ============================================================================
// メインスキャン関数
// ============================================================================

lexer_next :: proc(l: ^Lexer) -> Token {
	for {
		// 空白スキップ（改行は含まない）
		for lex_peek(l) == ' ' || lex_peek(l) == '\t' {
			lex_advance(l)
		}

		start := l.offset
		p := Pos{offset = l.offset, line = l.line, column = l.column}
		r := lex_advance(l)

		switch r {
		case utf8.RUNE_EOF:
			return Token{type = .Eof, lexeme = "", pos = p, consumed = false}

		case '\n':
			return make_token(l, .Newline, "\n", p)

		case '#':
			// コメント → 改行まで読み飛ばし、Newline を返す
			for lex_peek(l) != '\n' && lex_peek(l) != utf8.RUNE_EOF {
				lex_advance(l)
			}
			if lex_peek(l) == '\n' {
				lex_advance(l)
			}
			return make_token(l, .Newline, "\n", p)

		case '+':
			skip_trail(l)
			return make_token(l, .Op_Plus, "+", p)

		case '-':
			if lex_peek(l) == '>' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Lambda, "->", p)
			}
			skip_trail(l)
			return make_token(l, .Op_Minus, "-", p)

		case '*':
			skip_trail(l)
			return make_token(l, .Op_Mult, "*", p)

		case '/':
			skip_trail(l)
			return make_token(l, .Op_Div, "/", p)

		case '%':
			skip_trail(l)
			return make_token(l, .Op_Mod, "%", p)

		case '=':
			if lex_peek(l) == '=' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Eq, "==", p)
			}
			if lex_peek(l) == '>' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Rasgn, "=>", p)
			}
			skip_trail(l)
			return make_token(l, .Eq, "=", p) // Op_Assign → Eq

		case '!':
			if lex_peek(l) == '=' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Neq, "!=", p)
			}
			return make_token(l, .Op_Not, "!", p)

		case '<':
			if lex_peek(l) == '=' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Le, "<=", p)
			}
			if lex_peek(l) == '-' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Lasgn, "<-", p)
			}
			skip_trail(l)
			return make_token(l, .Op_Lt, "<", p)

		case '>':
			if lex_peek(l) == '=' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Ge, ">=", p)
			}
			skip_trail(l)
			return make_token(l, .Op_Gt, ">", p)

		case '&':
			if lex_peek(l) == '&' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_And, "&&", p)
			}
			skip_trail(l)
			return make_token(l, .Op_Amper, "&", p)

		case '|':
			if lex_peek(l) == '|' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Or, "||", p)
			}
			skip_trail(l)
			return make_token(l, .Op_Bar, "|", p)

		case '~':
			return make_token(l, .Op_Tilde, "~", p)

		case ':':
			if lex_peek(l) == ':' {
				lex_advance(l)
				skip_trail(l)
				return make_token(l, .Op_Colon2, "::", p)
			}
			return scan_symbol(l, start, p)

		case '(':
			skip_trail(l)
			return make_token(l, .Lparen, "(", p)

		case ')':
			// )-> または )->{ のチェック
			saved_offset := l.offset
			saved_line := l.line
			saved_column := l.column
			spaces := 0
			for lex_peek(l) == ' ' {
				lex_advance(l)
				spaces += 1
			}
			if lex_peek(l) == '-' && lex_peek_n(l, 1) == '>' {
				lex_advance(l) // '-'
				lex_advance(l) // '>'
				// )->{ のチェック
				for lex_peek(l) == ' ' {
					lex_advance(l)
				}
				if lex_peek(l) == '{' {
					lex_advance(l)
					skip_trail(l)
					return make_token(l, .Op_Lambda3, ")->{", p)
				}
				skip_trail(l)
				return make_token(l, .Op_Lambda2, ")->", p)
			}
			// ロールバック
			l.offset = saved_offset
			l.line = saved_line
			l.column = saved_column
			return make_token(l, .Rparen, ")", p)

		case '[':
			skip_trail(l)
			return make_token(l, .Lbracket, "[", p)

		case ']':
			return make_token(l, .Rbracket, "]", p)

		case '{':
			skip_trail(l)
			return make_token(l, .Lbrace, "{", p)

		case '}':
			return make_token(l, .Rbrace, "}", p)

		case ',':
			skip_trail(l)
			return make_token(l, .Comma, ",", p)

		case ';':
			skip_trail(l)
			return make_token(l, .Semicolon, ";", p)

		case '.':
			skip_trail(l)
			return make_token(l, .Dot, ".", p)

		case '@':
			return make_token(l, .At, "@", p)

		case '"':
			return scan_string(l, start, p)

		case '0' ..= '9':
			return scan_number(l, start, p)

		case:
			if is_ident_start(r) {
				return scan_identifier(l, start, p)
			}
			return make_token(l, .Error, l.source[start:l.offset], p)
		}
	}
}
