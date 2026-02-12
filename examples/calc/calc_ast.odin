package calc

import "core:container/queue"
import "core:strconv"
import "core:fmt"

// AST ノード種別
Node_Number :: struct {
	value: f64,
}

Node_Unary :: struct {
	op:      Token_Type, // .Minus のみ
	operand: ^Node,
}

Node_Binary :: struct {
	op:    Token_Type, // .Plus, .Minus, .Asterisk, .Slash
	left:  ^Node,
	right: ^Node,
}

Node_Func_Call :: struct {
	name: string,
	args: [dynamic]^Node,
}

// AST ノード
Node :: struct {
	variant: union {
		Node_Number,
		Node_Unary,
		Node_Binary,
		Node_Func_Call,
	},
}

// ノードを作成する
node_new :: proc(variant: $T) -> ^Node {
	n := new(Node)
	n.variant = variant
	return n
}

// ノードを再帰的に解放する
node_free :: proc(n: ^Node) {
	if n == nil {
		return
	}
	switch &v in n.variant {
	case Node_Number:
	// nothing to free
	case Node_Unary:
		node_free(v.operand)
	case Node_Binary:
		node_free(v.left)
		node_free(v.right)
	case Node_Func_Call:
		for arg in v.args {
			node_free(arg)
		}
		delete(v.args)
	}
	free(n)
}

// パースイベントハンドラ
//
// 生成されたパーサーから各イベント発生時に呼び出される。
// top.node, top.saved, top.op を使って AST を構築する。
//
// イベント発火のタイミング:
//   生成コードでは on_parse_event の呼び出し後に tk.consumed = true と
//   parser_begin/parser_set_state が続く。つまりこのハンドラ内で
//   top.node を変更すると、後続の parser_begin に反映される。
on_parse_event :: proc(p: ^Parser, event: Parse_Event, tk: ^Token, top: ^Parse_State) {
	switch event {

	// ── expr: 二項演算子 (+, -) ──
	// 呼び出し元: parse_expr の Expr_Op 状態
	// 直後: parser_begin(p, .Term, top.node)
	case .Expr_Op:
		left := (top.node)^
		bin := node_new(Node_Binary{op = tk.type, left = left, right = nil})
		(top.node)^ = bin
		// top.node を右辺に切り替え → 次の Term がここに書き込む
		bin_variant := &bin.variant.(Node_Binary)
		top.node = &bin_variant.right

	// ── term: 二項演算子 (*, /) ──
	// 呼び出し元: parse_term の Term_Op 状態
	// 直後: parser_begin(p, .Factor, top.node)
	case .Term_Op:
		left := (top.node)^
		bin := node_new(Node_Binary{op = tk.type, left = left, right = nil})
		(top.node)^ = bin
		bin_variant := &bin.variant.(Node_Binary)
		top.node = &bin_variant.right

	// ── factor: 数値リテラル ──
	// 呼び出し元: parse_factor の Factor 状態
	// 直後: tk.consumed, parser_end
	case .Factor_Number:
		value, ok := strconv.parse_f64(tk.lexeme)
		if !ok {
			parser_error(p, fmt.tprintf("Invalid number: %s", tk.lexeme))
			return
		}
		(top.node)^ = node_new(Node_Number{value = value})

	// ── factor: 識別子 (関数呼び出しの開始) ──
	// 呼び出し元: parse_factor の Factor 状態
	// 直後: tk.consumed, parser_set_state(.Factor_Await_Left_Paren)
	case .Factor_Ident:
		func_node := node_new(Node_Func_Call{
			name = tk.lexeme,
			args = make([dynamic]^Node),
		})
		(top.node)^ = func_node

	// ── factor: '(' expr ')' の開始 ──
	// 呼び出し元: parse_factor の Factor 状態
	// 直後: tk.consumed, parser_set_state(.Factor_Await_Right_Paren_2),
	//        parser_begin(p, .Expr, top.node)
	case .Factor_Left_Paren:
		// 括弧式: Expr の結果がそのまま top.node^ に書き込まれるため何もしない

	// ── factor: 単項マイナス ──
	// 呼び出し元: parse_factor の Factor 状態
	// 直後: tk.consumed, parser_end, parser_begin(p, .Factor, top.node)
	case .Factor_Minus:
		unary := node_new(Node_Unary{op = .Minus, operand = nil})
		(top.node)^ = unary
		// top.node を operand に切り替え → 次の Factor がここに書き込む
		unary_variant := &unary.variant.(Node_Unary)
		top.node = &unary_variant.operand

	// ── factor: 関数呼び出しの '(' を消費 ──
	// 呼び出し元: parse_factor の Factor_Await_Left_Paren 状態
	// 直後: parser_set_state(.Factor_Await_Right_Paren),
	//        parser_begin(p, .Args, top.node)
	case .Factor_Await_Left_Paren:
		// func_call ノードは既に top.node^ に設定済み
		// top.saved に保存して、Args_Operator から参照できるようにする
		top.saved = (top.node)^

		// 最初の引数スロットを準備
		func_node := &((top.node)^.variant.(Node_Func_Call))
		append(&func_node.args, nil)
		arg_idx := len(func_node.args) - 1
		// top.node を引数スロットに切り替え → parser_begin(p, .Args, top.node)
		// で Args に渡される
		top.node = &func_node.args[arg_idx]

	// ── factor: 関数呼び出しの ')' を消費 ──
	// 呼び出し元: parse_factor の Factor_Await_Right_Paren 状態
	// 直後: parser_end
	case .Factor_Await_Right_Paren:
		// 引数パース完了。空引数の場合、args[0] が nil のままなので除去する
		func_node := &(top.saved.variant.(Node_Func_Call))
		if len(func_node.args) == 1 && func_node.args[0] == nil {
			// 空引数リスト: foo() のケース
			clear(&func_node.args)
		}

	// ── factor: 括弧式の ')' を消費 ──
	// 呼び出し元: parse_factor の Factor_Await_Right_Paren_2 状態
	// 直後: parser_end
	case .Factor_Await_Right_Paren_2:
		// 括弧式完了。何もしない。

	// ── args: カンマで次の引数へ ──
	// 呼び出し元: parse_args の Args_Op 状態
	// 直後: tk.consumed, parser_begin(p, .Expr, top.node)
	case .Args_Op:
		// top は Args 状態の Parse_State
		// 親状態 (Factor_Await_Right_Paren) は state_stack のインデックス 1
		parent := queue.get_ptr(&p.state_stack, 1)
		func_node := &(parent.saved.variant.(Node_Func_Call))

		// 新しい引数スロットを追加
		append(&func_node.args, nil)
		arg_idx := len(func_node.args) - 1
		// top.node を新しいスロットに切り替え → 次の Expr がここに書き込む
		top.node = &func_node.args[arg_idx]

	case .None:
	// 何もしない
	}
}
