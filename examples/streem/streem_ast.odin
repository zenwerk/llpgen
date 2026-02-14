package streem

import "core:container/queue"
import "core:strconv"
import "core:strings"
import "core:fmt"

// ============================================================================
// AST ノード定義
// ============================================================================

// Node_Type - ASTノードの種類
Node_Type :: enum {
	// リテラル
	Int,
	Float,
	Time,
	Str,
	Nil,
	Bool,
	// コレクション
	Args,
	Pair,
	Array,
	Nodes,
	// スプラット
	Splat,
	// 式
	Ident,
	Op,
	If,
	Lambda,
	Call,
	Fcall,
	Genfunc,
	// 文
	Let,
	Emit,
	Skip,
	Return,
	// トップレベル
	Ns,
	Import,
	// パターンマッチング
	PArray,
	PStruct,
	PSplat,
	PLambda,
}

// ノード構造体
Node :: struct {
	type: Node_Type,
	data: Node_Data,
}

Node_Data :: union {
	Node_Int,
	Node_Float,
	Node_Time,
	Node_Str,
	Node_Bool,
	Node_Args,
	Node_Pair,
	Node_Array,
	Node_Nodes,
	Node_Splat,
	Node_Ident,
	Node_Op,
	Node_If,
	Node_Lambda,
	Node_Call,
	Node_Fcall,
	Node_Genfunc,
	Node_Let,
	Node_Emit,
	Node_Return,
	Node_Ns,
	Node_Import,
	Node_PArray,
	Node_PStruct,
	Node_PSplat,
	Node_PLambda,
}

Node_Int :: struct {
	value: i64,
}

Node_Float :: struct {
	value: f64,
}

Node_Time :: struct {
	raw: string, // 生の文字列を保持
}

Node_Str :: struct {
	value: string,
}

Node_Bool :: struct {
	value: bool,
}

Node_Args :: struct {
	names: [dynamic]string,
}

Node_Pair :: struct {
	key:   string,
	value: ^Node,
}

Node_Array :: struct {
	elements: [dynamic]^Node,
}

Node_Nodes :: struct {
	nodes: [dynamic]^Node,
}

Node_Splat :: struct {
	expr: ^Node,
}

Node_Ident :: struct {
	name: string,
}

Node_Op :: struct {
	op:  string,
	lhs: ^Node,
	rhs: ^Node,
}

Node_If :: struct {
	cond:     ^Node,
	then_:    ^Node,
	opt_else: ^Node,
}

Node_Lambda :: struct {
	args:     ^Node, // Node_Args or nil
	body:     ^Node,
	is_block: bool,
}

Node_Call :: struct {
	name: string,
	args: ^Node, // Node_Array or nil
}

Node_Fcall :: struct {
	func_: ^Node,
	args:  ^Node, // Node_Array or nil
}

Node_Genfunc :: struct {
	name: string,
}

Node_Let :: struct {
	lhs: string,
	rhs: ^Node,
}

Node_Emit :: struct {
	value: ^Node,
}

Node_Return :: struct {
	value: ^Node,
}

Node_Ns :: struct {
	name: string,
	body: ^Node,
}

Node_Import :: struct {
	name: string,
}

Node_PArray :: struct {
	patterns: [dynamic]^Node,
}

Node_PStruct :: struct {
	patterns: [dynamic]^Node,
}

Node_PSplat :: struct {
	head: ^Node,
	mid:  ^Node,
	tail: ^Node,
}

Node_PLambda :: struct {
	pat:   ^Node,
	cond:  ^Node,
	body:  ^Node,
	next_: ^Node,
}

// ============================================================================
// ノードコンストラクタ
// ============================================================================

node_new :: proc(type: Node_Type, data: Node_Data) -> ^Node {
	n := new(Node)
	n.type = type
	n.data = data
	return n
}

node_int_new :: proc(value: i64) -> ^Node {
	return node_new(.Int, Node_Int{value = value})
}

node_float_new :: proc(value: f64) -> ^Node {
	return node_new(.Float, Node_Float{value = value})
}

node_str_new :: proc(value: string) -> ^Node {
	return node_new(.Str, Node_Str{value = value})
}

node_bool_new :: proc(value: bool) -> ^Node {
	return node_new(.Bool, Node_Bool{value = value})
}

node_nil_new :: proc() -> ^Node {
	return node_new(.Nil, nil)
}

node_ident_new :: proc(name: string) -> ^Node {
	return node_new(.Ident, Node_Ident{name = name})
}

node_op_new :: proc(op: string, lhs: ^Node, rhs: ^Node) -> ^Node {
	return node_new(.Op, Node_Op{op = op, lhs = lhs, rhs = rhs})
}

node_if_new :: proc(cond: ^Node, then_: ^Node, opt_else: ^Node) -> ^Node {
	return node_new(.If, Node_If{cond = cond, then_ = then_, opt_else = opt_else})
}

node_lambda_new :: proc(args: ^Node, body: ^Node) -> ^Node {
	return node_new(.Lambda, Node_Lambda{args = args, body = body, is_block = false})
}

node_block_new :: proc(body: ^Node) -> ^Node {
	return node_new(.Lambda, Node_Lambda{args = nil, body = body, is_block = true})
}

node_call_new :: proc(name: string, args: ^Node) -> ^Node {
	return node_new(.Call, Node_Call{name = name, args = args})
}

node_fcall_new :: proc(func_: ^Node, args: ^Node) -> ^Node {
	return node_new(.Fcall, Node_Fcall{func_ = func_, args = args})
}

node_genfunc_new :: proc(name: string) -> ^Node {
	return node_new(.Genfunc, Node_Genfunc{name = name})
}

node_let_new :: proc(lhs: string, rhs: ^Node) -> ^Node {
	return node_new(.Let, Node_Let{lhs = lhs, rhs = rhs})
}

node_emit_new :: proc(value: ^Node) -> ^Node {
	return node_new(.Emit, Node_Emit{value = value})
}

node_return_new :: proc(value: ^Node) -> ^Node {
	return node_new(.Return, Node_Return{value = value})
}

node_skip_new :: proc() -> ^Node {
	return node_new(.Skip, nil)
}

node_ns_new :: proc(name: string, body: ^Node) -> ^Node {
	return node_new(.Ns, Node_Ns{name = name, body = body})
}

node_import_new :: proc(name: string) -> ^Node {
	return node_new(.Import, Node_Import{name = name})
}

node_splat_new :: proc(expr: ^Node) -> ^Node {
	return node_new(.Splat, Node_Splat{expr = expr})
}

node_array_new :: proc() -> ^Node {
	return node_new(.Array, Node_Array{})
}

node_array_add :: proc(arr: ^Node, elem: ^Node) {
	if arr == nil || arr.type != .Array {
		return
	}
	a := &arr.data.(Node_Array)
	append(&a.elements, elem)
}

node_nodes_new :: proc() -> ^Node {
	return node_new(.Nodes, Node_Nodes{})
}

node_nodes_add :: proc(nodes: ^Node, node: ^Node) {
	if nodes == nil || nodes.type != .Nodes {
		return
	}
	ns := &nodes.data.(Node_Nodes)
	append(&ns.nodes, node)
}

node_args_new :: proc() -> ^Node {
	return node_new(.Args, Node_Args{})
}

node_args_add :: proc(args: ^Node, name: string) {
	if args == nil || args.type != .Args {
		return
	}
	a := &args.data.(Node_Args)
	append(&a.names, name)
}

node_pair_new :: proc(key: string, value: ^Node) -> ^Node {
	return node_new(.Pair, Node_Pair{key = key, value = value})
}

node_parray_new :: proc() -> ^Node {
	return node_new(.PArray, Node_PArray{})
}

node_parray_add :: proc(parray: ^Node, pattern: ^Node) {
	if parray == nil || parray.type != .PArray {
		return
	}
	p := &parray.data.(Node_PArray)
	append(&p.patterns, pattern)
}

node_pstruct_new :: proc() -> ^Node {
	return node_new(.PStruct, Node_PStruct{})
}

node_pstruct_add :: proc(pstruct: ^Node, pattern: ^Node) {
	if pstruct == nil || pstruct.type != .PStruct {
		return
	}
	p := &pstruct.data.(Node_PStruct)
	append(&p.patterns, pattern)
}

node_plambda_new :: proc(pat: ^Node, cond: ^Node) -> ^Node {
	return node_new(.PLambda, Node_PLambda{pat = pat, cond = cond})
}

node_psplat_new :: proc(head: ^Node, mid: ^Node, tail: ^Node) -> ^Node {
	return node_new(.PSplat, Node_PSplat{head = head, mid = mid, tail = tail})
}

// ============================================================================
// ノード解放
// ============================================================================

node_free :: proc(n: ^Node) {
	if n == nil {
		return
	}

	switch &d in n.data {
	case Node_Int, Node_Float, Node_Time, Node_Str, Node_Bool:
	// プリミティブ型は追加の解放不要

	case Node_Args:
		delete(d.names)

	case Node_Pair:
		node_free(d.value)

	case Node_Array:
		for elem in d.elements {
			node_free(elem)
		}
		delete(d.elements)

	case Node_Nodes:
		for node in d.nodes {
			node_free(node)
		}
		delete(d.nodes)

	case Node_PArray:
		for pat in d.patterns {
			node_free(pat)
		}
		delete(d.patterns)

	case Node_PStruct:
		for pat in d.patterns {
			node_free(pat)
		}
		delete(d.patterns)

	case Node_Splat:
		node_free(d.expr)

	case Node_Ident:
	// 文字列は入力から直接参照しているため解放不要

	case Node_Op:
		node_free(d.lhs)
		node_free(d.rhs)

	case Node_If:
		node_free(d.cond)
		node_free(d.then_)
		node_free(d.opt_else)

	case Node_Lambda:
		node_free(d.args)
		node_free(d.body)

	case Node_Call:
		node_free(d.args)

	case Node_Fcall:
		node_free(d.func_)
		node_free(d.args)

	case Node_Genfunc:

	case Node_Let:
		node_free(d.rhs)

	case Node_Emit:
		node_free(d.value)

	case Node_Return:
		node_free(d.value)

	case Node_Ns:
		node_free(d.body)

	case Node_Import:

	case Node_PSplat:
		node_free(d.head)
		node_free(d.mid)
		node_free(d.tail)

	case Node_PLambda:
		node_free(d.pat)
		node_free(d.cond)
		node_free(d.body)
		node_free(d.next_)
	}

	free(n)
}

// ============================================================================
// トークンの演算子文字列を取得
// ============================================================================

@(private = "file")
token_op_str :: proc(tk: ^Token) -> string {
	return tk.lexeme
}

// ============================================================================
// on_parse_event - パースイベントハンドラ
// ============================================================================
//
// 生成パーサーから各イベント発生時に呼び出される。
// top.node, top.saved, top.op を使って AST を構築する。
//
// 重要な設計方針:
//   - top.node は ^^Node (ノードへのポインタのポインタ)
//     (top.node)^ で現在のノードを読み書きする
//   - 二項演算子ループでは、left を保存して Binary ノードを作成し、
//     top.node を right に切り替えて次の子規則がそこに書き込むようにする
//   - top.saved は中間結果の保持に使用（関数呼び出しのノード保持等）

on_parse_event :: proc(p: ^Parser, event: Parse_Event, tk: ^Token, top: ^Parse_State) {
	#partial switch event {

	// ====================================================================
	// リテラル・識別子
	// ====================================================================

	case .Primary_Lit_Number:
		// 整数か浮動小数点かを判定
		if strings.contains_rune(tk.lexeme, '.') || strings.contains_rune(tk.lexeme, 'e') || strings.contains_rune(tk.lexeme, 'E') {
			value, ok := strconv.parse_f64(tk.lexeme)
			if !ok {
				parser_error(p, fmt.tprintf("Invalid float: %s", tk.lexeme))
				return
			}
			(top.node)^ = node_float_new(value)
		} else {
			value, ok := strconv.parse_i64_of_base(tk.lexeme, 10)
			if !ok {
				parser_error(p, fmt.tprintf("Invalid integer: %s", tk.lexeme))
				return
			}
			(top.node)^ = node_int_new(value)
		}

	case .Primary_Lit_String:
		(top.node)^ = node_str_new(tk.lexeme)

	case .Primary_Lit_Symbol:
		// シンボルは文字列として保存（:name → "name"）
		name := tk.lexeme
		if len(name) > 0 && name[0] == ':' {
			name = name[1:]
		}
		(top.node)^ = node_str_new(name)
		// シンボルは Ident で表現
		(top.node)^ = node_ident_new(tk.lexeme)

	case .Primary_Lit_Time:
		(top.node)^ = node_new(.Time, Node_Time{raw = tk.lexeme})

	case .Primary_Kw_Nil:
		(top.node)^ = node_nil_new()

	case .Primary_Kw_True:
		(top.node)^ = node_bool_new(true)

	case .Primary_Kw_False:
		(top.node)^ = node_bool_new(false)

	case .Primary_Kw_New:
		// new Ident[args] - saved に "new" を記録、後の Await_Ident で処理
		top.op = "new"

	case .Primary_Await_Ident:
		// new Ident... → saved に名前を保存
		top.saved = node_ident_new(tk.lexeme)

	case .Primary_Await_Lbracket:
		// new Ident[ → 引数配列を準備
		arr := node_array_new()
		// saved は ident ノード
		// 最終的に Primary_Await_Rbracket で Call ノードを構築

	case .Primary_Await_Rbracket:
		// new Ident[args] の完了
		// args は top.node^ に入っている（opt_args経由）
		args := (top.node)^
		ident := top.saved
		if ident != nil {
			name := ""
			if id, ok := ident.data.(Node_Ident); ok {
				name = id.name
			}
			call := node_call_new(name, args)
			node_free(ident)
			(top.node)^ = call
		}

	case .Primary_Op_Amper:
		// &fname → saved に "&" を記録、fname イベントで完了
		top.op = "&"

	// ====================================================================
	// 識別子と関数呼び出し
	// ====================================================================

	case .Ident_Or_Call_Ident:
		// 識別子（後で ident_suffix で Call に昇格する可能性あり）
		(top.node)^ = node_ident_new(tk.lexeme)

	case .Ident_Suffix_Lparen:
		// ident(args) → Call ノードに変換
		ident_node := (top.node)^
		name := ""
		if ident_node != nil {
			if id, ok := ident_node.data.(Node_Ident); ok {
				name = id.name
			}
		}
		// 引数配列を準備
		arr := node_array_new()
		call := node_call_new(name, arr)
		if ident_node != nil {
			node_free(ident_node)
		}
		(top.node)^ = call
		// top.saved に Call ノードを保存
		top.saved = call
		// top.node を最初の引数スロットに切り替え
		call_data := &call.data.(Node_Call)
		arr_data := &call_data.args.data.(Node_Array)
		append(&arr_data.elements, nil)
		top.node = &arr_data.elements[len(arr_data.elements) - 1]

	case .Ident_Suffix_Await_Rparen:
		// ident(args) の ')' を消費
		// 空引数の場合を処理
		call := top.saved
		if call != nil {
			call_data := &call.data.(Node_Call)
			if call_data.args != nil {
				arr := &call_data.args.data.(Node_Array)
				if len(arr.elements) == 1 && arr.elements[0] == nil {
					clear(&arr.elements)
				}
			}
		}

	case .Ident_Suffix_Lbrace:
		// ident { stmts } → Call with block argument
		ident_node := (top.node)^
		name := ""
		if ident_node != nil {
			if id, ok := ident_node.data.(Node_Ident); ok {
				name = id.name
			}
		}
		// ブロック引数用の配列を準備
		arr := node_array_new()
		call := node_call_new(name, arr)
		if ident_node != nil {
			node_free(ident_node)
		}
		(top.node)^ = call
		top.saved = call
		// body を stmts の書き込み先として使う
		// stmts の結果は後で Block_Await_Rbrace ではなく Ident_Suffix_Await_Rbrace でブロック化
		call_data := &call.data.(Node_Call)
		arr_data := &call_data.args.data.(Node_Array)
		append(&arr_data.elements, nil)
		top.node = &arr_data.elements[0]

	case .Ident_Suffix_Await_Rbrace:
		// ident { stmts } の '}' を消費
		// stmts の結果を Block でラップして引数に設定
		call := top.saved
		if call != nil {
			call_data := &call.data.(Node_Call)
			if call_data.args != nil {
				arr := &call_data.args.data.(Node_Array)
				if len(arr.elements) > 0 {
					body := arr.elements[0]
					arr.elements[0] = node_block_new(body)
				}
			}
		}

	// ====================================================================
	// 二項演算子ループ
	// ====================================================================

	case .Pipe_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .Amper_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .Or_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .And_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .Eq_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .Cmp_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .Add_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	case .Mul_Expr_Op:
		left := (top.node)^
		bin := node_op_new(token_op_str(tk), left, nil)
		(top.node)^ = bin
		bin_data := &bin.data.(Node_Op)
		top.node = &bin_data.rhs

	// ====================================================================
	// 単項演算子
	// ====================================================================

	case .Unary_Expr_Op_Plus:
		// 単項+は何もしない (operandがそのまま値)
		unary := node_op_new("+", nil, nil)
		(top.node)^ = unary
		unary_data := &unary.data.(Node_Op)
		top.node = &unary_data.rhs

	case .Unary_Expr_Op_Minus:
		unary := node_op_new("-", nil, nil)
		(top.node)^ = unary
		unary_data := &unary.data.(Node_Op)
		top.node = &unary_data.rhs

	case .Unary_Expr_Op_Not:
		unary := node_op_new("!", nil, nil)
		(top.node)^ = unary
		unary_data := &unary.data.(Node_Op)
		top.node = &unary_data.rhs

	case .Unary_Expr_Op_Tilde:
		unary := node_op_new("~", nil, nil)
		(top.node)^ = unary
		unary_data := &unary.data.(Node_Op)
		top.node = &unary_data.rhs

	// ====================================================================
	// Postfix chain (method access)
	// ====================================================================

	case .Postfix_Chain_Dot:
		// obj.method → saved に obj を保存、fname で method 名を取得
		top.saved = (top.node)^

	case .Postfix_Access_Lparen:
		// obj.(args) → Fcall ノード
		obj := top.saved
		if obj == nil {
			obj = (top.node)^
		}
		arr := node_array_new()
		fcall := node_fcall_new(obj, arr)
		(top.node)^ = fcall
		top.saved = fcall
		// 引数スロットを準備
		fcall_data := &fcall.data.(Node_Fcall)
		arr_data := &fcall_data.args.data.(Node_Array)
		append(&arr_data.elements, nil)
		top.node = &arr_data.elements[0]

	case .Postfix_Access_Await_Rparen:
		// obj.(args) の ')' 消費
		fcall := top.saved
		if fcall != nil && fcall.type == .Fcall {
			fcall_data := &fcall.data.(Node_Fcall)
			if fcall_data.args != nil {
				arr := &fcall_data.args.data.(Node_Array)
				if len(arr.elements) == 1 && arr.elements[0] == nil {
					clear(&arr.elements)
				}
			}
		}

	case .Postfix_Call_Args_Lparen:
		// expr(args) → Fcall ノード
		func_expr := (top.node)^
		arr := node_array_new()
		fcall := node_fcall_new(func_expr, arr)
		(top.node)^ = fcall
		top.saved = fcall
		fcall_data := &fcall.data.(Node_Fcall)
		arr_data := &fcall_data.args.data.(Node_Array)
		append(&arr_data.elements, nil)
		top.node = &arr_data.elements[0]

	case .Postfix_Call_Args_Await_Rparen:
		fcall := top.saved
		if fcall != nil && fcall.type == .Fcall {
			fcall_data := &fcall.data.(Node_Fcall)
			if fcall_data.args != nil {
				arr := &fcall_data.args.data.(Node_Array)
				if len(arr.elements) == 1 && arr.elements[0] == nil {
					clear(&arr.elements)
				}
			}
		}

	// ====================================================================
	// fname (関数名/メソッド名)
	// ====================================================================

	case .Fname_Ident:
		// saved に "&" が保存されている場合は Genfunc、
		// dot chain で呼ばれた場合は Call を構築
		if top.op == "&" {
			(top.node)^ = node_genfunc_new(tk.lexeme)
			top.op = ""
		} else if top.saved != nil {
			// dot.method の場合 → method呼び出しに変換
			obj := top.saved
			// 引数なしのCallノード（後でpostfix_call_argsで引数が追加される可能性あり）
			call := node_call_new(tk.lexeme, nil)
			// Fcall として obj.method(args) を構築
			fcall := node_fcall_new(obj, nil)
			node_free(fcall) // Fcall ではなく method call パターンを使う
			// obj.method → Call (method, args=[obj]) にしたい
			// ただし streem では obj.method は Fcall(obj, method_name) のような形式
			// 簡易化: obj.name はメソッド呼び出しとして表現
			arr := node_array_new()
			node_array_add(arr, obj)
			(top.node)^ = node_call_new(tk.lexeme, arr)
			top.saved = (top.node)^
		} else {
			// def fname の場合
			top.saved = node_ident_new(tk.lexeme)
			(top.node)^ = top.saved
		}

	case .Fname_Lit_String:
		if top.op == "&" {
			(top.node)^ = node_genfunc_new(tk.lexeme)
			top.op = ""
		} else {
			top.saved = node_str_new(tk.lexeme)
			(top.node)^ = top.saved
		}

	// ====================================================================
	// 文 (Statements)
	// ====================================================================

	case .Stmt_Kw_Def:
		// def fname def_body → fname イベントで処理開始
		top.op = "def"

	case .Stmt_Kw_Skip:
		(top.node)^ = node_skip_new()

	case .Stmt_Kw_Emit:
		// emit opt_args → saved に "emit" を記録
		top.op = "emit"

	case .Stmt_Kw_Return:
		// return opt_args → saved に "return" を記録
		top.op = "return"

	// ====================================================================
	// stmt_suffix (代入)
	// ====================================================================

	case .Stmt_Suffix_Eq:
		// expr = expr → Let ノード
		// 現在の top.node^ は左辺の式（Ident であるべき）
		lhs_node := (top.node)^
		lhs_name := ""
		if lhs_node != nil {
			if id, ok := lhs_node.data.(Node_Ident); ok {
				lhs_name = id.name
			}
		}
		let := node_let_new(lhs_name, nil)
		if lhs_node != nil {
			node_free(lhs_node)
		}
		(top.node)^ = let
		let_data := &let.data.(Node_Let)
		top.node = &let_data.rhs

	case .Stmt_Suffix_Op_Rasgn:
		// expr => ident → 右代入 (Let)
		// saved に右辺の式を保存
		top.saved = (top.node)^

	case .Stmt_Suffix_Await_Ident:
		// expr => ident の ident を消費
		rhs := top.saved
		(top.node)^ = node_let_new(tk.lexeme, rhs)

	// ====================================================================
	// def_body
	// ====================================================================

	case .Def_Body_Lparen:
		// def fname(f_args) method_body
		// saved にはfnameのノードが入っている
		// f_args 用の Node_Args を準備
		top.op = "def_body"

	case .Def_Body_Eq:
		// def fname = expr
		top.op = "def_eq"

	case .Def_Body_Await_Rparen:
		// def fname(f_args) → f_args パース完了
		// method_body に進む

	// ====================================================================
	// expr - if 式
	// ====================================================================

	case .Expr_Kw_If:
		// if (cond) then opt_else → If ノード準備
		// parser_end 後にフレームが破棄されるため saved ではなく node^ に設定
		if_node := node_if_new(nil, nil, nil)
		(top.node)^ = if_node

	// ====================================================================
	// condition
	// ====================================================================

	case .Condition_Lparen:
		// '(' を消費、cond に書き込み先を設定
		// top.node^ は If ノード（Expr_Kw_If で設定）
		if_node := (top.node)^
		if if_node != nil && if_node.type == .If {
			if_data := &if_node.data.(Node_If)
			top.saved = if_node // Condition フレームの saved に保存
			top.node = &if_data.cond
		}

	case .Condition_Await_Rparen:
		// ')' を消費
		// cond は top.node^ に入っている（Condition_Lparen で切り替え済み）
		// Condition の下のフレーム (Pipe_Expr) の node を then に設定する必要がある
		if_node := top.saved
		if if_node != nil && if_node.type == .If {
			if_data := &if_node.data.(Node_If)
			// Condition の下の Pipe_Expr フレームの node を then に変更
			// state_stack[0] = top (Condition), state_stack[1] = Pipe_Expr
			if queue.len(p.state_stack) >= 2 {
				pipe_frame := queue.get_ptr(&p.state_stack, 1)
				pipe_frame.node = &if_data.then_
			}
			// さらに Opt_Terms と Opt_Else の node も変更
			// (Pipe_Expr 完了後に then の値が設定されるので、Opt_Else は別の node を使う)
			// Opt_Else は opt_else フィールドに書き込む必要がある
			if queue.len(p.state_stack) >= 3 {
				opt_terms_frame := queue.get_ptr(&p.state_stack, 2)
				opt_terms_frame.saved = if_node // Opt_Terms で保持
			}
			if queue.len(p.state_stack) >= 4 {
				opt_else_frame := queue.get_ptr(&p.state_stack, 3)
				opt_else_frame.node = &if_data.opt_else
			}
		}

	// ====================================================================
	// opt_else
	// ====================================================================

	case .Opt_Else_Kw_Else:
		// else → opt_else に書き込み先を設定
		// Condition_Await_Rparen で top.node を &if_data.opt_else に設定済み
		// 何もしない（top.node は既に opt_else フィールドを指している）
		// parser_begin(p, .Expr, top.node) で Expr に渡される
		_ = top // already set up

	// ====================================================================
	// 括弧式・ラムダ
	// ====================================================================

	case .Paren_Expr_Lparen:
		// '(' を消費。Expr の結果がそのまま top.node^ に入る

	case .Paren_Content_Rparen:
		// '()' → 空のラムダ引数リスト。Paren_Suffix で処理
		top.saved = nil // 空括弧を示す

	case .Paren_Content_Await_Rparen:
		// '(expr)' の ')' → saved に式を保存
		top.saved = (top.node)^

	case .Paren_Suffix_Op_Lambda2:
		// (args) -> expr ラムダ
		// top.saved には括弧内の式が入っている
		args_node := top.saved
		lambda_args := build_lambda_args(args_node)
		lambda := node_lambda_new(lambda_args, nil)
		(top.node)^ = lambda
		lambda_data := &lambda.data.(Node_Lambda)
		top.node = &lambda_data.body

	case .Paren_Suffix_Op_Lambda3:
		// (args) -> { stmts } ラムダ
		args_node := top.saved
		lambda_args := build_lambda_args(args_node)
		lambda := node_lambda_new(lambda_args, nil)
		(&lambda.data.(Node_Lambda)).is_block = true
		(top.node)^ = lambda
		lambda_data := &lambda.data.(Node_Lambda)
		top.node = &lambda_data.body

	case .Paren_Suffix_Await_Rbrace:
		// (args) -> { stmts } の '}' 消費 → 何もしない

	// ====================================================================
	// 配列リテラル
	// ====================================================================

	case .Bracket_Expr_Lbracket:
		// '[' → 配列ノード作成
		arr := node_array_new()
		(top.node)^ = arr
		top.saved = arr
		// 最初の要素スロットを準備
		arr_data := &arr.data.(Node_Array)
		append(&arr_data.elements, nil)
		top.node = &arr_data.elements[0]

	case .Bracket_Content_Rbracket:
		// '[]' → 空配列
		arr := node_array_new()
		(top.node)^ = arr

	case .Bracket_Content_Await_Rbracket:
		// '[args]' の ']' → 空要素を除去
		arr := top.saved
		if arr != nil && arr.type == .Array {
			arr_data := &arr.data.(Node_Array)
			if len(arr_data.elements) == 1 && arr_data.elements[0] == nil {
				clear(&arr_data.elements)
			}
		}

	// ====================================================================
	// ブロック
	// ====================================================================

	case .Block_Lbrace:
		// '{' → block_content に進む
		// Block は Lambda(is_block=true) として表現
		// block_content が stmts, lambda args, case を判定

	case .Block_Await_Rbrace:
		// '}' → ブロック完了
		// top.node^ にはブロックの本体が入っている
		body := (top.node)^
		if body != nil && body.type != .Lambda && body.type != .PLambda {
			(top.node)^ = node_block_new(body)
		}

	case .Block_Content_Op_Lambda:
		// {-> stmts} → パラメータなしブロックラムダの開始
		lambda := node_lambda_new(nil, nil)
		(&lambda.data.(Node_Lambda)).is_block = true
		(top.node)^ = lambda
		lambda_data := &lambda.data.(Node_Lambda)
		top.node = &lambda_data.body

	case .Block_Content_Ident:
		// { Ident ... → bparam か stmts かを判定するために Ident を保存
		// block_after_ident で分岐
		// top.node にも設定（ident_suffix 等が top.node^ を参照するため）
		ident := node_ident_new(tk.lexeme)
		(top.node)^ = ident
		top.saved = ident

	case .Block_Content_Kw_Case:
		// { case ... } → PLambda（パターンマッチ）

	// ====================================================================
	// block_after_ident (bparam 解決)
	// ====================================================================

	case .Block_After_Ident_Comma:
		// {x, y ... -> stmts} → 複数パラメータの bparam
		// top.node^ に Ident ノードが設定されている（Block_Content_Ident で設定）
		args := node_args_new()
		ident_node := (top.node)^
		if ident_node != nil {
			if id, ok := ident_node.data.(Node_Ident); ok {
				node_args_add(args, id.name)
			}
			node_free(ident_node)
			(top.node)^ = nil
		}
		top.saved = args

	case .Block_After_Ident_Await_Ident:
		// {x, y -> の y を保存
		// saved は Args ノード
		if top.saved != nil && top.saved.type == .Args {
			node_args_add(top.saved, tk.lexeme)
		}

	case .Block_After_Ident_Op_Lambda:
		// {x -> stmts} → 単一パラメータの bparam
		// top.node^ に Ident ノードが設定されている（Block_Content_Ident で設定）
		args := node_args_new()
		ident_node := (top.node)^
		if ident_node != nil {
			if id, ok := ident_node.data.(Node_Ident); ok {
				node_args_add(args, id.name)
			}
			node_free(ident_node)
		}
		lambda := node_lambda_new(args, nil)
		(&lambda.data.(Node_Lambda)).is_block = true
		(top.node)^ = lambda
		lambda_data := &lambda.data.(Node_Lambda)
		top.node = &lambda_data.body

	case .Block_After_Ident_Await_Op_Lambda:
		// {x, y -> stmts} → Op_Lambda 消費後、Lambda ノードを作成
		// saved は Args ノード
		args := top.saved
		lambda := node_lambda_new(args, nil)
		(&lambda.data.(Node_Lambda)).is_block = true
		(top.node)^ = lambda
		lambda_data := &lambda.data.(Node_Lambda)
		top.node = &lambda_data.body

	// ====================================================================
	// 引数リスト
	// ====================================================================

	case .Arg_Label:
		// label: expr → Pair ノード
		// label の lexeme からラベル名を取得
		pair := node_pair_new(tk.lexeme, nil)
		(top.node)^ = pair
		pair_data := &pair.data.(Node_Pair)
		top.node = &pair_data.value

	case .Arg_Op_Mult:
		// *expr → Splat ノード
		splat := node_splat_new(nil)
		(top.node)^ = splat
		splat_data := &splat.data.(Node_Splat)
		top.node = &splat_data.expr

	case .Arg_Rest_Comma:
		// 引数リストのカンマ → 次の引数スロットを作成
		// 親の配列ノードに新しいスロットを追加
		parent_idx := 1
		for parent_idx < queue.len(p.state_stack) {
			parent := queue.get_ptr(&p.state_stack, parent_idx)
			if parent.saved != nil {
				#partial switch parent.saved.type {
				case .Call:
					call_data := &parent.saved.data.(Node_Call)
					if call_data.args != nil {
						arr := &call_data.args.data.(Node_Array)
						append(&arr.elements, nil)
						top.node = &arr.elements[len(arr.elements) - 1]
					}
					return
				case .Fcall:
					fcall_data := &parent.saved.data.(Node_Fcall)
					if fcall_data.args != nil {
						arr := &fcall_data.args.data.(Node_Array)
						append(&arr.elements, nil)
						top.node = &arr.elements[len(arr.elements) - 1]
					}
					return
				case .Array:
					arr := &parent.saved.data.(Node_Array)
					append(&arr.elements, nil)
					top.node = &arr.elements[len(arr.elements) - 1]
					return
				}
			}
			parent_idx += 1
		}

	// ====================================================================
	// 関数仮引数 (f_args)
	// ====================================================================

	case .Opt_F_Args_Ident:
		// 最初の引数名
		args := node_args_new()
		node_args_add(args, tk.lexeme)
		(top.node)^ = args
		top.saved = args

	case .F_Args_Rest_Comma:
		// カンマ → 次の引数

	case .F_Args_Rest_Await_Ident:
		// 次の引数名
		// saved の Args ノードに追加
		parent_idx := 0
		for parent_idx < queue.len(p.state_stack) {
			parent := queue.get_ptr(&p.state_stack, parent_idx)
			if parent.saved != nil && parent.saved.type == .Args {
				node_args_add(parent.saved, tk.lexeme)
				return
			}
			parent_idx += 1
		}

	// ====================================================================
	// トップレベル
	// ====================================================================

	case .Topstmt_Kw_Namespace:
		// namespace Ident { program } → Ns ノード
		top.op = "namespace"

	case .Topstmt_Await_Ident:
		// namespace Ident → saved に名前を保存
		ns := node_ns_new(tk.lexeme, nil)
		(top.node)^ = ns
		top.saved = ns

	case .Topstmt_Await_Lbrace:
		// namespace Ident { → body に書き込み先を設定
		ns := top.saved
		if ns != nil && ns.type == .Ns {
			ns_data := &ns.data.(Node_Ns)
			top.node = &ns_data.body
		}

	case .Topstmt_Await_Rbrace:
		// namespace Ident { program } の '}'

	case .Topstmt_Kw_Class:
		top.op = "class"

	case .Topstmt_Await_Ident_2:
		// class Ident → Ns ノードとして扱う
		ns := node_ns_new(tk.lexeme, nil)
		(top.node)^ = ns
		top.saved = ns

	case .Topstmt_Await_Lbrace_2:
		ns := top.saved
		if ns != nil && ns.type == .Ns {
			ns_data := &ns.data.(Node_Ns)
			top.node = &ns_data.body
		}

	case .Topstmt_Await_Rbrace_2:
		// class { ... } の '}'

	case .Topstmt_Kw_Import:
		top.op = "import"

	case .Topstmt_Await_Ident_3:
		// import Ident
		(top.node)^ = node_import_new(tk.lexeme)

	case .Topstmt_Kw_Method:
		top.op = "method"

	case .Topstmt_Await_Lparen:
		// method fname(f_args) → fname は既に処理済み

	case .Topstmt_Await_Rparen:
		// method fname(f_args) → f_args パース完了、method_body に進む

	// ====================================================================
	// method_body
	// ====================================================================

	case .Method_Body_Lbrace:
		// { stmts } 形式のメソッドボディ

	case .Method_Body_Eq:
		// = expr 形式のメソッドボディ

	case .Method_Body_Await_Rbrace:
		// メソッドボディの '}' 消費

	// ====================================================================
	// case / cparam / pattern マッチング
	// ====================================================================

	case .Cparam_Op_Lambda:
		// | → ガードなし、パターンなしのcase節完了

	case .Cparam_Kw_If:
		// if → ガード付きcase節開始

	case .Cparam_Await_Op_Lambda:
		// if expr | → ガード付きcase節完了

	case .Cparam_Await_Op_Lambda_2:
		// pattern | → パターンcase節完了

	case .Cparam_Await_Kw_If:
		// pattern if → ガード付きパターンcase節開始

	case .Cparam_Await_Op_Lambda_3:
		// pattern if expr | → ガード付きパターンcase節完了

	case .Case_Body_Cont_Kw_Case:
		// 次のcase節

	case .Case_Body_Cont_Kw_Else:
		// else → デフォルトcase節

	case .Case_Body_Cont_Await_Op_Lambda:
		// else | → デフォルトcase節のボディ開始

	// ====================================================================
	// パターン
	// ====================================================================

	case .Pary_Or_Pstruct_Label:
		// label: pterm → PStruct の開始

	case .Pary_Rest_Comma:
		// パターン配列の次の要素

	case .Pstruct_Rest_Comma:
		// パターン構造体の次の要素

	case .Pstruct_Rest_Await_Label:
		// パターン構造体の次のラベル

	case .Pattern_Splat_Opt_Comma:
		// スプラットパターンのコンマ

	case .Pattern_Splat_Opt_Await_Op_Mult:
		// *ident のスプラット

	case .Splat_Tail_Comma:
		// スプラット後の末尾パターン

	// ====================================================================
	// pterm (パターン項)
	// ====================================================================

	case .Pterm_Ident:
		(top.node)^ = node_ident_new(tk.lexeme)

	case .Pterm_Lit_Number:
		if strings.contains_rune(tk.lexeme, '.') {
			value, ok := strconv.parse_f64(tk.lexeme)
			if ok {
				(top.node)^ = node_float_new(value)
			}
		} else {
			value, ok := strconv.parse_i64_of_base(tk.lexeme, 10)
			if ok {
				(top.node)^ = node_int_new(value)
			}
		}

	case .Pterm_Lit_String:
		(top.node)^ = node_str_new(tk.lexeme)

	case .Pterm_Kw_Nil:
		(top.node)^ = node_nil_new()

	case .Pterm_Kw_True:
		(top.node)^ = node_bool_new(true)

	case .Pterm_Kw_False:
		(top.node)^ = node_bool_new(false)

	case .Pterm_Lbracket:
		// '[' → パターン配列開始
		(top.node)^ = node_parray_new()

	case .Pterm_Suffix_At:
		// ident @ → 束縛パターン

	case .Pterm_Suffix_Await_Ident:
		// @ ident → 束縛変数名

	case .Pterm_Bracket_Content_Rbracket:
		// '[]' → 空のパターン配列

	case .Pterm_Bracket_Content_At:
		// [@ident...] パターン

	case .Pterm_Bracket_Content_Await_Ident:
		// [@ident] の ident

	case .Pterm_Bracket_Content_Await_Rbracket:
		// [pattern] の ']'

	case .Pterm_Bracket_At_Rbracket:
		// [@ident] の ']'

	case .Pterm_Bracket_At_Await_Rbracket:
		// [@ident pattern] の ']'

	// ====================================================================
	// term / terms
	// ====================================================================

	case .Term_Semicolon, .Term_Newline:
		// 文の区切り → 現在の文を Nodes リストに追加
		// Nodes リストを使ってプログラム全体を構築
		current_node := (top.node)^
		if current_node == nil {
			return
		}

		// 親を辿って Nodes リストまたはルートを見つける
		parent_idx := 1
		for parent_idx < queue.len(p.state_stack) {
			parent := queue.get_ptr(&p.state_stack, parent_idx)
			if parent.node != nil && (parent.node)^ != nil {
				parent_node := (parent.node)^
				if parent_node.type == .Nodes {
					// 既存の Nodes リストに追加
					return
				}
			}
			parent_idx += 1
		}

	case .None:
	// 何もしない
	}
}

// ============================================================================
// ヘルパー関数
// ============================================================================

// 括弧内の式から Lambda 引数リストを構築する
// (x) -> expr の x を Args ノードに変換
// () -> expr の場合は nil
@(private = "file")
build_lambda_args :: proc(args_node: ^Node) -> ^Node {
	if args_node == nil {
		return nil
	}

	// 既に Args ノードの場合はそのまま返す
	if args_node.type == .Args {
		return args_node
	}

	// 単一の Ident → Args に変換
	if args_node.type == .Ident {
		args := node_args_new()
		if id, ok := args_node.data.(Node_Ident); ok {
			node_args_add(args, id.name)
		}
		node_free(args_node)
		return args
	}

	// それ以外（例: (a, b) のような場合）は nil を返す
	// TODO: 複数引数のラムダサポート
	return nil
}
