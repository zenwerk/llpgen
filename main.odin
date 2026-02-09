package llpgen

import "core:flags"
import "core:fmt"
import "core:os"

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

	// 5. check_ll1_conflicts() で衝突検出 (警告出力)
	conflicts := check_ll1_conflicts(&g, firsts, follows)
	defer delete(conflicts)
	if len(conflicts) > 0 {
		fmt.eprintfln("Warning: %d LL(1) conflict(s) detected:", len(conflicts))
		for &c in conflicts {
			fmt.eprintfln("  rule '%s': productions %d and %d conflict on token '%s'",
				c.rule_name, c.prod_i, c.prod_j, c.token)
		}
	}

	// 6. generate_states() で状態生成
	states := generate_states(&g)
	defer states_destroy(&states)

	// 7. codegen() でコード生成
	ci := Codegen_Input{
		grammar = &g,
		firsts  = &firsts,
		follows = &follows,
		states  = &states,
	}
	code := codegen(ci)
	defer delete(code)

	// 8. 出力
	if opt.output == "" {
		fmt.print(code)
	} else {
		write_ok := os.write_entire_file(opt.output, transmute([]u8)code)
		if !write_ok {
			fmt.eprintfln("Error: cannot write to '%s'", opt.output)
			os.exit(1)
		}
		fmt.printfln("Generated: %s (%d bytes)", opt.output, len(code))
	}

	// 統計情報
	fmt.eprintfln("Grammar: %d tokens, %d rules, %d states",
		len(g.tokens), len(g.rules), len(states) + 3) // +3 for Start, End, Error
}
