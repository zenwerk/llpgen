package calc

import "core:fmt"
import "core:os"

// 簡易レキサー (テスト用)
Lexer :: struct {
	source: string,
	pos:    int,
	line:   int,
	column: int,
}

lexer_new :: proc(source: string) -> Lexer {
	return Lexer{source = source, pos = 0, line = 1, column = 1}
}

lexer_next :: proc(l: ^Lexer) -> Token {
	// 空白スキップ
	for l.pos < len(l.source) {
		ch := l.source[l.pos]
		if ch == ' ' || ch == '\t' || ch == '\r' {
			l.pos += 1
			l.column += 1
		} else if ch == '\n' {
			l.pos += 1
			l.line += 1
			l.column = 1
		} else {
			break
		}
	}

	if l.pos >= len(l.source) {
		return Token{type = .Eof, lexeme = "", pos = Pos{offset = l.pos, line = l.line, column = l.column}}
	}

	start := l.pos
	ch := l.source[l.pos]
	p := Pos{offset = l.pos, line = l.line, column = l.column}

	// 数値
	if ch >= '0' && ch <= '9' {
		for l.pos < len(l.source) && ((l.source[l.pos] >= '0' && l.source[l.pos] <= '9') || l.source[l.pos] == '.') {
			l.pos += 1
			l.column += 1
		}
		return Token{type = .Number, lexeme = l.source[start:l.pos], pos = p}
	}

	// 識別子
	if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' {
		for l.pos < len(l.source) && ((l.source[l.pos] >= 'a' && l.source[l.pos] <= 'z') || (l.source[l.pos] >= 'A' && l.source[l.pos] <= 'Z') || (l.source[l.pos] >= '0' && l.source[l.pos] <= '9') || l.source[l.pos] == '_') {
			l.pos += 1
			l.column += 1
		}
		return Token{type = .Ident, lexeme = l.source[start:l.pos], pos = p}
	}

	// 単一文字トークン
	l.pos += 1
	l.column += 1
	switch ch {
	case '+': return Token{type = .Plus, lexeme = "+", pos = p}
	case '-': return Token{type = .Minus, lexeme = "-", pos = p}
	case '*': return Token{type = .Asterisk, lexeme = "*", pos = p}
	case '/': return Token{type = .Slash, lexeme = "/", pos = p}
	case '(': return Token{type = .Left_Paren, lexeme = "(", pos = p}
	case ')': return Token{type = .Right_Paren, lexeme = ")", pos = p}
	case ',': return Token{type = .Comma, lexeme = ",", pos = p}
	}

	return Token{type = .Error, lexeme = l.source[start:l.pos], pos = p}
}

// AST の表示
print_ast :: proc(n: ^Node, indent: int = 0) {
	if n == nil {
		print_indent(indent)
		fmt.println("nil")
		return
	}

	switch &v in n.variant {
	case Node_Number:
		print_indent(indent)
		fmt.printfln("Number(%v)", v.value)
	case Node_Unary:
		print_indent(indent)
		fmt.printfln("Unary(%v)", v.op)
		print_ast(v.operand, indent + 2)
	case Node_Binary:
		print_indent(indent)
		fmt.printfln("Binary(%v)", v.op)
		print_ast(v.left, indent + 2)
		print_ast(v.right, indent + 2)
	case Node_Func_Call:
		print_indent(indent)
		fmt.printfln("FuncCall(%s, %d args)", v.name, len(v.args))
		for arg in v.args {
			print_ast(arg, indent + 2)
		}
	}
}

print_indent :: proc(n: int) {
	for _ in 0..<n {
		fmt.print(" ")
	}
}

// テスト実行
run_test :: proc(input: string) {
	fmt.printfln("Input: %s", input)

	p := parser_new()
	defer parser_destroy(p)

	l := lexer_new(input)
	for {
		tk := lexer_next(&l)
		result := parser_push_token(p, tk)
		if result == .Parse_End {
			break
		}
	}

	if p.nerr > 0 {
		fmt.printfln("  Error: %s", p.error_msg)
	} else if p.root != nil {
		fmt.println("  AST:")
		print_ast(p.root, 4)
	} else {
		fmt.println("  (empty)")
	}
	fmt.println()
}

main :: proc() {
	fmt.println("=== Calculator Parser Test ===")
	fmt.println()

	// 基本的な数値
	run_test("42")

	// 二項演算
	run_test("1 + 2")

	// 演算子の優先順位
	run_test("1 + 2 * 3")

	// 括弧
	run_test("(1 + 2) * 3")

	// 単項マイナス
	run_test("-5")

	// 複合式
	run_test("-1 + 2 * (3 + 4)")

	// 関数呼び出し (引数なし)
	run_test("foo()")

	// 関数呼び出し (1引数)
	run_test("sin(3.14)")

	// 関数呼び出し (複数引数)
	run_test("max(1, 2, 3)")

	// 複合式 with 関数
	run_test("1 + max(2 * 3, 4) - 5")

	os.exit(0)
}
