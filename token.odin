package llpgen

Llp_Token_Type :: enum {
	Eof,
	Error,
	// ディレクティブ
	Dir_Package,  // %package
	Dir_Token,    // %token
	Dir_Left,     // %left
	Dir_Right,    // %right
	Dir_Nonassoc, // %nonassoc
	Dir_Term,       // %term
	Dir_Token_Type, // %token_type
	Dir_Node_Type,  // %node_type
	Separator,      // %%
	// 文法記号
	Colon,        // :
	Pipe,         // |
	Semicolon,    // ;
	// リテラル
	Ident,        // 識別子 (英数字 + アンダースコア)
	String_Lit,   // "..." 文字列リテラル (将来用)
}

Llp_Token :: struct {
	type:   Llp_Token_Type,
	lexeme: string, // ソース上のスライス
	line:   int,
	column: int,
}
