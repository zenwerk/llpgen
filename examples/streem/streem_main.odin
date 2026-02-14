package streem

import "core:fmt"
import "core:os"

// ============================================================================
// AST 表示
// ============================================================================

print_ast :: proc(n: ^Node, indent: int = 0) {
	if n == nil {
		print_indent(indent)
		fmt.println("nil")
		return
	}

	switch &v in n.data {
	case Node_Int:
		print_indent(indent)
		fmt.printfln("Int(%v)", v.value)

	case Node_Float:
		print_indent(indent)
		fmt.printfln("Float(%v)", v.value)

	case Node_Time:
		print_indent(indent)
		fmt.printfln("Time(%s)", v.raw)

	case Node_Str:
		print_indent(indent)
		fmt.printfln("Str(\"%s\")", v.value)

	case Node_Bool:
		print_indent(indent)
		fmt.printfln("Bool(%v)", v.value)

	case Node_Args:
		print_indent(indent)
		fmt.printf("Args(")
		for name, i in v.names {
			if i > 0 {
				fmt.printf(", ")
			}
			fmt.printf("%s", name)
		}
		fmt.println(")")

	case Node_Pair:
		print_indent(indent)
		fmt.printfln("Pair(%s:)", v.key)
		print_ast(v.value, indent + 2)

	case Node_Array:
		print_indent(indent)
		fmt.printfln("Array(%d elements)", len(v.elements))
		for elem in v.elements {
			print_ast(elem, indent + 2)
		}

	case Node_Nodes:
		print_indent(indent)
		fmt.printfln("Nodes(%d)", len(v.nodes))
		for node in v.nodes {
			print_ast(node, indent + 2)
		}

	case Node_Splat:
		print_indent(indent)
		fmt.println("Splat")
		print_ast(v.expr, indent + 2)

	case Node_Ident:
		print_indent(indent)
		fmt.printfln("Ident(%s)", v.name)

	case Node_Op:
		print_indent(indent)
		if v.lhs == nil {
			fmt.printfln("Unary(%s)", v.op)
			print_ast(v.rhs, indent + 2)
		} else {
			fmt.printfln("Op(%s)", v.op)
			print_ast(v.lhs, indent + 2)
			print_ast(v.rhs, indent + 2)
		}

	case Node_If:
		print_indent(indent)
		fmt.println("If")
		print_indent(indent + 2)
		fmt.println("cond:")
		print_ast(v.cond, indent + 4)
		print_indent(indent + 2)
		fmt.println("then:")
		print_ast(v.then_, indent + 4)
		if v.opt_else != nil {
			print_indent(indent + 2)
			fmt.println("else:")
			print_ast(v.opt_else, indent + 4)
		}

	case Node_Lambda:
		print_indent(indent)
		if v.is_block {
			fmt.println("Block")
		} else {
			fmt.println("Lambda")
		}
		if v.args != nil {
			print_indent(indent + 2)
			fmt.println("args:")
			print_ast(v.args, indent + 4)
		}
		print_indent(indent + 2)
		fmt.println("body:")
		print_ast(v.body, indent + 4)

	case Node_Call:
		print_indent(indent)
		fmt.printfln("Call(%s)", v.name)
		if v.args != nil {
			print_indent(indent + 2)
			fmt.println("args:")
			print_ast(v.args, indent + 4)
		}

	case Node_Fcall:
		print_indent(indent)
		fmt.println("Fcall")
		print_indent(indent + 2)
		fmt.println("func:")
		print_ast(v.func_, indent + 4)
		if v.args != nil {
			print_indent(indent + 2)
			fmt.println("args:")
			print_ast(v.args, indent + 4)
		}

	case Node_Genfunc:
		print_indent(indent)
		fmt.printfln("Genfunc(&%s)", v.name)

	case Node_Let:
		print_indent(indent)
		fmt.printfln("Let(%s)", v.lhs)
		print_ast(v.rhs, indent + 2)

	case Node_Emit:
		print_indent(indent)
		fmt.println("Emit")
		print_ast(v.value, indent + 2)

	case Node_Return:
		print_indent(indent)
		fmt.println("Return")
		print_ast(v.value, indent + 2)

	case Node_Ns:
		print_indent(indent)
		fmt.printfln("Namespace(%s)", v.name)
		print_ast(v.body, indent + 2)

	case Node_Import:
		print_indent(indent)
		fmt.printfln("Import(%s)", v.name)

	case Node_PArray:
		print_indent(indent)
		fmt.printfln("PArray(%d)", len(v.patterns))
		for pat in v.patterns {
			print_ast(pat, indent + 2)
		}

	case Node_PStruct:
		print_indent(indent)
		fmt.printfln("PStruct(%d)", len(v.patterns))
		for pat in v.patterns {
			print_ast(pat, indent + 2)
		}

	case Node_PSplat:
		print_indent(indent)
		fmt.println("PSplat")
		print_ast(v.head, indent + 2)
		print_ast(v.mid, indent + 2)
		print_ast(v.tail, indent + 2)

	case Node_PLambda:
		print_indent(indent)
		fmt.println("PLambda")
		if v.pat != nil {
			print_indent(indent + 2)
			fmt.println("pattern:")
			print_ast(v.pat, indent + 4)
		}
		if v.cond != nil {
			print_indent(indent + 2)
			fmt.println("guard:")
			print_ast(v.cond, indent + 4)
		}
		if v.body != nil {
			print_indent(indent + 2)
			fmt.println("body:")
			print_ast(v.body, indent + 4)
		}
		if v.next_ != nil {
			print_indent(indent + 2)
			fmt.println("next:")
			print_ast(v.next_, indent + 4)
		}
	case:
		// data が nil の場合 (Nil, Skip)
		print_indent(indent)
		fmt.printfln("%v", n.type)
	}
}

print_indent :: proc(n: int) {
	for _ in 0 ..< n {
		fmt.print(" ")
	}
}

// ============================================================================
// パース実行
// ============================================================================

run_parse :: proc(input: string, name: string = "<input>") {
	fmt.printfln("=== %s ===", name)

	p := parser_new()
	defer parser_destroy(p)

	l := lexer_new(input)
	max_tokens := 500
	token_count := 0
	for {
		tk := lexer_next(&l)
		result := parser_push_token(p, tk)
		if result == .Parse_End || p.nerr > 0 {
			break
		}
		token_count += 1
		if token_count > max_tokens {
			fmt.eprintln("  MAX TOKENS EXCEEDED")
			break
		}
	}

	if p.nerr > 0 {
		fmt.printfln("  Error: %s", p.error_msg)
	} else if p.root != nil {
		print_ast(p.root, 2)
	} else {
		fmt.println("  (empty)")
	}
	fmt.println()
}

// ============================================================================
// メイン
// ============================================================================

main :: proc() {
	// コマンドライン引数でファイルが指定された場合
	args := os.args
	if len(args) > 1 {
		for i in 1 ..< len(args) {
			fname := args[i]
			data, ok := os.read_entire_file(fname)
			if !ok {
				fmt.eprintfln("Error: Cannot read file: %s", fname)
				continue
			}
			source := string(data)
			run_parse(source, fname)
		}
		return
	}

	// ファイル指定がない場合はインラインテスト
	fmt.println("=== Streem Parser Test ===")
	fmt.println()

	// 基本的な式
	run_parse("42", "integer literal")
	run_parse("3.14", "float literal")
	run_parse("\"hello\"", "string literal")
	run_parse("true", "boolean")
	run_parse("nil", "nil")

	// 識別子
	run_parse("stdin", "identifier")

	// 二項演算
	run_parse("1 + 2", "addition")
	run_parse("1 + 2 * 3", "operator precedence")

	// パイプ
	run_parse("stdin | stdout", "pipe")

	// 関数呼び出し
	run_parse("seq(100)", "function call")

	// 代入
	run_parse("x = 42", "assignment")

}
