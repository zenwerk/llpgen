# llpgen 改善計画: 簡潔なプッシュパーサー生成

## 現状の問題分析

### 手書きパーサーとの比較

calc_odin/parse.odin（手書き）と llpgen 生成コードを比較すると、根本的な設計思想の違いがある。

**手書き（16状態）**:
```
expr  → [Expr, Expr_Op]              — 2状態
term  → [Term, Term_Op]              — 2状態
factor → [Factor, Unary, Paren_Close] — 3状態
func_call → [Func_Call, Func_Args, Func_Args_Next, Func_Close] — 4状態
```

**llpgen（32 + 3基本 = 35状態）**:
```
expr   → 8状態  (各productionの各位置)
term   → 8状態
factor → 11状態
args   → 5状態
```

### 冗長性の根本原因

**問題1: 「production完了」状態の生成**

llpgen は各 production の最終シンボル処理後に専用の完了状態を作る:
```
case .Expr_After_Term:    // production 完了
    parser_end(p)
    return .Continue
case .Expr_After_Term_2:  // production 完了
    parser_end(p)
    return .Continue
case .Expr_After_Term_3:  // production 完了
    parser_end(p)
    return .Continue
```

手書き版では最終シンボル処理時に直接 `parser_end()` して完了状態自体が不要。

**問題2: 各 production を独立に展開する**

`expr : expr Plus term | expr Minus term | term` を3つの独立した production として扱い、
それぞれに状態を生成する。手書き版は:
```
case .Expr:    → term をパース → .Expr_Op に遷移
case .Expr_Op: → Plus/Minus なら term をパース（ループ）、なければ parse_end()
```
つまり「term の後に演算子があるか見る」という **イテレーティブパターン** を使い、
production の数に関係なく2状態で済ませている。

**問題3: 左再帰の未対処**

`expr : expr Plus term` は直接左再帰。LL パーサーでは原理的に処理不能。
手書き版は人間が `expr → term (op term)*` に書き換えている。

## 本質的な問い: LL(1) で十分か？

**結論: LL(1) で十分。ただし文法の書き換えが必要。**

手書き版 calc_odin/parse.odin は LL(1) パーサーそのものである。
streem_odin/parse.odin もプッシュ型 LL パーサーである。
問題は llpgen が「BNF をそのまま機械的に展開する」アプローチを取っていることにある。

手書きパーサーが簡潔なのは:

1. **左再帰の排除**: `A → A op B | B` を `A → B (op B)*` のイテレーティブ形式に変換
2. **意味的状態**: 「production の位置」ではなく「今何を待っているか」で状態を設計
3. **FOLLOW による暗黙終了**: 次トークンが期待外なら `parse_end()` で呼び出し元に戻す

これらは全て LL(1) の枠内で実現可能。

## 改善方針

### Phase 1: 左再帰の検出とエラー報告

**目的**: 壊れたコードを生成しない

**内容**:
- `grammar_build_indices()` 後に直接左再帰を検出
- `A : A ...` 形式の規則を見つけたらエラー終了
- エラーメッセージで修正方法を提示

```
Error: Left-recursive rule 'expr' detected (production 0: expr Plus term)
  LL parsers cannot handle left recursion.
  Rewrite as: expr : term expr_tail ;
              expr_tail : Plus term expr_tail | ;
  Or use %left/%right to enable operator-loop transformation.
```

**変更ファイル**: `llpgen/analysis.odin`, `llpgen/main.odin`

### Phase 2: 末尾状態の除去（状態数削減）

**目的**: 不要な状態の除去

**内容**:
- `generate_states()` で production の最終位置の状態を生成しない
  - 現状: `pos = 1..len(symbols)` → 変更後: `pos = 1..len(symbols)-1`
  - ただし len(symbols) == 1 の場合は中間状態を一切生成しない
- `emit_intermediate_case()` で `is_last == true` の場合に直接 `parser_end()` を呼ぶ（既に部分的に実装済み）
- `emit_production_body()` で最終シンボルが非終端の場合も `parser_end()` + `parser_begin()` で直接完了

**効果**: calc.llp の場合 35→約22状態に削減

**変更ファイル**: `llpgen/analysis.odin`, `llpgen/codegen.odin`

### Phase 3: イテレーティブ演算子ループ（`%left`/`%right` 活用）

**目的**: `A : A op B | B` パターンを `A → B (op B)*` に変換

これが最も効果の大きい改善。手書きの `Expr → Expr_Op` パターンを自動生成する。

**前提条件**: Phase 1 完了済み（左再帰検出）

**内容**:

1. **パターン検出**: 規則が以下の形式か判定
   ```
   A : A op1 B
     | A op2 B
     | ...
     | B        (ベースケース)
     ;
   ```
   条件:
   - 少なくとも1つの production が `A T ...` で始まる（直接左再帰）
   - 少なくとも1つの production が `A` で始まらない（ベースケース）
   - 左再帰 production の2番目のシンボルが terminal（演算子）

2. **変換後の状態生成**: 2つの状態のみ生成
   ```
   A:     B をパース → A_Op に遷移
   A_Op:  op があれば B をパース（ループ）、なければ parse_end()
   ```

3. **変換後のコード生成**:
   ```odin
   case .Expr:
       parser_set_state(p, .Expr_Op)
       parser_begin(p, .Term, top.node)
       return .Continue
   case .Expr_Op:
       if tk.type == .Plus || tk.type == .Minus {
           // TODO: AST construction
           tk.consumed = true
           parser_begin(p, .Term, top.node)
           return .Continue
       } else {
           parser_end(p)
           return .Continue
       }
   ```

4. **文法制約の緩和**: Phase 1 で「左再帰エラー」を出す代わりに、
   このパターンに該当する場合は自動変換を適用し、該当しない左再帰のみエラーとする。

**効果**: calc.llp の `expr`/`term` が各2状態になる（8→2, 8→2）

**変更ファイル**: `llpgen/analysis.odin`, `llpgen/codegen.odin`

### Phase 4: 非終端呼び出し後の FOLLOW ベース終了

**目的**: 非終端記号から戻った後の「次に何を待つか」を簡潔にする

**内容**:

現状は production の各位置に状態を作り、次シンボルを明示的にチェックする:
```
case .Factor_After_Left_Paren:
    parser_set_state(p, .Factor_After_Args)
    parser_begin(p, .Args, top.node)
    return .Continue
case .Factor_After_Args:
    if consumed(tk, .Right_Paren) { ... }
```

改善後は「非終端呼び出し後に期待するシンボル」を直接チェック:
```
case .Factor_Paren:
    parser_begin(p, .Args, top.node)
    parser_set_state(p, .Factor_Close_Paren) // 戻ったら次はこの状態
    return .Continue
case .Factor_Close_Paren:
    if consumed(tk, .Right_Paren) { ... }
```

つまり「After_X」ではなく「次に何を待つか」で状態名を付ける。
これにより中間状態が削減され、手書き版に近い読みやすいコードになる。

**変更ファイル**: `llpgen/analysis.odin`, `llpgen/codegen.odin`

### Phase 5: ディスパッチの改善 (is_between → #partial switch)

**目的**: streem_odin/parse.odin のように状態列挙で直接ディスパッチ

**内容**:
```odin
// 現状
if is_between(pstate, .Expr, .Expr_After_Term_3) {
    action = parse_expr(p, &tk)

// 改善後
#partial switch pstate {
case .Expr, .Expr_Op:
    action = parse_expr(p, &tk)
```

**利点**: 状態範囲に依存しないため、enum の順序変更に強い

**変更ファイル**: `llpgen/codegen.odin`

## 実施順序

```
Phase 1 (左再帰検出)
    ↓
Phase 2 (末尾状態除去)     ← 独立して実施可能
    ↓
Phase 3 (演算子ループ)     ← Phase 1 に依存
    ↓
Phase 4 (状態名改善)       ← Phase 2 に依存
    ↓
Phase 5 (ディスパッチ改善) ← Phase 4 に依存
```

Phase 1 と Phase 2 は独立して実施可能。
Phase 3 が最も効果が大きく、Phase 1 の後すぐに実施すべき。

## 期待される最終結果

calc.llp（ただし左再帰を排除した文法に書き換えた場合）:
```
状態数: 35 → 約15
parse関数: 各規則2-4状態
コード行数: 520行 → 約200行
```

手書き版（16状態, 420行）とほぼ同等の出力が期待できる。
