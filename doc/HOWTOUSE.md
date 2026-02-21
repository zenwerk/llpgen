# llpgen DSL リファレンス

llpgen は `.llp` ファイルに記述された文法定義から、Odin 言語用の LL(1) プッシュパーサーを生成するツールです。

## コマンドラインの使い方

```bash
# ビルド
odin build .

# パーサー生成 (stdout に出力)
odin run . -- input.llp

# パーサー生成 (ファイルに出力)
odin run . -- input.llp -o output_parse.odin
# → output_parse.odin (パーサー本体) と output_parse_token.odin (トークン定義) が生成される
```

`-o` を指定すると、`foo.odin` に対して `foo.odin`（パーサー）と `foo_token.odin`（トークン型）の 2 ファイルが生成されます。`-o` を省略すると両方が stdout にセパレータ付きで出力されます。

---

## `.llp` ファイルの構造

`.llp` ファイルは 3 つのセクションで構成されます:

```
<ヘッダセクション: ディレクティブ>
%%
<文法規則セクション>
%%
```

末尾の `%%` は省略可能です。コメントは `//` で行末まで記述できます。

---

## ヘッダセクション (ディレクティブ)

### `%package` — パッケージ名

生成コードの `package` 宣言に使用される名前を指定します。

```
%package calc
```

### `%token` — トークン宣言

文法で使用する終端記号（トークン）を宣言します。ここで宣言されたシンボルは終端記号として扱われ、宣言されていないシンボルは非終端記号（文法規則名）として扱われます。

```
%token Eof Error
%token Number Ident
%token Plus Minus Asterisk Slash
%token Left_Paren Right_Paren
```

- `%token` は複数行に分けて記述できます
- 1 行に複数のトークンをスペース区切りで列挙できます
- `Eof` と `Error` は必ず宣言してください（生成パーサーが内部で使用します）

### `%token_type` — トークン型名

生成されるトークン型の名前を指定します。デフォルトは `Token` です。

```
%token_type Token
```

これにより `Token_Type`（enum）、`Token`（struct）が生成されます。

### `%node_type` — ASTノード型名

生成パーサーが参照する AST ノードの型名を指定します。デフォルトは `Node` です。

```
%node_type Node
```

ユーザーはこの型と `node_free()` 関数、`on_parse_event()` コールバックを別ファイルで定義する必要があります。型名を `MyNode` に変更すると、生成コードは `^MyNode` や `my_node_free()` を参照します。

### `%left` / `%right` / `%nonassoc` — 演算子の優先順位と結合性

演算子トークンの優先順位と結合性を宣言します。**下の行ほど優先順位が高くなります**。

```
%left Plus Minus        // 優先順位 1 (低い)
%left Asterisk Slash    // 優先順位 2 (高い)
```

- `%left` — 左結合（`1 + 2 + 3` は `(1 + 2) + 3`）
- `%right` — 右結合（`a = b = c` は `a = (b = c)`）
- `%nonassoc` — 非結合（`a < b < c` はエラー。チェーンが禁止される）

これらの宣言は、演算子ループパターン（後述）で自動変換される規則に対して適用されます。`%nonassoc` の場合、生成されたパーサーは 2 回目の演算子使用時にエラーを報告します。

### `%term` — 文区切りトークン（パニックモード回復）

文区切りとなるトークンを宣言します。パースエラー時のパニックモード回復に使用されます。

```
%term Semicolon Newline
```

`%term` が宣言されている場合、生成されるトークンファイルに `is_term()` と `consume_term()` ヘルパー関数が追加されます。パースエラー発生時、Error 状態のパーサーは `%term` トークンに到達するまで入力を読み飛ばします。

### `%expect_conflict` — LL(1) 衝突の抑制

意図的な LL(1) 衝突の警告を抑制します。

```
%expect_conflict stmt 2
```

規則 `stmt` で最大 2 件の衝突を許容します。超過分は通常通り警告されます。

### `%max_iterations` — 最大ループ回数

`parser_push_token()` のメインループの最大反復回数を指定します。デフォルトは `1000` です。

```
%max_iterations 5000
```

無限ループ防止のための安全弁です。通常は変更不要です。

---

## 文法規則セクション

`%%` の後に文法規則を記述します。

### 基本構文

```
規則名 : シンボル1 シンボル2 ... ;
```

- **規則名**: 非終端記号の名前（`snake_case` を推奨）
- **シンボル**: トークン名（終端記号）または別の規則名（非終端記号）
- 規則はセミコロン `;` で終了します

### 複数の選択肢 (alternative)

`|` で区切って複数の生成規則を記述できます:

```
factor : Number
       | Left_Paren expr Right_Paren
       | Minus factor
       ;
```

### 空規則 (epsilon)

シンボルを 1 つも書かない選択肢は空（epsilon）生成規則になります:

```
opt_args : arg arg_rest
         |                  // 空 (epsilon)
         ;
```

### 開始規則

**最初に記述された規則が開始規則**（パースの起点）になります。

```
%%
program : stmts ;       // ← これが開始規則
stmts   : stmt stmts | ;
stmt    : expr Semicolon ;
```

### 規則記述のルール

- 規則名は `%token` で宣言されていない任意の識別子
- 同じ規則名を 2 回定義することはできません（1 つの規則に `|` で alternative をまとめてください）
- 再帰的な規則を記述できます（ただし左再帰には制約があります。後述）

---

## 演算子ループパターン (自動左再帰変換)

llpgen の最大の特徴は、左再帰の演算子パターンを自動的に反復ループに変換する機能です。

### 対象パターン

以下の形式の規則は演算子ループとして自動検出されます:

```
A : A op1 B
  | A op2 B
  | B
  ;
```

ここで:
- `A` は規則自身（左再帰）
- `op1`, `op2` は終端記号（演算子トークン）
- `B` は別の規則（ベースケース）
- 最後の選択肢が `B` 単体であること

### 実用例

```
// 左再帰パターンで自然に記述
expr : expr Plus term
     | expr Minus term
     | term
     ;

term : term Asterisk factor
     | term Slash factor
     | factor
     ;
```

このように書くと、生成パーサーでは以下の反復コードに変換されます:

```
// 生成されるコード (概念的)
parse_expr:
  parse_term()           // まず B をパース
  loop:
    if tk == Plus || tk == Minus:
      on_parse_event(.Expr_Op, tk, top)  // イベント発火
      consume(tk)
      parse_term()       // 右辺をパース
    else:
      break
```

### 前提条件

演算子ループとして認識されるには:

1. **規則が自身を左再帰で参照**している（`A : A ...`）
2. 左再帰の直後に**終端記号（演算子）**が来る（`A : A Op B`）
3. 最後の選択肢が**非終端記号 1 つだけ**のベースケースである（`| B`）
4. 全ての左再帰の選択肢のベースケースが同じ非終端記号（`B`）を参照

### `%left` / `%right` との連携

`%left`/`%right`/`%nonassoc` で宣言された演算子トークンが演算子ループの `op` に該当する場合、適切な結合性が生成コードに反映されます。

- `%nonassoc` の演算子が 2 回連続で使われると、生成パーサーがエラーを報告します

### 変換されない左再帰

演算子ループパターンに該当しない左再帰は、**致命的エラー**としてツールが停止します:

```
// NG: 演算子ループパターンに該当しない左再帰
list : list item ;     // ← Error: 演算子が挟まっていない
```

このような場合は手動で右再帰や反復パターンに書き換えてください:

```
// OK: 右再帰で書き換え
list : item list_rest ;
list_rest : item list_rest
          |
          ;
```

---

## パススルー規則の最適化

単一の非終端記号への委譲規則（パススルー規則）は、生成パーサーで自動的にインライン化されます:

```
lambda_expr : pipe_expr ;   // パススルー: 状態遷移なしでインライン化
```

これにより不要なスタック操作が省略され、パーサーの効率が向上します。パススルー規則が検出されると Info メッセージで通知されます。

---

## 間接左再帰の検出

llpgen は間接左再帰（循環する規則依存）も検出し、致命的エラーとして報告します:

```
// NG: 間接左再帰 (A → B → C → A)
a : b X ;
b : c Y ;
c : a Z ;   // ← Error: cycle a -> b -> c -> a
```

LL パーサーは間接左再帰を処理できないため、文法を書き換える必要があります。

---

## 生成されるファイル

### パーサーファイル (`*_parse.odin`)

| 要素 | 説明 |
|------|------|
| `Parse_State_Kind` enum | パーサーの全状態（`Start`, `End`, `Error`, 各規則の状態） |
| `Parse_Event` enum | AST 構築のためのコールバックイベント種別 |
| `Parse_State` struct | 状態種別、ノードポインタ(`node`)、保存ノード(`saved`)、演算子(`op`)、`user_data: rawptr` |
| `Parser` struct | 状態スタック、ルートノード、エラー情報 |
| `parser_new()` | パーサーの初期化（`Start` 状態でスタック初期化） |
| `parser_destroy()` | パーサーの破棄（AST含む） |
| `parser_reset()` | パーサーの再初期化 |
| `parser_push_token()` | トークンを 1 つ投入してパースを進める（メインAPI） |
| `parse_<規則名>()` | 各規則のステートマシン関数 |

### トークンファイル (`*_token.odin`)

| 要素 | 説明 |
|------|------|
| `Token_Type` enum | `%token` で宣言された全トークン |
| `Pos` struct | 位置情報（`offset`, `line`, `column`） |
| `Token` struct | `type`, `consumed`, `lexeme`, `pos` |
| `consumed()` | トークンが期待通りか確認して `consumed` フラグを立てる |
| `is_term()` | `%term` 宣言時のみ生成。トークンが文区切りかどうか |
| `consume_term()` | `%term` 宣言時のみ生成。文区切りトークンを消費 |

---

## ユーザーが実装する必要があるもの

生成パーサーを使うには、以下をユーザーが別ファイルで定義する必要があります:

### 1. AST ノード型

`%node_type` で指定した型（デフォルト: `Node`）を定義します:

```odin
Node :: struct {
    variant: union {
        Node_Number,
        Node_Binary,
        // ...
    },
}
```

### 2. ノード解放関数

`node_free()` (型名に応じて `<snake_case型名>_free()`) を定義します:

```odin
node_free :: proc(n: ^Node) {
    if n == nil { return }
    // 再帰的にノードを解放
    switch &v in n.variant {
    case Node_Number:
        // nothing
    case Node_Binary:
        node_free(v.left)
        node_free(v.right)
    }
    free(n)
}
```

### 3. パースイベントハンドラ

`on_parse_event()` を定義します。これが AST 構築のコア部分です:

```odin
on_parse_event :: proc(p: ^Parser, event: Parse_Event, tk: ^Token, top: ^Parse_State) {
    switch event {
    case .Factor_Number:
        // 数値リテラル → ノード作成
        (top.node)^ = node_new(Node_Number{value = parse_number(tk.lexeme)})

    case .Expr_Op:
        // 二項演算子 → 左辺を保存して Binary ノードを作成
        left := (top.node)^
        bin := node_new(Node_Binary{op = tk.type, left = left, right = nil})
        (top.node)^ = bin
        top.node = &bin.variant.(Node_Binary).right

    case .None:
        // 何もしない
    }
}
```

### 4. レキサー

llpgen はレキサーを生成しません。ユーザーが Token 型を返すレキサーを実装する必要があります:

```odin
lexer_next :: proc(l: ^Lexer) -> Token {
    // ...
    return Token{type = .Number, lexeme = "42", pos = Pos{...}}
}
```

---

## パーサーの使い方

```odin
main :: proc() {
    p := parser_new()
    defer parser_destroy(p)

    l := lexer_new(source)
    for {
        tk := lexer_next(&l)
        result := parser_push_token(p, tk)
        if result == .Parse_End {
            break
        }
    }

    if p.nerr > 0 {
        fmt.printfln("Error: %s", p.error_msg)
    } else if p.root != nil {
        // p.root に AST が構築されている
        process_ast(p.root)
    }
}
```

ポイント:
- `parser_push_token()` に 1 トークンずつ渡す **プッシュパーサー** 方式
- `.Parse_End` が返るまでトークンを投入し続ける
- エラーは `p.nerr > 0` で検出、`p.error_msg` にメッセージ
- 成功時は `p.root` に AST のルートノードが格納される

---

## イベントハンドラでの AST 構築パターン

### `top.node` — 現在のノード書き込み先

`top.node` は `^^Node` 型で、現在のパース位置が結果を書き込むべきポインタです。`(top.node)^ = new_node` で値を設定します。

### `top.saved` — 一時ノード保存

中間状態で参照が必要なノードを保存する場所です。例えば関数呼び出しで `(` の時点で `top.saved` に関数ノードを保存し、後の `)` で参照します。

### `top.op` — 演算子文字列

演算子ループで最後に消費された演算子の lexeme が格納されます。

### `top.user_data` — ユーザー定義データ

`rawptr` 型のフィールドで、イベントハンドラ間で任意のデータを受け渡すのに使用できます。

### スタック上の親状態を参照する

```odin
// スタックのインデックス 1 (現在の1つ上の親) を参照
parent := queue.get_ptr(&p.state_stack, 1)
```

---

## エラーと警告

### 致命的エラー (ツール終了)

| エラー | 原因 |
|--------|------|
| 未定義シンボル | `%token` にも規則名にもないシンボルを使用 |
| 直接左再帰 | 演算子ループパターンに該当しない左再帰 |
| 間接左再帰 | 規則間の循環参照 (A→B→C→A) |

### 警告 (続行)

| 警告 | 原因 | 対処 |
|------|------|------|
| LL(1) 衝突 | 同じ先頭トークンで複数の選択肢がマッチ | 文法の書き換え、または `%expect_conflict` で抑制 |
| 空 FIRST+FOLLOW | 規則がどのトークンでも開始できない | 文法の確認 |

### 情報メッセージ

| メッセージ | 内容 |
|-----------|------|
| パススルー規則 | 単一非終端記号への委譲が検出された |
| 演算子ループ | 左再帰パターンが検出され自動変換される |

---

## 完全な例: 電卓パーサー

### 文法定義 (`calc.llp`)

```
%package calc

%token_type Token
%node_type Node

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
%%
```

### パーサー生成

```bash
odin run . -- calc.llp -o calc_parse.odin
# → calc_parse.odin, calc_parse_token.odin が生成される
```

### ユーザー実装ファイル構成

```
calc_parse.odin         ← 生成: パーサー本体
calc_parse_token.odin   ← 生成: トークン型
calc_ast.odin           ← ユーザー: Node型, node_free(), on_parse_event()
calc_main.odin          ← ユーザー: レキサー, main()
```

生成されたパーサーの使い方については `examples/calc/` の実装を参照してください。
