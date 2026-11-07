// Trusted evaluator source. Compile this before compiling any candidate.
// This profile permits one pure function body; it does not admit arbitrary Go.
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
	err := ast.Fprint(&output, nil, node, func(name string, value reflect.Value) bool {
		if value.Type() == positionType {
			return false
		}
		switch name {
		case "Obj", "Scope", "Unresolved", "Doc", "Comment", "Comments":
			return false
		}
		return true
	})
	if err != nil {
		reject()
	}
	return output.String()
}

func read(path string) *ast.File {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > 65536 {
		reject()
	}
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ParseComments)
	if err != nil || file.Name.Name != "humanize" {
		reject()
	}
	for _, group := range file.Comments {
		for _, comment := range group.List {
			text := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(comment.Text, "//"), "/*"))
			if strings.HasPrefix(text, "go:") || strings.HasPrefix(text, "line ") ||
				strings.HasPrefix(text, "+build") || strings.Contains(text, "#cgo") {
				reject()
			}
		}
	}
	return file
}

func safeBody(body *ast.BlockStmt) {
	ast.Inspect(body, func(node ast.Node) bool {
		if node == nil {
			return true
		}
		switch value := node.(type) {
		case *ast.BlockStmt, *ast.IfStmt, *ast.ReturnStmt, *ast.Ident,
			*ast.BinaryExpr, *ast.ParenExpr, *ast.IndexExpr, *ast.SliceExpr:
		case *ast.AssignStmt:
			if value.Tok != token.DEFINE && value.Tok != token.ASSIGN {
				reject()
			}
			for _, left := range value.Lhs {
				if _, ok := left.(*ast.Ident); !ok {
					reject()
				}
			}
		case *ast.IncDecStmt:
			identifier, ok := value.X.(*ast.Ident)
			if !ok || identifier.Name != "i" || (value.Tok != token.INC && value.Tok != token.DEC) {
				reject()
			}
		case *ast.BasicLit:
			if value.Kind != token.INT && value.Kind != token.STRING && value.Kind != token.CHAR {
				reject()
			}
		case *ast.UnaryExpr:
			if value.Op != token.ADD && value.Op != token.SUB && value.Op != token.NOT && value.Op != token.XOR {
				reject()
			}
		case *ast.CallExpr:
			if value.Ellipsis.IsValid() {
				reject()
			}
			switch function := value.Fun.(type) {
			case *ast.Ident:
				if function.Name != "len" || len(value.Args) != 1 {
					reject()
				}
			case *ast.SelectorExpr:
				name, ok := function.X.(*ast.Ident)
				if !ok || name.Name != "strings" || function.Sel.Name != "Index" || len(value.Args) != 2 {
					reject()
				}
			default:
				reject()
			}
		case *ast.SelectorExpr:
			name, ok := value.X.(*ast.Ident)
			if !ok || name.Name != "strings" || value.Sel.Name != "Index" {
				reject()
			}
		default:
			reject()
		}
		return true
	})
}

func main() {
	if len(os.Args) != 3 {
		reject()
	}
	candidate, baseline := read(os.Args[1]), read(os.Args[2])
	if len(candidate.Decls) != len(baseline.Decls) {
		reject()
	}
	targets := 0
	for index, declaration := range candidate.Decls {
		function, isFunction := declaration.(*ast.FuncDecl)
		original, originalFunction := baseline.Decls[index].(*ast.FuncDecl)
		if isFunction && function.Name.Name == "stripTrailingDigits" {
			targets++
			if !originalFunction || original.Name.Name != function.Name.Name ||
				function.Recv != nil || function.Type.TypeParams != nil || function.Body == nil ||
				canonical(function.Type) != canonical(original.Type) {
				reject()
			}
			safeBody(function.Body)
		} else if canonical(declaration) != canonical(baseline.Decls[index]) {
			reject()
		}
	}
	if targets != 1 {
		reject()
	}
}
