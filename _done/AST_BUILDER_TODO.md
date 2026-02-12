# AST Builder: イベント方式の実装 TODO

## 概要

現在、生成コード内の AST 構築箇所は `// TODO: AST node construction` コメントとしてマークされている。
この方式では再生成時にユーザーの AST 構築コードが上書きされてしまう。

**解決策**: パーサーがパースイベントを発行し、ユーザーが別ファイルで `on_parse_event` ハンドラを実装する方式に変更する。

## 設計

### 生成されるコード (再生成しても安全)

```odin
// --- パーサーファイル (_parser.odin) に生成 ---

// パースイベント種別
Parse_Event :: enum {
    None,
    // -- expr --
    Expr_Operator,            // expr: 演算子 (Plus/Minus) がマッチ
    // -- term --
    Term_Operator,            // term: 演算子 (Asterisk/Slash) がマッチ
    // -- factor --
    Factor_Number,            // factor: Number がマッチ (production 0)
    Factor_Ident,             // factor: Ident がマッチ (production 1, 先頭)
    Factor_Left_Paren,        // factor: Left_Paren がマッチ (production 2, 先頭)
    Factor_Minus,             // factor: Minus がマッチ (production 3, 先頭)
    Factor_Await_Left_Paren,  // factor: Ident後の Left_Paren を消費
    Factor_Await_Right_Paren, // factor: 関数呼出し後の Right_Paren を消費
    Factor_Await_Right_Paren_2, // factor: 括弧式後の Right_Paren を消費
    // -- args --
    Args_Operator,            // args: 演算子 (Comma) がマッチ
}

// 使用例 (生成コード内):
case .Factor:
    if tk.type == .Number {
        on_parse_event(p, .Factor_Number, tk, top)  // ← TODO の代わり
        tk.consumed = true
        parser_end(p)
        return .Continue
```

### ユーザー実装 (別ファイル, 再生成で上書きされない)

```odin
// --- ast_builder.odin (ユーザーが実装) ---
package calc

on_parse_event :: proc(p: ^Parser, event: Parse_Event, tk: ^Token, top: ^Parse_State) {
    #partial switch event {
    case .Factor_Number:
        value, _ := strconv.parse_f64(tk.lexeme)
        (top.node)^ = node_new(Node_Number{value = value})
    case .Expr_Operator:
        left := (top.node)^
        bin := node_new(Node_Binary{op = tk.type, left = left})
        (top.node)^ = bin
        top.node = &bin.variant.(Node_Binary).right
    // ... 他のイベント
    }
}
```

## イベント発行箇所の分類

### カテゴリ A: 通常規則の開始状態 (pos == 0)

各 production の先頭シンボルにマッチした時点で発行。

| 発行箇所 | イベント名パターン | 文脈 |
|----------|-------------------|------|
| `emit_production_body()` | `<Rule>_<Terminal>` | 先頭が Terminal の production |
| `emit_production_body()` | なし (不要) | 先頭が Nonterminal の production (ノード構築不要) |

codegen.odin での該当行: L602

### カテゴリ B: 通常規則の中間状態 (pos > 0)

中間状態で Terminal を `consumed()` した時点で発行。

| 発行箇所 | イベント名パターン | 文脈 |
|----------|-------------------|------|
| `emit_intermediate_case()` | `<Rule>_Await_<Terminal>` | 状態名をそのまま使う |

codegen.odin での該当行: L689

### カテゴリ C: 演算子ループの _Op 状態

演算子がマッチした時点で発行。

| 発行箇所 | イベント名パターン | 文脈 |
|----------|-------------------|------|
| `emit_operator_loop_function()` | `<Rule>_Operator` | 演算子にマッチした時 |

codegen.odin での該当行: L797

### カテゴリ D: 演算子ループのベースケース

`emit_operator_loop_base_case()` 内で先頭 Terminal を消費する箇所。
単純な Nonterminal ベースケース (例: `expr : term`) では不要。

codegen.odin での該当行: L826, L859, L868

## 実装手順

### Phase 1: Parse_Event enum の生成

**変更ファイル**: `llpgen/codegen.odin`

1. `emit_event_enum(b, input)` 関数を新規作成
   - `codegen()` 内で `emit_state_enum()` の直後に呼び出す
   - `Parse_Event :: enum { None, ... }` を生成

2. イベント名の生成ロジック:
   - **カテゴリ A**: 規則の開始状態で、先頭が Terminal の production ごとに1つ
     - 命名: `<Rule_Pascal>_<Terminal>` (例: `Factor_Number`, `Factor_Ident`)
     - 先頭が Nonterminal の production では生成しない (構築不要)
   - **カテゴリ B**: 中間状態（Await_ 状態）ごとに1つ
     - 命名: 状態名をそのまま使用 (例: `Factor_Await_Left_Paren`)
   - **カテゴリ C**: 演算子ループ規則ごとに1つ
     - 命名: `<Rule_Pascal>_Operator` (例: `Expr_Operator`, `Term_Operator`)
   - **カテゴリ D**: 演算子ループのベースケースで先頭が Terminal の場合
     - 命名: `<Rule_Pascal>_<Terminal>` (カテゴリ A と同じパターン)

3. 実装の注意点:
   - イベント名を収集するフェーズと出力フェーズを分ける
   - 収集は `[dynamic]string` にイベント名を追加していく
   - 規則ごとにコメントでグループ分け (state enum と同じスタイル)

### Phase 2: `on_parse_event` 呼び出しの挿入

**変更ファイル**: `llpgen/codegen.odin`

1. `// TODO: AST node construction` コメントを `on_parse_event(p, .<EventName>, tk, top)` 呼び出しに置換

2. 各 emit 関数の修正:
   - `emit_production_body()` (L602): カテゴリ A
     - 先頭が Terminal の場合のみイベント発行
     - 先頭が Nonterminal の場合は発行しない
   - `emit_intermediate_case()` (L689): カテゴリ B
     - `consumed()` 成功時にイベント発行
   - `emit_operator_loop_function()` (L797): カテゴリ C
     - 演算子マッチ時にイベント発行
   - `emit_operator_loop_base_case()` (L826, L859, L868): カテゴリ D
     - 先頭 Terminal 消費時にイベント発行

3. イベント名の導出は Phase 1 と同じロジックを使う
   - 共通のイベント名導出ヘルパーが必要

### Phase 3: ヘッダコメントの更新

**変更ファイル**: `llpgen/codegen.odin`

1. `emit_header()` のコメントブロックを更新:
   ```
   // このパーサーを使用するには、以下の型と関数を別ファイルで定義してください:
   //
   //   Node :: struct { ... }       // AST ノード型
   //   node_free(n: ^Node)          // ノードの再帰的解放
   //   on_parse_event(p: ^Parser, event: Parse_Event, tk: ^Token, top: ^Parse_State)
   //                                // パースイベントハンドラ
   //
   // トークン型は _token.odin に自動生成されます。
   ```

### Phase 4: テスト

**変更ファイル**: `llpgen/codegen_test.odin`

1. 新規テスト:
   - `codegen_parse_event_enum_test`: Parse_Event enum が生成されること
   - `codegen_on_parse_event_call_test`: `on_parse_event` 呼び出しが生成されること
   - `codegen_no_todo_comment_test`: `// TODO: AST` が生成コードに含まれないこと
   - `codegen_event_operator_loop_test`: 演算子ループのイベントが正しく生成されること

2. 既存テスト修正:
   - `// TODO` を検証しているテストがあれば更新

### Phase 5: E2E 検証

1. `odin test llpgen/` — 全テスト合格
2. `odin build llpgen/` — ビルド成功
3. `./llpgen/llpgen llpgen/examples/calc.llp -o /tmp/llpgen_check/generated.odin`
4. 生成コードに `// TODO` が含まれないこと
5. 生成コードに `on_parse_event(p,` が含まれること
6. `Parse_Event :: enum` が生成されていること
7. `odin check` — スタブに `on_parse_event` を追加して構文検証

## イベント名導出のヘルパー設計

```
// イベント名を導出する共通ロジック
// (codegen.odin 内に @(private = "file") で追加)

// カテゴリ A/D: 開始状態での Terminal マッチ
//   rule="factor", terminal="Number" → "Factor_Number"
event_name_for_match :: proc(rule_name, terminal_name: string) -> string

// カテゴリ B: 中間状態 (状態名をそのまま使用)
//   state_name="Factor_Await_Left_Paren" → "Factor_Await_Left_Paren"
// → ヘルパー不要、状態名をそのまま使う

// カテゴリ C: 演算子ループ
//   rule="expr" → "Expr_Operator"
event_name_for_operator :: proc(rule_name: string) -> string
```

## calc.llp から生成されるイベント一覧 (期待値)

```
Parse_Event :: enum {
    None,
    // -- expr --
    Expr_Operator,
    // -- term --
    Term_Operator,
    // -- factor --
    Factor_Number,
    Factor_Ident,
    Factor_Left_Paren,
    Factor_Minus,
    Factor_Await_Left_Paren,
    Factor_Await_Right_Paren,
    Factor_Await_Right_Paren_2,
    // -- args --
    Args_Operator,
}
```

計 10 イベント。これは先述のサンプルコードと一致する。
