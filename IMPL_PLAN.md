# llpgen - LL型 PushParser Generator 実装計画

## 1. 方針の選択肢

### 選択肢A: 専用DSL (yacc風)

**概要**: `.llp` のような専用ファイルを定義し、llpgen がそれを読み込んで Odin コードを生成する。

**入力例** (yacc風DSLを簡略化したもの):
```
%token keyword_if keyword_else ...
%token lit_number lit_string identifier

%left  op_bar
%left  op_and
%left  op_eq op_neq
%left  op_plus op_minus
%left  op_mult op_div op_mod

%%
program : topstmts ;
topstmts : topstmt_list opt_terms ;
topstmt : keyword_namespace identifier '{' topstmts '}' { node_ns_new($2, $4) }
        | stmt
        ;
stmt : var '=' expr { node_let_new($1, $3) }
     | expr
     ;
expr : expr op_plus expr { node_op_new("+", $1, $3) }
     | primary
     ;
%%
```

**メリット**:
- 文法の可読性が高い。BNF風の記法で構文規則を直感的に記述できる
- 文法記述と生成コードが明確に分離される
- yacc/bison の知識を持つ人にとって馴染みやすい
- 文法の検証（左再帰検出、FIRST/FOLLOW集合の衝突検出）を組み込める

**デメリット**:
- DSL自身のレキサー・パーサーを実装する必要がある（ブートストラップ問題）
- 実装コストが大きい（DSLパーサー + コードジェネレータ）
- DSLの表現力の限界に遭遇した場合、DSL自体の拡張が必要になる
- エラーメッセージの質がDSLの実装品質に依存する

### 選択肢B: Odin定義ファイル (DSL-in-Odin) + `core:odin/ast` による解析

**概要**: Odinの構文を使って文法を定義し、Odin標準ライブラリの
`core:odin/parser` + `core:odin/ast` でそのファイルをパースして内部表現に変換し、
コードを生成する。

**Odin標準ライブラリの提供機能**:
- `core:odin/parser`: `parse_file()` でOdinソースを完全なASTに変換
- `core:odin/ast`: `Value_Decl`, `Enum_Type`, `Struct_Type`, `Ident`, `Basic_Lit` 等の全AST型
- パーサー/レキサーの自作が完全に不要

参照:
- https://pkg.odin-lang.org/core/odin/ast/
- https://pkg.odin-lang.org/core/odin/parser/

**入力例** (Odinの有効な構文で文法を定義):
```odin
package grammar

// トークン定義は既存の Token_Type enum をそのまま参照
// （llpgen が Token_Type の定義を直接パースして取得する）

// 優先順位テーブル
Assoc :: enum { Left, Right, Nonassoc }
Prec_Entry :: struct { assoc: Assoc, tokens: []string }

precedence :: [?]Prec_Entry {
    { .Right,    {"Op_Lambda", "Op_Lambda2", "Op_Lambda3"} },
    { .Right,    {"Kw_Else"} },
    { .Right,    {"Kw_If"} },
    { .Left,     {"Op_Bar"} },
    { .Left,     {"Op_Amper"} },
    { .Left,     {"Op_Or"} },
    { .Left,     {"Op_And"} },
    { .Nonassoc, {"Op_Eq", "Op_Neq"} },
    { .Left,     {"Op_Lt", "Op_Le", "Op_Gt", "Op_Ge"} },
    { .Left,     {"Op_Plus", "Op_Minus"} },
    { .Left,     {"Op_Mult", "Op_Div", "Op_Mod"} },
    { .Right,    {"Op_Not", "Op_Tilde"} },
}

// 文の区切りトークン
terms :: []string { "Newline", "Semicolon" }

// 文法規則
// Rule :: struct { name: string, alts: [][]string }
// alt の各要素は: トークン名(大文字始まり) or 非終端記号名(小文字始まり)

rules :: [?]Rule {
    { "program",  { {"topstmt_list"} } },
    { "topstmt_list", { {"topstmt"}, {"topstmt_list", "TERM", "topstmt"} } },
    { "topstmt", {
        {"Kw_Namespace", "Ident", "Left_Brace", "topstmt_list", "Right_Brace"},
        {"Kw_Class", "Ident", "Left_Brace", "topstmt_list", "Right_Brace"},
        {"Kw_Import", "Ident"},
        {"stmt"},
    }},
    { "stmt", {
        {"Ident", "Op_Assign", "expr"},
        {"Kw_Skip"},
        {"Kw_Emit", "opt_args"},
        {"Kw_Return", "opt_args"},
        {"expr"},
    }},
    // ... 省略
}
```

**メリット**:
- **DSLパーサーの自作が完全に不要**: `core:odin/parser` が全て行う
- Odinの構文チェック・エラー報告をそのまま活用
- 文法定義ファイル自体がOdinコードとしてコンパイル・型検査可能
- llpgen の実装工数が大幅に減る（入力処理がほぼ無料）

**デメリット**:
- **文法記述がOdinの構文に制約される**: BNF風の `|` 区切りができず、配列リテラルで
  代替表現する必要がある。文法の可読性が `.y` や専用DSLに比べて劣る
- **AST走査ロジックの複雑さ**: `core:odin/ast` のAST構造に合わせた走査コードを
  書く必要がある。Value_Decl → values → Compound_Lit → elements → ... といった
  多段のunwrap処理が必要
- **Odinの構文制約で表現できない文法概念がある**:
  例えば EBNF の `(A B)*` をOdinの配列リテラルでどう表現するか、
  優先順位の `%left` / `%right` の対応づけが不自然になる
- **脆弱性**: `core:odin/ast` のAPI変更に影響を受ける（ただし安定したライブラリ）
- **デバッグの困難さ**: 文法記述のエラーがOdinの構文エラーとして報告されるため、
  「文法としてどこが間違っているか」のフィードバックが得にくい

### 選択肢C: 簡易DSL（推奨）

**概要**: yacc風だが大幅に簡略化した独自DSL。yaccの複雑さ（セマンティックアクション、型宣言、%union等）を排除し、**文法構造の記述に特化**する。アクション（AST構築ロジック）はDSL内ではなく、生成コードにフックポイントとして提供する。

**メリット**:
- DSLパーサーの実装が比較的容易（yacc程の複雑さがない）
- 文法の可読性が高い
- 既存のparse.yを参考にしながら段階的に移行できる
- 生成コードのカスタマイズポイントが明確

**デメリット**:
- DSLパーサーの実装は依然必要（ただし軽量）
- DSLの表現力に限界がある場合は拡張が必要

---

## 2. 選択肢BとCの詳細比較、および推奨

### 2.1 `core:odin/ast` を使う選択肢Bの実現可能性

Odin標準ライブラリの `core:odin/parser` + `core:odin/ast` を使えば、
DSLのレキサー・パーサーを自作せずに済む。これは大きな実装コスト削減となる。

**具体的な処理フロー（選択肢B）**:
```
grammar.odin (Odinの有効な構文で文法定義)
    ↓ core:odin/parser.parse_file()
ast.File (OdinのAST)
    ↓ llpgen のAST走査コード
Grammar 内部表現 (Rule, Production, Symbol)
    ↓ 分析 + コード生成
parse_generated.odin (Push Parser)
```

**AST走査の実装例**:
```odin
// ast.File.decls を走査して Value_Decl を探す
for decl in file.decls {
    if val_decl, ok := decl.derived.(^ast.Value_Decl); ok {
        // val_decl.names[0] が変数名 (例: "rules", "precedence")
        // val_decl.values[0] が配列リテラル (ast.Compound_Lit)
        // → 再帰的にunwrapして文法規則を抽出
    }
}
```

**選択肢Bの実装コスト見積り**:
- DSLレキサー: **不要**（0行）
- DSLパーサー: **不要**（0行）
- AST走査コード: 約200〜400行（`core:odin/ast` の型に合わせた走査）
- Grammar内部表現: 選択肢Cと同じ
- 分析 + コード生成: 選択肢Cと同じ

**選択肢Cの実装コスト見積り**:
- DSLレキサー: 約150〜250行
- DSLパーサー: 約300〜500行
- Grammar内部表現: 選択肢Bと同じ
- 分析 + コード生成: 選択肢Bと同じ

### 2.2 比較表

| 観点 | B: Odin AST解析 | C: 簡易DSL |
|------|-----------------|------------|
| 入力処理の実装コスト | 低（AST走査のみ） | 中（レキサー+パーサー） |
| 文法記述の可読性 | 低〜中（Odin構文に制約） | 高（BNF風で自然） |
| 文法記述の拡張性 | 低（Odin構文の範囲内） | 高（DSLを自由に拡張） |
| エラー報告の質 | 低（Odin構文エラーとして報告） | 高（文法固有のエラーを出せる） |
| 外部依存 | core:odin/ast に依存 | 依存なし |
| 保守性 | core:odin/ast のAPI変更に影響 | 完全に自己完結 |
| 学習コスト | core:odin/ast の構造理解が必要 | DSL仕様のみ |

### 2.3 推奨: 選択肢C（簡易DSL）

**結論: 選択肢Bは実現可能だが、選択肢Cを推奨する。**

理由:

1. **文法記述の可読性が最重要**: パーサージェネレータにおいて、入力となる文法定義の
   可読性は最も重要な品質指標。Odin構文に制約された配列リテラルでの文法記述は
   直感的でなく、保守が困難になる。

2. **DSLの実装コストは許容範囲**: 簡易DSLのレキサー・パーサーは合計450〜750行程度。
   `core:odin/ast` の走査コードも200〜400行かかるため、差は250〜350行程度。
   この差は文法可読性・拡張性の利点で十分にペイする。

3. **AST走査の隠れた複雑さ**: `core:odin/ast` の型階層は深く
   （Stmt → Decl → Value_Decl → values → Compound_Lit → elems → ...）、
   各段階での型アサーション・エラーハンドリングが必要。
   見た目よりコードが煩雑になりがち。

4. **自己完結性**: DSLアプローチは外部APIに依存せず、`core:odin/ast` の
   バージョン間差異を気にする必要がない。

5. **将来の拡張**: EBNF風の繰り返し `(A)*` やオプション `A?` の記法、
   セマンティックアクションの追加など、DSLは自由に拡張できる。

### 2.4 補足: 選択肢Bが有利なケース

以下の場合は選択肢Bの方が適切:
- 文法が非常に単純で、配列リテラルでの記述でも十分に読める場合
- `core:odin/ast` を他の目的（リファクタリングツール等）でも使う場合
- DSL実装を一切避けたい場合（プロトタイプの素早い検証等）

---

### 2.5 選択肢Cの詳細設計

#### 設計の基本方針

既存の `streem_odin/parse.odin` と `calc_odin/parse.odin` のコードを分析すると、Push Parser の構造には明確なパターンがある:

1. **状態の列挙** (`Parse_State_Kind`): 文法の各規則・位置に対応する状態
2. **状態遷移ループ** (`parser_push_token`): 状態に応じた分岐とトークン消費
3. **個別パース関数** (`parse_expr`, `parse_primary`, ...): 文法規則群ごとのハンドラ
4. **状態スタック操作** (`parser_begin`, `parser_end`, `parser_set_state`): 再帰的パースの実現

これらのパターンは文法規則から機械的に生成可能である。ただし、以下の部分はユーザーの手動記述が必要：

- **ASTノードの構築ロジック**: `node_op_new("+", $1, $3)` のような部分
- **トークンからの値抽出**: `strconv.parse_i64(tk.lexeme)` のような部分
- **特殊な文法的判断**: `is_term(tk)` のような部分

よって、文法構造をDSLで定義し、アクション部分を生成コードのフックとして提供する方針が最も実用的である。

### 2.2 DSLの設計

#### DSLファイル形式 (`.llp`)

```
// ============================================================
// ヘッダセクション: パッケージ名、トークン定義、優先順位
// ============================================================
%package streem

// トークン宣言（Token_Type enumの値に対応）
%token Eof Error Newline
%token Lit_Int Lit_Float Lit_String Lit_Symbol Lit_Time
%token Ident Label
%token Kw_If Kw_Else Kw_Case Kw_Emit Kw_Skip Kw_Return
%token Kw_Namespace Kw_Class Kw_Import Kw_Def Kw_Method Kw_New
%token Kw_Nil Kw_True Kw_False
%token Op_Plus Op_Minus Op_Mult Op_Div Op_Mod
%token Op_Eq Op_Neq Op_Lt Op_Le Op_Gt Op_Ge
%token Op_And Op_Or Op_Not
%token Op_Amper Op_Bar Op_Tilde
%token Op_Assign Op_Lasgn Op_Rasgn
%token Op_Lambda Op_Lambda2 Op_Lambda3
%token Op_Colon2
%token Left_Paren Right_Paren Left_Bracket Right_Bracket
%token Left_Brace Right_Brace Comma Semicolon Colon Dot At

// 優先順位（低い方から高い方へ）
%right Op_Lambda Op_Lambda2 Op_Lambda3
%right Kw_Else
%right Kw_If
%left  Op_Bar
%left  Op_Amper
%left  Op_Or
%left  Op_And
%nonassoc Op_Eq Op_Neq
%left  Op_Lt Op_Le Op_Gt Op_Ge
%left  Op_Plus Op_Minus
%left  Op_Mult Op_Div Op_Mod
%right Op_Not Op_Tilde

// term (文区切り)の定義
%term Newline Semicolon

// ============================================================
// 文法規則セクション
// ============================================================
%%

program
    : topstmt_list
    ;

topstmt_list
    : topstmt (term topstmt)*
    ;

topstmt
    : Kw_Namespace Ident Left_Brace topstmt_list Right_Brace
    | Kw_Class Ident Left_Brace topstmt_list Right_Brace
    | Kw_Import Ident
    | Kw_Method fname Left_Paren opt_f_args Right_Paren Left_Brace stmts Right_Brace
    | Kw_Method fname Left_Paren opt_f_args Right_Paren Op_Assign expr
    | stmt
    ;

stmts
    : stmt_list
    ;

stmt_list
    : stmt (term stmt)*
    ;

stmt
    : Ident Op_Assign expr
    | Kw_Def fname Left_Paren opt_f_args Right_Paren Left_Brace stmts Right_Brace
    | Kw_Def fname Left_Paren opt_f_args Right_Paren Op_Assign expr
    | Kw_Def fname Op_Assign expr
    | expr Op_Rasgn Ident
    | Kw_Skip
    | Kw_Emit opt_args
    | Kw_Return opt_args
    | expr
    ;

// ... 以下省略
%%
```

#### DSLの特徴

1. **yaccから引き継ぐもの**:
   - `%token` によるトークン宣言
   - `%left`, `%right`, `%nonassoc` による優先順位
   - `%%` によるセクション区切り
   - `:` と `|` による規則の定義

2. **yaccから削除するもの**:
   - `%union`, `%type` （Odinの型システムに委ねる）
   - `{ ... }` によるセマンティックアクション（生成コードのフック関数に置き換え）
   - `$1`, `$2` などのスタック参照（フック関数の引数で明示的に渡す）
   - `%pure-parser`, `%parse-param` 等のオプション

3. **独自の拡張**:
   - `%term` で文区切りトークンを定義（streemの `\n` / `;` に対応）
   - `%package` で生成先のパッケージ名を指定
   - EBNF風の `(A B)*` , `(A | B)?` 等の繰り返し・オプション記法（将来的に）

### 2.3 生成されるコード

DSLから以下のコードが自動生成される:

1. **Parse_State_Kind enum**: 各文法規則・位置に対応する状態の列挙
2. **parser_push_token関数**: メインディスパッチループ
3. **各parse_*関数のスケルトン**: 状態遷移のフレームワーク

ASTノード構築等のアクションは、生成コードが呼び出す**フック関数**（ユーザーが実装）を通じて行う。もしくは、初期バージョンではアクション部分はユーザーが生成コードを直接編集する形でもよい。

---

## 3. 実装ステップ

### Phase 1: DSLレキサー・パーサー（llpgen の入力処理）

**目標**: `.llp` ファイルを読み込み、内部表現（Grammar構造体）に変換する。

1. **Step 1.1**: llpgen用のトークン定義とレキサーの実装
   - `%token`, `%left`, `%right`, `%nonassoc`, `%term`, `%package`, `%%`, `:`, `|`, `;`, 識別子, 文字列リテラル
2. **Step 1.2**: llpgen用のパーサーの実装
   - ヘッダセクション（トークン宣言、優先順位）のパース
   - 文法規則セクションのパース
3. **Step 1.3**: Grammar 内部表現の定義
   - `Grammar`, `Rule`, `Production`, `Symbol` 等の構造体

### Phase 2: 文法解析

**目標**: Grammar 内部表現を解析し、LL(1)パーサーに必要な情報を計算する。

1. **Step 2.1**: FIRST集合の計算
2. **Step 2.2**: FOLLOW集合の計算
3. **Step 2.3**: LL(1)衝突の検出と報告
4. **Step 2.4**: 状態生成（各規則の各位置に対応するPush Parser状態の生成）

### Phase 3: コード生成

**目標**: 解析結果から Odin の Push Parser コードを生成する。

1. **Step 3.1**: Parse_State_Kind enum の生成
2. **Step 3.2**: parser_push_token ディスパッチ関数の生成
3. **Step 3.3**: 各parse_*関数の状態遷移コード生成
4. **Step 3.4**: フック関数のインターフェース定義の生成

### Phase 4: 検証

**目標**: 生成されたパーサーの動作を検証する。

1. **Step 4.1**: calc_odin の文法を `.llp` で記述し、生成コードが calc_odin/parse.odin と同等に動作することを検証
2. **Step 4.2**: streem の文法（parse.y に基づく）を `.llp` で記述し、生成コードが streem_odin/parse.odin と同等に動作することを検証

---

## 4. 補足: Push Parser の生成パターン

既存のコード（`calc_odin/parse.odin`, `streem_odin/parse.odin`）から抽出した Push Parser のパターン:

### 4.1 基本構造

```
Parse_State_Kind :: enum {
    Start, End, Error,
    // 文法規則ごとの状態...
    Rule_A,          // 規則Aの開始
    Rule_A_Cont,     // 規則Aの継続（次のシンボルを待つ）
    Rule_B,          // 規則Bの開始
    // ...
}
```

### 4.2 状態遷移パターン

文法規則 `A : B C D ;` に対して:

```
case .Rule_A:
    // Bをパースするために子状態をpush
    parser_set_state(p, .Rule_A_After_B)
    parser_begin(p, .Rule_B, top.node)
    return .Continue

case .Rule_A_After_B:
    // Cをパースするために子状態をpush
    parser_set_state(p, .Rule_A_After_C)
    parser_begin(p, .Rule_C, ...)
    return .Continue

case .Rule_A_After_C:
    // Dのトークンを消費
    if consumed(tk, .Token_D) {
        // アクション実行
        parser_end(p)
        return .Continue
    }
    parser_error(p, "Expected D")
```

### 4.3 選択（alternation）パターン

文法規則 `A : B | C | D ;` に対して:

```
case .Rule_A:
    if tk.type == .First_of_B {
        parser_set_state(p, .Rule_B)
        return .Continue
    }
    if tk.type == .First_of_C {
        parser_set_state(p, .Rule_C)
        return .Continue
    }
    // D がデフォルト
    parser_set_state(p, .Rule_D)
    return .Continue
```

### 4.4 繰り返しパターン

文法規則 `A_list : A (term A)* ;` に対して:

```
case .Rule_A_List:
    // 最初のAをパース
    parser_set_state(p, .Rule_A_List_Next)
    parser_begin(p, .Rule_A, ...)
    return .Continue

case .Rule_A_List_Next:
    // termがあれば次のAをパース
    if consume_term(tk) {
        parser_set_state(p, .Rule_A_List_Next)
        parser_begin(p, .Rule_A, ...)
        return .Continue
    }
    // termでなければリスト終了
    parser_end(p)
    return .Continue
```

---

## 5. ディレクトリ構成（予定）

```
llpgen/
├── IMPL_PLAN.md          # この文書
├── main.odin             # エントリーポイント
├── token.odin            # DSLレキサーのトークン定義
├── lex.odin              # DSLレキサー
├── grammar.odin          # Grammar 内部表現
├── parse.odin            # DSLパーサー（.llpファイルの解析）
├── analysis.odin         # FIRST/FOLLOW集合計算、衝突検出
├── codegen.odin          # Odinコード生成
├── examples/
│   ├── calc.llp          # 電卓文法（検証用）
│   └── streem.llp        # streem文法
└── tests/
    └── ...               # テスト
```
