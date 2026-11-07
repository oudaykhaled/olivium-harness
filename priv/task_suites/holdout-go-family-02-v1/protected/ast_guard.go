// Trusted evaluator. Compile before any candidate. One finite pure function.
package main

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"reflect"
	"strings"
)

func reject() {
	os.Stderr.WriteString("candidate_subset_rejected\n")
	os.Exit(45)
}

func canonical(node any) string {
	var output bytes.Buffer
	positionType := reflect.TypeOf(token.Pos(0))
	if ast.Fprint(&output, nil, node, func(name string, value reflect.Value) bool {
		if value.Type() == positionType { return false }
		switch name {
		case "Obj", "Scope", "Unresolved", "Doc", "Comment", "Comments": return false
		}
		return true
	}) != nil { reject() }
	return output.String()
}

func read(path string) *ast.File {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > 65536 { reject() }
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ParseComments)
	if err != nil || file.Name.Name != "utility" { reject() }
	for _, group := range file.Comments {
		for _, comment := range group.List {
			text := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(comment.Text, "//"), "/*"))
			if strings.HasPrefix(text, "go:") || strings.HasPrefix(text, "line ") || strings.HasPrefix(text, "+build") || strings.Contains(text, "#cgo") { reject() }
		}
	}
	return file
}

func safeBody(body *ast.BlockStmt) {
	ast.Inspect(body, func(node ast.Node) bool {
		if node == nil { return true }
		switch value := node.(type) {
		case *ast.BlockStmt, *ast.IfStmt, *ast.ForStmt, *ast.ReturnStmt,
			*ast.Ident, *ast.BinaryExpr, *ast.ParenExpr, *ast.IndexExpr, *ast.SliceExpr, *ast.EmptyStmt:
		case *ast.AssignStmt:
			switch value.Tok {
			case token.DEFINE, token.ASSIGN, token.ADD_ASSIGN, token.SUB_ASSIGN:
			default: reject()
			}
			for _, left := range value.Lhs {
				if _, ok := left.(*ast.Ident); !ok { reject() }
			}
		case *ast.IncDecStmt:
			if _, ok := value.X.(*ast.Ident); !ok { reject() }
		case *ast.BasicLit:
			if value.Kind != token.INT && value.Kind != token.STRING && value.Kind != token.CHAR { reject() }
		case *ast.UnaryExpr:
			if value.Op != token.ADD && value.Op != token.SUB && value.Op != token.NOT && value.Op != token.XOR { reject() }
		case *ast.CallExpr:
			function, ok := value.Fun.(*ast.Ident)
			if !ok || function.Name != "len" || len(value.Args) != 1 || value.Ellipsis.IsValid() { reject() }
		default: reject()
		}
		if identifier, ok := node.(*ast.Ident); ok {
			switch identifier.Name {
			case "init", "main", "print", "println", "panic", "recover", "unsafe", "reflect", "runtime", "os", "syscall": reject()
			}
		}
		return true
	})
}

func main() {
	if len(os.Args) != 3 { reject() }
	candidate, baseline := read(os.Args[1]), read(os.Args[2])
	if len(candidate.Decls) != 1 || len(baseline.Decls) != 1 { reject() }
	function, ok := candidate.Decls[0].(*ast.FuncDecl)
	original, originalOK := baseline.Decls[0].(*ast.FuncDecl)
	if !ok || !originalOK || function.Recv != nil || function.Name.Name != original.Name.Name || function.Type.TypeParams != nil || function.Body == nil || canonical(function.Type) != canonical(original.Type) { reject() }
	safeBody(function.Body)
}
