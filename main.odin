package llpgen

import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"

Options :: struct {
	input:  string `args:"pos=0,required" usage:"Input .llp grammar file."`,
	output: string `args:"name=o"         usage:"Output file (default: stdout)."`,
}

main :: proc() {
	opt: Options
	flags.parse_or_exit(&opt, os.args, .Unix)

	// 1. .llp ファイルを読み込み
	data, ok := os.read_entire_file(opt.input)
	if !ok {
		fmt.eprintfln("Error: cannot read file '%s'", opt.input)
		os.exit(1)
	}
	input := string(data)

	// 2. parse_llp() で Grammar に変換
	g, parse_ok := parse_llp(input)
	defer grammar_destroy(&g)
	if !parse_ok {
		fmt.eprintfln("Error: parse failed")
		os.exit(1)
	}

	// 3. grammar_build_indices() でインデックス構築
	grammar_build_indices(&g)

	// 3.1. 未定義シンボルの検出
	undef_syms := check_undefined_symbols(&g)
	defer delete(undef_syms)
	if len(undef_syms) > 0 {
		fmt.eprintfln("Error: %d undefined symbol(s) found:", len(undef_syms))
		for &us in undef_syms {
			fmt.eprintfln("  '%s' used in rule '%s' (production %d) is not defined as a %%token or grammar rule",
				us.name, us.rule_name, us.prod_idx)
		}
		os.exit(1)
	}

	// 3.5. 演算子ループパターンの検出 + 変換不可能な左再帰の検出
	op_loops := detect_operator_loops(&g)
	defer operator_loops_destroy(&op_loops)

	if len(op_loops) > 0 {
		fmt.eprintfln("Info: %d operator-loop rule(s) detected:", len(op_loops))
		for name, &loop in op_loops {
			fmt.eprintfln("  rule '%s': %s (op %s)* pattern",
				name, loop.base_name, strings.join(loop.operators[:], ", ", context.temp_allocator))
		}
	}

	// 演算子ループで変換できない左再帰のみエラーにする
	left_recs := check_left_recursion(&g)
	defer delete(left_recs)
	unhandled_left_recs: [dynamic]Left_Recursion
	defer delete(unhandled_left_recs)
	for &lr in left_recs {
		if lr.rule_name not_in op_loops {
			append(&unhandled_left_recs, lr)
		}
	}
	if len(unhandled_left_recs) > 0 {
		fmt.eprintfln("Error: %d direct left recursion(s) cannot be auto-transformed:", len(unhandled_left_recs))
		for &lr in unhandled_left_recs {
			rule, _ := grammar_find_rule(&g, lr.rule_name)
			prod := &rule.productions[lr.prod_idx]
			sym_buf: strings.Builder
			strings.builder_init(&sym_buf, context.temp_allocator)
			for &sym, i in prod.symbols {
				if i > 0 { fmt.sbprint(&sym_buf, " ") }
				fmt.sbprint(&sym_buf, sym.name)
			}
			fmt.eprintfln("  rule '%s' production %d: %s",
				lr.rule_name, lr.prod_idx, strings.to_string(sym_buf))
		}
		fmt.eprintln("  LL parsers cannot handle left recursion.")
		fmt.eprintln("  Rewrite using right recursion or iteration, e.g.:")
		fmt.eprintln("    expr : term expr_tail ;")
		fmt.eprintln("    expr_tail : Plus term expr_tail | ;")
		os.exit(1)
	}

	// 3.6. 間接左再帰の検出
	indirect_recs := check_indirect_left_recursion(&g, &op_loops)
	defer indirect_left_recursion_destroy(&indirect_recs)
	if len(indirect_recs) > 0 {
		fmt.eprintfln("Error: %d indirect left recursion(s) detected:", len(indirect_recs))
		for &ir in indirect_recs {
			fmt.eprintf("  cycle: ")
			for name, i in ir.cycle {
				if i > 0 { fmt.eprintf(" -> ") }
				fmt.eprintf("%s", name)
			}
			fmt.eprintln()
		}
		fmt.eprintln("  LL parsers cannot handle indirect left recursion.")
		fmt.eprintln("  Rewrite the grammar to eliminate the cycle.")
		os.exit(1)
	}

	// 4. compute_first_sets(), compute_follow_sets() でFIRST/FOLLOW集合を計算
	firsts := compute_first_sets(&g)
	defer {
		for k, &v in firsts {
			delete(v)
		}
		delete(firsts)
	}

	follows := compute_follow_sets(&g, firsts)
	defer {
		for k, &v in follows {
			delete(v)
		}
		delete(follows)
	}

	// 5. check_ll1_conflicts() で衝突検出 (警告出力、演算子ループ変換済み規則はスキップ)
	conflicts := check_ll1_conflicts(&g, firsts, follows, &op_loops)
	defer ll1_conflicts_destroy(&conflicts)
	if len(conflicts) > 0 {
		// %expect_conflict で予想された衝突を分類
		// 規則ごとの衝突数をカウント
		conflict_counts: map[string]int
		defer delete(conflict_counts)
		for &c in conflicts {
			conflict_counts[c.rule_name] = (conflict_counts[c.rule_name] or_else 0) + 1
		}

		has_unexpected := false
		for &c in conflicts {
			expected, has_expected := g.expected_conflicts[c.rule_name]
			if has_expected && conflict_counts[c.rule_name] <= expected {
				fmt.eprintfln("Info: rule '%s': productions %d and %d conflict on tokens: %s (expected)",
					c.rule_name, c.prod_i, c.prod_j, strings.join(c.tokens[:], ", ", context.temp_allocator))
			} else {
				has_unexpected = true
				fmt.eprintfln("Warning: rule '%s': productions %d and %d conflict on tokens: %s",
					c.rule_name, c.prod_i, c.prod_j, strings.join(c.tokens[:], ", ", context.temp_allocator))
			}
		}

		if has_unexpected {
			fmt.eprintfln("Warning: %d LL(1) conflict(s) detected (some may be unexpected)", len(conflicts))
		}
	}

	// 6. generate_states() で状態生成
	states := generate_states(&g, &op_loops)
	defer states_destroy(&states)

	// 7. codegen() でコード生成
	ci := Codegen_Input{
		grammar  = &g,
		firsts   = &firsts,
		follows  = &follows,
		states   = &states,
		op_loops = &op_loops,
	}
	token_code := codegen_token(&g)
	defer delete(token_code)
	code := codegen(ci)
	defer delete(code)

	// 8. 出力
	if opt.output == "" {
		// stdout: セパレータ付きで両方出力
		fmt.eprintln("// ===== TOKEN DEFINITIONS =====")
		os.write(os.stdout, transmute([]u8)token_code)
		fmt.eprintln("// ===== PARSER =====")
		os.write(os.stdout, transmute([]u8)code)
	} else {
		// token ファイル名の導出: foo.odin -> foo_token.odin
		token_output: string
		if strings.has_suffix(opt.output, ".odin") {
			base := opt.output[:len(opt.output) - len(".odin")]
			token_output = strings.concatenate({base, "_token.odin"})
		} else {
			token_output = strings.concatenate({opt.output, "_token.odin"})
		}
		defer delete(token_output)

		// parser ファイル書き出し
		write_ok := os.write_entire_file(opt.output, transmute([]u8)code)
		if !write_ok {
			fmt.eprintfln("Error: cannot write to '%s'", opt.output)
			os.exit(1)
		}
		fmt.printfln("Generated: %s (%d bytes)", opt.output, len(code))

		// token ファイル書き出し
		write_ok2 := os.write_entire_file(token_output, transmute([]u8)token_code)
		if !write_ok2 {
			fmt.eprintfln("Error: cannot write to '%s'", token_output)
			os.exit(1)
		}
		fmt.printfln("Generated: %s (%d bytes)", token_output, len(token_code))
	}

	// 統計情報
	fmt.eprintfln("Grammar: %d tokens, %d rules, %d states",
		len(g.tokens), len(g.rules), len(states) + 3) // +3 for Start, End, Error
}
