# llpgen 実装手順 (Claude Code 作業用)

選択肢C（簡易DSL）で実装。各Stepは前のStepの成果物に依存する。

---

## ファイル構成

```
llpgen/
├── main.odin             # エントリーポイント (CLIツール)
├── token.odin            # DSLレキサーのトークン定義
├── lex.odin              # DSLレキサー
├── lex_test.odin         # レキサーテスト
├── grammar.odin          # Grammar 内部表現 (Rule, Production, Symbol等)
├── parse.odin            # DSLパーサー (.llpファイル → Grammar)
├── parse_test.odin       # パーサーテスト
├── analysis.odin         # FIRST/FOLLOW集合, 衝突検出
├── analysis_test.odin    # 分析テスト
├── codegen.odin          # Odin Push Parserコード生成
├── codegen_test.odin     # コード生成テスト
└── examples/
    ├── calc.llp           # 電卓文法 (検証用)
    └── streem.llp         # streem文法
```

---

## Phase 1: Grammar 内部表現 + DSLレキサー

### Step 1.1: grammar.odin — 内部表現の定義

他の全てのモジュールが依存する中心データ構造。最初に定義する。

```odin
package llpgen

// シンボルの種類
Symbol_Kind :: enum {
    Terminal,      // トークン (Token_Type のメンバー名に対応)
    Nonterminal,   // 非終端記号 (文法規則名)
    Epsilon,       // 空列 (ε)
}

// 文法シンボル
Symbol :: struct {
    kind: Symbol_Kind,
    name: string,      // Terminal: "Kw_If", "Op_Plus" 等
                       // Nonterminal: "expr", "stmt" 等
}

// 結合性
Assoc :: enum {
    None,      // %nonassoc
    Left,      // %left
    Right,     // %right
}

// 優先順位エントリ
Prec_Entry :: struct {
    level:  int,       // 優先順位レベル (1が最低, 数値が大きいほど高い)
    assoc:  Assoc,
    tokens: [dynamic]string,  // 適用されるトークン名
}

// 1つの生成規則 (alternative)
// 例: topstmt : Kw_Namespace Ident Left_Brace topstmt_list Right_Brace
//   → Production { symbols: [Kw_Namespace, Ident, Left_Brace, topstmt_list, Right_Brace] }
Production :: struct {
    symbols: [dynamic]Symbol,
}

// 文法規則 (1つの非終端記号に対する全alternative)
// 例: stmt : alt1 | alt2 | alt3 ;
//   → Rule { name: "stmt", productions: [alt1, alt2, alt3] }
Rule :: struct {
    name:        string,
    productions: [dynamic]Production,
}

// 文法全体
Grammar :: struct {
    package_name: string,              // %package で指定された名前
    tokens:       [dynamic]string,     // %token で宣言されたトークン名
    term_tokens:  [dynamic]string,     // %term で宣言された文区切りトークン
    precedence:   [dynamic]Prec_Entry, // 優先順位テーブル (index順に低→高)
    rules:        [dynamic]Rule,       // 文法規則
    start_rule:   string,              // 開始規則名 (最初のrule)
    // 以下は analysis.odin で設定
    token_set:    map[string]bool,     // 全トークンのセット (O(1)検索用)
    rule_map:     map[string]int,      // 規則名 → rules配列のインデックス
}
```

**実装ポイント**:
- grammar_new, grammar_destroy の alloc/free 管理
- grammar_add_token, grammar_add_rule 等のヘルパー
- grammar_is_terminal(name) → token_set で判定
- grammar_find_rule(name) → rule_map で検索

---

### Step 1.2: token.odin — DSLレキサーのトークン定義

```odin
package llpgen

Llp_Token_Type :: enum {
    Eof,
    Error,
    // ディレクティブ
    Dir_Package,     // %package
    Dir_Token,       // %token
    Dir_Left,        // %left
    Dir_Right,       // %right
    Dir_Nonassoc,    // %nonassoc
    Dir_Term,        // %term
    Separator,       // %%
    // 文法記号
    Colon,           // :
    Pipe,            // |
    Semicolon,       // ;
    // リテラル
    Ident,           // 識別子 (英数字 + アンダースコア)
    String_Lit,      // "..." 文字列リテラル (将来用)
    // コメント (レキサーが読み飛ばす)
}

Llp_Token :: struct {
    type:   Llp_Token_Type,
    lexeme: string,       // ソース上のスライス
    line:   int,
    column: int,
}
```

---

### Step 1.3: lex.odin — DSLレキサー

入力: `.llp` ファイルのテキスト
出力: `Llp_Token` の列

```
処理フロー:
1. 空白・改行をスキップ (行番号はトラッキング)
2. '//' の行コメントをスキップ
3. '%' で始まる → ディレクティブ or '%%'
4. ':' | '|' | ';' → 区切り文字
5. [a-zA-Z_] で始まる → 識別子
6. '"' で始まる → 文字列リテラル
7. その他 → エラー
```

ディレクティブのキーワード判定:
```
"%package"  → .Dir_Package
"%token"    → .Dir_Token
"%left"     → .Dir_Left
"%right"    → .Dir_Right
"%nonassoc" → .Dir_Nonassoc
"%term"     → .Dir_Term
"%%"        → .Separator
```

**実装ポイント**:
- calc_odin/lex.odin のパターンを踏襲 (Lex構造体, lex_scan_token)
- input はstringスライスで保持、lexeme は input[start:end] のスライス
- UTF-8 は考慮不要 (.llp はASCIIのみ)

### Step 1.4: lex_test.odin — レキサーテスト

テストケース:
- ディレクティブのトークン化: `%token Eof Error` → Dir_Token, Ident("Eof"), Ident("Error")
- 区切り記号: `%%` → Separator
- 文法規則: `program : topstmt_list ;` → Ident, Colon, Ident, Semicolon
- コメントの読み飛ばし
- 行番号トラッキング

**完了条件**: `odin test llpgen/ -test-name lex` が全テスト pass

---

## Phase 2: DSLパーサー

### Step 2.1: parse.odin — DSLパーサー

入力: レキサーのトークン列
出力: `Grammar` 構造体

```
.llpファイルの構造:
  [ヘッダセクション]    ← ディレクティブ
  %%
  [文法規則セクション]  ← BNF風の規則定義
  %%                    ← (オプション、あれば以降は無視)

ヘッダセクションのパース:
  %package <ident>
  %token <ident> <ident> ...
  %left <ident> <ident> ...
  %right <ident> <ident> ...
  %nonassoc <ident> <ident> ...
  %term <ident> <ident> ...

文法規則セクションのパース:
  <ident> : <symbol> <symbol> ... ;
  <ident> : <symbol> ... | <symbol> ... ;
  <ident> : <symbol> ...
          | <symbol> ...
          ;
```

パース関数:
```
parse_llp(input: string) -> (Grammar, bool)
  ├── parse_header_section()
  │   ├── parse_package_directive()    // %package streem
  │   ├── parse_token_directive()      // %token Eof Error ...
  │   ├── parse_precedence_directive() // %left Op_Plus Op_Minus
  │   └── parse_term_directive()       // %term Newline Semicolon
  ├── expect(.Separator)               // %%
  └── parse_rules_section()
      └── parse_rule() を繰り返し
          ├── <ident> → 規則名
          ├── ':'
          ├── parse_production() → シンボル列
          ├── ('|' parse_production())*
          └── ';'
```

**実装ポイント**:
- 再帰下降パーサー (DSLの文法は単純なのでLL(1)で十分)
- エラー報告: 行番号 + 期待されたトークン vs 実際のトークン
- シンボルが Terminal か Nonterminal かの判定:
  - この時点では名前だけ保持し、後で grammar.token_set と照合して確定
  - 慣例: 大文字始まりは Terminal、小文字始まりは Nonterminal
    (もしくは %token で宣言されたものが Terminal)

### Step 2.2: parse_test.odin — パーサーテスト

テストケース:
1. 最小限の文法:
```
%token Eof Number Plus
%%
expr : Number ;
%%
```
→ Grammar { tokens: [Eof, Number, Plus], rules: [{ name: "expr", productions: [[Number]] }] }

2. 複数alternativeの規則:
```
%token Eof Number Plus Minus
%left Plus Minus
%%
expr : expr Plus expr
     | expr Minus expr
     | Number
     ;
%%
```

3. 複数規則:
```
%token Eof Number Plus Minus Asterisk Slash Left_Paren Right_Paren
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
       | Left_Paren expr Right_Paren
       ;
%%
```

**完了条件**: `odin test llpgen/ -test-name parse` が全テスト pass

---

## Phase 3: 文法分析

### Step 3.1: analysis.odin — FIRST/FOLLOW集合と状態生成

#### 3.1a: token_set と rule_map の構築

Grammar パース後に呼ぶ初期化処理。
```
grammar_build_indices(g: ^Grammar):
  - g.token_set: %token で宣言された全トークン名のセット
  - g.rule_map: 規則名 → rules配列インデックスのマップ
  - 各 Production 内の Symbol.kind を確定:
    token_set にあれば .Terminal、rule_map にあれば .Nonterminal
```

#### 3.1b: FIRST集合の計算

```
// FIRST(X) = X から始まることのできる終端記号の集合
First_Sets :: map[string]map[string]bool  // 非終端記号名 → {トークン名}

compute_first_sets(g: ^Grammar) -> First_Sets:
  不動点アルゴリズム:
  1. 全非終端記号の FIRST を空で初期化
  2. 変化がなくなるまで繰り返し:
     各規則 A : X1 X2 ... Xn について:
       - X1 が Terminal → FIRST(A) に X1 を追加
       - X1 が Nonterminal → FIRST(A) に FIRST(X1) \ {ε} を追加
         X1 が ε を導出可能なら X2 も同様に処理、以下再帰的に
```

#### 3.1c: FOLLOW集合の計算

```
// FOLLOW(A) = A の直後に出現しうる終端記号の集合
Follow_Sets :: map[string]map[string]bool

compute_follow_sets(g: ^Grammar, firsts: First_Sets) -> Follow_Sets:
  不動点アルゴリズム:
  1. FOLLOW(開始記号) に $ (Eof) を追加
  2. 変化がなくなるまで繰り返し:
     各規則 A : ... B β ... について:
       - FOLLOW(B) に FIRST(β) \ {ε} を追加
       - β が ε を導出可能 (または β が空) → FOLLOW(B) に FOLLOW(A) を追加
```

#### 3.1d: LL(1)衝突検出

```
check_ll1_conflicts(g: ^Grammar, firsts, follows):
  各規則 A : alt1 | alt2 | ... について:
  - 各 alt_i の FIRST 集合を計算
  - alt_i と alt_j (i≠j) の FIRST に重複があれば衝突
  - alt_i が ε を導出可能なら、FIRST(alt_i) と FOLLOW(A) の重複も衝突

  警告として報告 (LL(1) 衝突は push parser では手動で解決可能なため fatal にしない)
```

#### 3.1e: Push Parser 状態の生成

```
// 各規則の各位置に対応する状態を生成
State :: struct {
    name:  string,    // 状態名 (Parse_State_Kind のメンバー名)
    rule:  string,    // 所属する規則名
    prod:  int,       // alternative番号
    pos:   int,       // ドット位置 (0 = 開始, len(symbols) = 完了)
}

generate_states(g: ^Grammar) -> [dynamic]State:
  常に生成される状態: Start, End, Error

  各規則 R について:
    R の開始状態: "R" (例: "Expr", "Stmt")

    各 alternative の各位置について:
      R_After_X 形式の状態名を生成
      (例: Kw_Def fname '(' opt_f_args ')' '{' stmts '}'
       → Def_Func, Def_Args, Def_Close_Paren, Def_Body_Start, Def_Body)
```

### Step 3.2: analysis_test.odin

テストケース:
1. 単純な文法でFIRST集合が正しいか
2. FOLLOW集合が正しいか
3. 衝突検出が動くか
4. 状態生成が正しいか

**完了条件**: `odin test llpgen/ -test-name analysis` が全テスト pass

---

## Phase 4: コード生成

### Step 4.1: codegen.odin — Odin Push Parser コードの生成

入力: Grammar + 分析結果 (FIRST/FOLLOW, 生成された状態)
出力: Odinソースコード文字列

生成するコードの構成要素:

#### 4.1a: Parse_State_Kind enum

```odin
// 生成例:
Parse_State_Kind :: enum {
    Start,
    End,
    Error,
    // -- program --
    Program,
    Program_Term,
    // -- topstmt --
    Topstmt,
    Namespace_Body,
    Namespace_Close,
    // ...
}
```

生成ロジック:
```
emit_state_enum(g: Grammar, states: []State):
  "Parse_State_Kind :: enum {\n"
  "\tStart,\n\tEnd,\n\tError,\n"
  for state in states:
    "\t{state.name},\n"
  "}\n"
```

#### 4.1b: Parse_State, Parser 構造体

calc_odin/parse.odin, streem_odin/parse.odin のパターンをテンプレートとして出力。
これらはほぼ固定テンプレート。

```odin
Parse_State :: struct {
    kind:  Parse_State_Kind,
    node:  ^^Node,
    saved: ^Node,
    op:    string,
    prec:  int,  // 必要に応じて
}

Parser :: struct {
    state_stack:   [dynamic]Parse_State,
    root:          ^Node,
    current_token: Token,
    fname:         string,
    lineno:        int,
    error_msg:     string,
    nerr:          int,
}
```

#### 4.1c: パーサーコア関数 (テンプレート)

以下は全パーサー共通のためテンプレートとしてそのまま出力:
- parser_new, parser_destroy, parser_reset
- parser_begin, parser_end, parser_get_state, parser_set_state
- parser_error
- consumed, is_term, consume_term

#### 4.1d: parser_push_token ディスパッチ関数

状態範囲に基づく分岐を生成。
各文法規則グループごとに parse_* 関数を呼び出す。

```odin
// 生成例:
parser_push_token :: proc(p: ^Parser, token: Token) -> Parse_Result {
    tk := token
    // ... (共通ループ構造)
    for i := 0; i < max_iterations; i += 1 {
        // ... (共通チェック)
        #partial switch pstate {
        case .Start, .End, .Error:
            action = parse_start(p, &tk)
        case .Program, .Program_Term:
            action = parse_program(p, &tk)
        case .Topstmt, .Namespace_Body, .Namespace_Close, .Import_:
            action = parse_topstmt(p, &tk)
        // ... 各グループ
        }
        // ...
    }
    // ...
}
```

#### 4.1e: 各 parse_* 関数のスケルトン生成

各文法規則に対して状態遷移コードを生成。
ただし **ASTノード構築 (アクション) 部分はコメントでTODOマーク** する。

```odin
// 生成例:
parse_program :: proc(p: ^Parser, tk: ^Token) -> Parse_Loop_Action {
    top := parser_get_state(p)
    if top == nil { return .Break }

    #partial switch top.kind {
    case .Program:
        if tk.type == .Eof || tk.type == .Right_Brace {
            parser_end(p)
            return .Continue
        }
        if consume_term(tk) {
            return .Continue
        }
        // TODO: create nodes container
        parser_set_state(p, .Program_Term)
        parser_begin(p, .Topstmt, top.node)
        return .Continue

    case .Program_Term:
        if tk.type == .Eof || tk.type == .Right_Brace {
            parser_end(p)
            return .Continue
        }
        if consume_term(tk) {
            parser_set_state(p, .Program)
            return .Continue
        }
        parser_set_state(p, .Program)
        return .Continue
    }
    return .Break
}
```

**生成パターンの分類** (IMPL_PLAN.md セクション4を参照):

1. **連接** `A : B C D` → 状態チェーン (A → A_After_B → A_After_C)
2. **選択** `A : B | C | D` → FIRST集合に基づく分岐
3. **繰り返し** `A_list : A (term A)*` → ループ状態
4. **トークン消費** `consumed(tk, .Token_X)` → 終端記号
5. **非終端記号呼び出し** `parser_begin(p, .Rule_X, ...)` → 非終端記号

### Step 4.2: codegen_test.odin

テストケース:
1. 最小限の文法で生成コードが構文的に正しい Odin であること
2. calc.llp からの生成コードが calc_odin/parse.odin の構造と一致すること

**完了条件**: 生成コードが `odin check` を通ること

---

## Phase 5: CLI + 検証

### Step 5.1: main.odin — CLIエントリーポイント

```
Usage: llpgen <input.llp> [-o output.odin]

処理:
1. コマンドライン引数を解析
2. .llp ファイルを読み込み
3. parse_llp() で Grammar に変換
4. grammar_build_indices() でインデックス構築
5. compute_first_sets(), compute_follow_sets() で集合計算
6. check_ll1_conflicts() で衝突検出 (警告出力)
7. generate_states() で状態生成
8. codegen() でコード生成
9. 出力ファイルに書き込み
```

### Step 5.2: examples/calc.llp — 電卓文法

calc_odin の文法を .llp で記述:
```
%package calc

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

### Step 5.3: 検証

1. `calc.llp` → 生成コード → calc_odin のテストと同等の動作確認
2. (将来) `streem.llp` → streem_odin/parse.odin と同等の動作確認

---

## 作業順序サマリー

```
Step 1.1  grammar.odin       (内部表現定義)
Step 1.2  token.odin          (トークン定義)
Step 1.3  lex.odin            (レキサー実装)
Step 1.4  lex_test.odin       (レキサーテスト) → odin test で確認
  ↓
Step 2.1  parse.odin          (パーサー実装)
Step 2.2  parse_test.odin     (パーサーテスト) → odin test で確認
  ↓
Step 3.1  analysis.odin       (FIRST/FOLLOW, 状態生成)
Step 3.2  analysis_test.odin  (分析テスト) → odin test で確認
  ↓
Step 4.1  codegen.odin        (コード生成)
Step 4.2  codegen_test.odin   (生成テスト) → odin check で確認
  ↓
Step 5.1  main.odin           (CLI)
Step 5.2  examples/calc.llp   (電卓文法)
Step 5.3  検証                (生成パーサーの動作テスト)
```

各Stepの完了条件:
- Step 1.4: `odin test llpgen/` でレキサーテストが pass
- Step 2.2: `odin test llpgen/` でパーサーテストが pass
- Step 3.2: `odin test llpgen/` で分析テストが pass
- Step 4.2: 生成コードが `odin check` を pass
- Step 5.3: 生成パーサーが calc_odin テストケースと同等に動作

---

## 実装時の注意点

1. **package名**: `package llpgen` を使用
2. **メモリ管理**: Odin の context.allocator を使用。テストでは context.temp_allocator も活用
3. **エラー処理**: 各段階で行番号付きエラーメッセージを返す (ok パターン)
4. **コード生成**: `strings.Builder` で文字列を組み立て、`fmt.sbprintf` で出力
5. **テスト実行**: `odin test llpgen/` (llpgen ディレクトリで `odin test .`)
6. **参照コード**:
   - calc_odin/lex.odin — レキサーの構造パターン
   - calc_odin/parse.odin — Push Parser の構造パターン
   - streem_odin/parse.odin — 本格的な Push Parser の例
   - streem_odin/token.odin — トークン定義の例
   - src/parse.y — 元の yacc 文法
