# Pure renderer fixture, not approval authority. No app/server or inference starts.
alias HarnessForge.Compiler
root = Path.expand("tmp/native-agent-probe")
File.rm_rf!(Path.join(root, "exports"))
fixture = File.read!("examples/synthetic_company/harness.json") |> Jason.decode!()

fixture =
  put_in(fixture, ["spec", "policies"], [
    %{
      "id" => "no-shell",
      "capability" => "tool_permissions.bash",
      "value" => "deny",
      "required" => false
    }
  ])

fixture =
  put_in(
    fixture,
    ["spec", "rules", Access.at(0), "statement"],
    "HARNESSFORGE_NATIVE_RULE_SENTINEL: require explicit review."
  )

for {target, version} <- [{"codex", "0.156.0"}, {"claude_code", "2.1.311"}] do
  spec = put_in(fixture, ["spec", "runtime"], %{"name" => target, "version" => version})
  {:ok, artifact} = Compiler.compile(spec)

  for {path, bytes} <- artifact["files"] do
    destination = Path.join([root, "exports", target, path])
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, bytes)
  end
end

File.cp!("test/native_agents/Dockerfile", Path.join(root, "Dockerfile"))
File.cp!("test/native_agents/verify.cjs", Path.join(root, "verify.cjs"))
IO.puts("Synthetic native exports written; no coding agent or model was executed.")
