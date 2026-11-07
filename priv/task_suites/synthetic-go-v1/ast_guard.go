// This trusted parser is compiled before candidate code is compiled or executed.
// The finite suite deliberately accepts one pure utility function, not arbitrary Go.
package main

import (
 "go/ast"
 "go/parser"
 "go/token"
 "os"
 "strconv"
 "strings"
)

func reject() { os.Stderr.WriteString("candidate_subset_rejected\n"); os.Exit(45) }

func fields(list *ast.FieldList, typename string, count int) bool {
 if list == nil { return false }
 total := 0
 for _, field := range list.List {
  value, ok := field.Type.(*ast.Ident)
  if !ok || value.Name != typename { return false }
  n := len(field.Names); if n == 0 { n = 1 }; total += n
 }
 return total == count
}

func main() {
 if len(os.Args) != 3 { reject() }
 task := os.Args[2]
 name, kind, params := "Clamp", "int", 3
 if task == "reverse_words" { name, kind, params = "ReverseWords", "string", 1 } else if task != "clamp" { reject() }
 file, err := parser.ParseFile(token.NewFileSet(), os.Args[1], nil, parser.ParseComments)
 if err != nil || file.Name.Name != "utility" { reject() }
 for _, group := range file.Comments {
  for _, comment := range group.List {
   text := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(comment.Text,"//"),"/*"))
   if strings.HasPrefix(text,"go:") || strings.HasPrefix(text,"line ") || strings.Contains(text,"#cgo") { reject() }
  }
 }
 funcs := 0
 for _, declaration := range file.Decls {
  switch declaration := declaration.(type) {
  case *ast.GenDecl:
   if declaration.Tok != token.IMPORT || task != "reverse_words" { reject() }
   for _, specification := range declaration.Specs {
    imported, ok := specification.(*ast.ImportSpec)
    if !ok || imported.Name != nil { reject() }
    path, err := strconv.Unquote(imported.Path.Value)
    if err != nil || path != "strings" { reject() }
   }
  case *ast.FuncDecl:
   funcs++
   if declaration.Recv != nil || declaration.Name.Name != name || declaration.Type.TypeParams != nil || declaration.Body == nil || !fields(declaration.Type.Params,kind,params) || !fields(declaration.Type.Results,kind,1) { reject() }
  default: reject()
  }
 }
 if funcs != 1 { reject() }
 ast.Inspect(file,func(node ast.Node) bool {
  switch node := node.(type) {
  case *ast.GoStmt: reject()
  case *ast.Ident:
   switch node.Name { case "init","main","print","println","panic","recover","unsafe","reflect","runtime","os","syscall": reject() }
  }
  return true
 })
}
